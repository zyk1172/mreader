import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UIKit
@preconcurrency import Vision

nonisolated enum OCRRecognitionMode: String, Codable, CaseIterable, Sendable {
    case adaptive
    case maximumAccuracy

    var localizationKey: String {
        switch self {
        case .adaptive: return "ocr.localMode.adaptive"
        case .maximumAccuracy: return "ocr.localMode.accurate"
        }
    }
}

struct OCRPreprocessor {
    struct Options: Sendable {
        var isRightToLeft: Bool
        var minimumTextHeight: Double
        var languages: [String] = ["zh-Hans", "zh-Hant", "ja-JP", "ko-KR", "en-US"]
        var recognitionMode: OCRRecognitionMode = .adaptive
        /// 用户显式指定的原文语言：CJK 无假名时优先用它来区分中/日文，而不是只靠阅读方向猜。
        var sourceLanguagePreference: TranslationSourceLanguage? = nil
    }

    // CIContext 创建成本高，整个 OCR 预处理共享一个
    nonisolated private static let sharedCIContext = CIContext(options: [.useSoftwareRenderer: false])
    // OCR 高清图上限：普通对白 4500px 足够，避免每次 12000px 解码带来巨大内存/耗时峰值
    nonisolated private static let highResolutionMaxPixelSize: CGFloat = 4_500

    nonisolated private struct OCRImageVariant {
        let name: String
        let image: UIImage
        let sliceRect: CGRect
        let fullPixelSize: CGSize
    }

    nonisolated private struct RecognitionPlan {
        let primary: (name: String, languages: [String])
        let fallback: (name: String, languages: [String])?

        var orderedPasses: [(name: String, languages: [String])] {
            if let fallback { return [primary, fallback] }
            return [primary]
        }
    }

    nonisolated static func highResolutionImage(from url: URL, fallback: UIImage?) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            if RemotePageLoader.isRemotePageURL(url),
               let data = await RemotePageLoader.imageData(forRemotePageURL: url),
               let image = imageFromData(data, maxPixelSize: highResolutionMaxPixelSize) {
                return image
            }
            if ComicManager.isArchivePageURL(url),
               let data = ComicManager.imageData(forArchivePageURL: url),
               let image = imageFromData(data, maxPixelSize: highResolutionMaxPixelSize) {
                return image
            }
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let image = imageFromSource(source, maxPixelSize: highResolutionMaxPixelSize) {
                return image
            }
            return fallback
        }.value
    }

    nonisolated static func recognizeText(in image: UIImage, options: Options) async throws -> [TextBlock] {
        try await MangaOCRPipeline.recognize(in: image, options: options).bubbleBlocks
    }

    nonisolated static func recognizeCandidates(in image: UIImage, options: Options) async throws -> [TextBlock] {
        let normalizedImage = normalizedOrientationImage(image)
        let fullSize = pixelSize(for: normalizedImage)
        guard fullSize.width > 8, fullSize.height > 8 else { return [] }

        let slices = sliceImage(normalizedImage, fullPixelSize: fullSize)
        print("MReader OCR preprocess slices=\(slices.count) strategy=\(options.recognitionMode.rawValue) image=\(Int(fullSize.width))x\(Int(fullSize.height))")
        var allBlocks: [TextBlock] = []
        for slice in slices {
            try Task.checkCancellation()
            let original = OCRImageVariant(
                name: "original",
                image: slice.image,
                sliceRect: slice.rect,
                fullPixelSize: fullSize
            )
            let locatorImage = downsampledImage(slice.image, maxDimension: 1_400) ?? slice.image
            let locator = OCRImageVariant(
                name: "locator",
                image: locatorImage,
                sliceRect: slice.rect,
                fullPixelSize: fullSize
            )
            let plan: RecognitionPlan
            var sliceBlocks: [TextBlock]
            switch options.recognitionMode {
            case .adaptive:
                let locatorBlocks = await recognize(
                    locator,
                    options: options,
                    passes: [("script", effectiveLanguages(for: options))],
                    level: .fast,
                    usesLanguageCorrection: false,
                    maximumCandidates: 1
                )
                plan = recognitionPlan(
                    detectedTexts: locatorBlocks.map(\.text),
                    options: options
                )
                print("MReader OCR locator rect=\(Int(slice.rect.minY))-\(Int(slice.rect.maxY)) blocks=\(locatorBlocks.count) primary=\(plan.primary.name)")
                sliceBlocks = await recognize(
                    original,
                    options: options,
                    passes: [plan.primary]
                )
                if needsEnhancedFallback(sliceBlocks, isRightToLeft: options.isRightToLeft), let fallback = plan.fallback {
                    sliceBlocks.append(contentsOf: await recognize(
                        original,
                        options: options,
                        passes: [fallback]
                    ))
                }
            case .maximumAccuracy:
                let passes = maximumAccuracyPasses(for: options)
                plan = RecognitionPlan(primary: passes[0], fallback: passes[1])
                sliceBlocks = await recognize(
                    original,
                    options: options,
                    passes: passes
                )
            }

            let needsImageEnhancement = needsEnhancedFallback(sliceBlocks, isRightToLeft: options.isRightToLeft)
            if needsImageEnhancement,
               let enhancedImage = enhancedImage(slice.image, inverted: false) {
                let enhanced = OCRImageVariant(
                    name: "enhanced",
                    image: enhancedImage,
                    sliceRect: slice.rect,
                    fullPixelSize: fullSize
                )
                sliceBlocks.append(contentsOf: await recognize(
                    enhanced,
                    options: options,
                    passes: options.recognitionMode == .adaptive ? [plan.primary] : plan.orderedPasses
                ))
            }

            // 暗色判断只分析低分辨率定位图，避免为了少量采样强制解码整块高清像素。
            let shouldTryInverted = isLikelyDark(locatorImage) || needsEnhancedFallback(sliceBlocks, isRightToLeft: options.isRightToLeft)
            if shouldTryInverted,
               let invertedImage = enhancedImage(slice.image, inverted: true) {
                let inverted = OCRImageVariant(
                    name: "inverted",
                    image: invertedImage,
                    sliceRect: slice.rect,
                    fullPixelSize: fullSize
                )
                sliceBlocks.append(contentsOf: await recognize(
                    inverted,
                    options: options,
                    passes: options.recognitionMode == .adaptive ? [plan.primary] : plan.orderedPasses
                ))
            }
            allBlocks.append(contentsOf: sliceBlocks)
        }

        print("MReader OCR raw candidates=\(allBlocks.count)")
        return allBlocks
    }

    nonisolated private static func recognize(
        _ variant: OCRImageVariant,
        options: Options,
        passes: [(name: String, languages: [String])],
        level: VNRequestTextRecognitionLevel = .accurate,
        usesLanguageCorrection: Bool = true,
        maximumCandidates: Int = 3
    ) async -> [TextBlock] {
        var blocks: [TextBlock] = []
        for pass in passes {
            do {
                let result = try await recognizeVariant(
                    variant,
                    options: options,
                    languages: pass.languages,
                    passName: pass.name,
                    level: level,
                    usesLanguageCorrection: usesLanguageCorrection,
                    maximumCandidates: maximumCandidates
                )
                print("MReader OCR variant=\(variant.name) languagePass=\(pass.name) rect=\(Int(variant.sliceRect.minY))-\(Int(variant.sliceRect.maxY)) blocks=\(result.count) avgConfidence=\(String(format: "%.2f", averageConfidence(result)))")
                blocks.append(contentsOf: result)
            } catch {
                print("MReader OCR variant failed name=\(variant.name) languagePass=\(pass.name) error=\(error.localizedDescription)")
            }
        }
        return blocks
    }

    nonisolated private static func needsEnhancedFallback(
        _ candidates: [TextBlock],
        isRightToLeft: Bool
    ) -> Bool {
        let resolved = OCRCandidateResolver.resolve(candidates, isRightToLeft: isRightToLeft).resolvedBlocks
        guard !resolved.isEmpty else { return true }
        let confidence = averageConfidence(resolved)
        let usefulCharacterCount = resolved.reduce(into: 0) { total, block in
            total += block.text.unicodeScalars.filter {
                CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
            }.count
        }
        let totalCharacterCount = resolved.reduce(0) { $0 + $1.text.unicodeScalars.count }
        let usefulRatio = Double(usefulCharacterCount) / Double(max(totalCharacterCount, 1))
        return confidence < 0.58 || usefulRatio < 0.42
    }

    nonisolated private static func sliceImage(_ image: UIImage, fullPixelSize: CGSize) -> [(image: UIImage, rect: CGRect)] {
        guard let cgImage = image.cgImage else { return [(image, CGRect(origin: .zero, size: fullPixelSize))] }
        let width = cgImage.width
        let height = cgImage.height
        let sliceHeight = height > 3600 ? 2600 : height
        let overlap = max(0, Int(Double(sliceHeight) * 0.1))
        var output: [(UIImage, CGRect)] = []
        var y = 0
        while y < height {
            let h = min(sliceHeight, height - y)
            let rect = CGRect(x: 0, y: y, width: width, height: h)
            if let cropped = cgImage.cropping(to: rect) {
                output.append((UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation), rect))
            }
            if y + h >= height { break }
            y += max(1, sliceHeight - overlap)
        }
        return output.isEmpty ? [(image, CGRect(origin: .zero, size: fullPixelSize))] : output
    }

    nonisolated private static func enhancedImage(_ image: UIImage, inverted: Bool) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        var ciImage = CIImage(cgImage: cgImage)

        let mono = CIFilter.colorControls()
        mono.inputImage = ciImage
        mono.saturation = 0
        mono.contrast = 1.65
        mono.brightness = 0.02
        guard let monoOutput = mono.outputImage else { return nil }
        ciImage = monoOutput

        let denoise = CIFilter.noiseReduction()
        denoise.inputImage = ciImage
        denoise.noiseLevel = 0.018
        denoise.sharpness = 0.55
        if let output = denoise.outputImage {
            ciImage = output
        }

        let sharpen = CIFilter.sharpenLuminance()
        sharpen.inputImage = ciImage
        sharpen.sharpness = 0.75
        if let output = sharpen.outputImage {
            ciImage = output
        }

        if inverted {
            let invert = CIFilter.colorInvert()
            invert.inputImage = ciImage
            if let output = invert.outputImage {
                ciImage = output
            }
        }

        guard let outputCGImage = sharedCIContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: outputCGImage, scale: image.scale, orientation: image.imageOrientation)
    }

    nonisolated private static func isLikelyDark(_ image: UIImage) -> Bool {
        // 统一缩到 8×8 RGBA8888 再计算平均亮度，避免直接读取 CGImage 原始像素时
        // 因灰度/RGB/索引色等不同格式而对字节布局做错误假设。
        guard let cgImage = image.cgImage else { return false }
        let sampleSize = 8
        var pixelBuffer = [UInt8](repeating: 0, count: sampleSize * sampleSize * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixelBuffer,
            width: sampleSize,
            height: sampleSize,
            bitsPerComponent: 8,
            bytesPerRow: sampleSize * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return false
        }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))
        var total: CGFloat = 0
        var count: CGFloat = 0
        var offset = 0
        while offset + 3 < pixelBuffer.count {
            let r = CGFloat(pixelBuffer[offset])
            let g = CGFloat(pixelBuffer[offset + 1])
            let b = CGFloat(pixelBuffer[offset + 2])
            total += (r + g + b) / 3
            count += 1
            offset += 4
        }
        guard count > 0 else { return false }
        return total / count < 92
    }

    nonisolated private static func recognizeVariant(
        _ variant: OCRImageVariant,
        options: Options,
        languages: [String],
        passName: String,
        level: VNRequestTextRecognitionLevel,
        usesLanguageCorrection: Bool,
        maximumCandidates: Int
    ) async throws -> [TextBlock] {
        try await withCheckedThrowingContinuation { continuation in
            guard let cgImage = variant.image.cgImage else {
                continuation.resume(returning: [])
                return
            }

            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                var blocks: [TextBlock] = []
                for observation in observations {
                    let rect = mapVisionRect(
                        observation.boundingBox,
                        sliceRect: variant.sliceRect,
                        fullPixelSize: variant.fullPixelSize
                    )
                    let textColor = variant.name == "original"
                        ? representativeTextColorHex(in: cgImage, visionRect: observation.boundingBox)
                        : nil
                    for candidate in observation.topCandidates(maximumCandidates) {
                        blocks.append(TextBlock(
                            text: candidate.string,
                            boundingBox: rect,
                            confidence: Double(candidate.confidence),
                            ocrSource: "\(variant.name):\(passName)",
                            // 竖排列的字号≈列宽，横排行的字号≈行高
                            estimatedFontScale: Double(min(rect.width, rect.height)),
                            textColorHex: textColor
                        ))
                    }
                }
                continuation.resume(returning: AITranslator.sortedTextBlocks(blocks, isRightToLeft: options.isRightToLeft))
            }

            request.recognitionLevel = level
            request.usesLanguageCorrection = usesLanguageCorrection
            request.minimumTextHeight = min(max(Float(options.minimumTextHeight * 0.45), 0.0008), 0.04)
            request.recognitionLanguages = supportedRecognitionLanguages(from: languages, request: request)

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            // Vision 识别是重计算，放到全局队列执行，避免长时间占用 Swift 并发协作线程
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    nonisolated private static func mapVisionRect(_ visionRect: CGRect, sliceRect: CGRect, fullPixelSize: CGSize) -> CGRect {
        let x = (sliceRect.minX + visionRect.minX * sliceRect.width) / fullPixelSize.width
        let yInSliceFromTop = (1 - visionRect.maxY) * sliceRect.height
        let y = (sliceRect.minY + yInSliceFromTop) / fullPixelSize.height
        let width = visionRect.width * sliceRect.width / fullPixelSize.width
        let height = visionRect.height * sliceRect.height / fullPixelSize.height
        return CGRect(x: x, y: y, width: width, height: height)
    }

    nonisolated private static func representativeTextColorHex(in image: CGImage, visionRect: CGRect) -> String? {
        let pixelRect = CGRect(
            x: visionRect.minX * CGFloat(image.width),
            y: (1 - visionRect.maxY) * CGFloat(image.height),
            width: visionRect.width * CGFloat(image.width),
            height: visionRect.height * CGFloat(image.height)
        ).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard pixelRect.width >= 2, pixelRect.height >= 2,
              let crop = image.cropping(to: pixelRect) else { return nil }

        let width = 12
        let height = 12
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .low
        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))

        var darkest = (r: UInt8(255), g: UInt8(255), b: UInt8(255), luminance: Double(255))
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = pixels[index]
            let g = pixels[index + 1]
            let b = pixels[index + 2]
            let luminance = 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
            if luminance < darkest.luminance {
                darkest = (r, g, b, luminance)
            }
        }
        return String(format: "#%02X%02X%02X", darkest.r, darkest.g, darkest.b)
    }

    nonisolated private static func pixelSize(for image: UIImage) -> CGSize {
        if let cgImage = image.cgImage {
            return CGSize(width: cgImage.width, height: cgImage.height)
        }
        return CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    }

    nonisolated private static func imageFromData(_ data: Data, maxPixelSize: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return UIImage(data: data) }
        return imageFromSource(source, maxPixelSize: maxPixelSize)
    }

    nonisolated private static func imageFromSource(_ source: CGImageSource, maxPixelSize: CGFloat) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    nonisolated private static func supportedRecognitionLanguages(from preferredLanguages: [String], request: VNRecognizeTextRequest) -> [String] {
        guard let supported = try? request.supportedRecognitionLanguages() else {
            // 查询 API 失败：才允许使用兼容 fallback（项10）
            return preferredLanguages
        }
        let filtered = preferredLanguages.filter { supported.contains($0) }
        // 查询成功但 intersection 为空：不能再返回已知 unsupported 的 preferred；
        // 退回到设备实际支持的语言（优先英文），保证 OCR 至少能运行。
        if filtered.isEmpty {
            return ["en-US"].filter { supported.contains($0) }
        }
        return filtered
    }

    nonisolated static func languagePassesForDiagnostics() -> [[String]] {
        languagePasses().map(\.languages)
    }

    nonisolated static func preferredLanguagePassesForDiagnostics(
        detectedTexts: [String],
        isRightToLeft: Bool = false,
        sourceLanguagePreference: TranslationSourceLanguage? = nil
    ) -> [[String]] {
        recognitionPlan(
            detectedTexts: detectedTexts,
            options: Options(
                isRightToLeft: isRightToLeft,
                minimumTextHeight: 0.006,
                sourceLanguagePreference: sourceLanguagePreference
            )
        ).orderedPasses.map(\.languages)
    }

    /// 供测试：最高精度模式的 pass（项8）。
    nonisolated static func maximumAccuracyPassesForDiagnostics(
        sourceLanguagePreference: TranslationSourceLanguage? = nil
    ) -> [[String]] {
        maximumAccuracyPasses(
            for: Options(
                isRightToLeft: false,
                minimumTextHeight: 0.006,
                sourceLanguagePreference: sourceLanguagePreference
            )
        ).map(\.languages)
    }

    /// 供测试：supportedRecognitionLanguages 过滤逻辑（项10）。
    nonisolated static func supportedRecognitionLanguagesForDiagnostics(
        preferredLanguages: [String]
    ) -> [String] {
        supportedRecognitionLanguages(
            from: preferredLanguages,
            request: VNRecognizeTextRequest()
        )
    }

    /// #8：最高精度模式也必须尊重 sourceLanguagePreference。
    nonisolated private static func maximumAccuracyPasses(for options: Options) -> [(name: String, languages: [String])] {
        if let source = options.sourceLanguagePreference, source != .automatic {
            let effective = effectiveLanguages(for: options)
            let primaryIDs = filteredLanguages(
                source.recognitionLanguageIdentifiers,
                allowed: effective
            )
            let defaultIDs = languagePasses().flatMap(\.languages)
            let fallbackIDs = defaultIDs.filter { !primaryIDs.contains($0) }
            return [
                ("manual", primaryIDs),
                ("fallback", fallbackIDs.isEmpty ? primaryIDs : fallbackIDs)
            ]
        }
        return languagePasses()
    }

    nonisolated private static func languagePasses() -> [(name: String, languages: [String])] {
        [
            ("zh-ko", ["zh-Hans", "zh-Hant", "ko-KR", "en-US"]),
            ("ja", ["ja-JP", "en-US"])
        ]
    }

    nonisolated private static func normalizedOrientationImage(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    nonisolated private static func averageConfidence(_ blocks: [TextBlock]) -> Double {
        guard !blocks.isEmpty else { return 0 }
        return blocks.reduce(0) { $0 + $1.confidence } / Double(blocks.count)
    }

    nonisolated private static func recognitionPlan(
        detectedTexts: [String],
        options: Options
    ) -> RecognitionPlan {
        let scalars = detectedTexts.joined().unicodeScalars
        var kanaCount = 0
        var hangulCount = 0
        var cjkCount = 0
        var latinCount = 0
        var cyrillicCount = 0
        var thaiCount = 0
        var arabicCount = 0

        for scalar in scalars {
            switch scalar.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF:
                kanaCount += 1
            case 0xAC00...0xD7AF, 0x1100...0x11FF:
                hangulCount += 1
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                cjkCount += 1
            case 0x0041...0x005A, 0x0061...0x007A:
                latinCount += 1
            case 0x0400...0x052F:
                cyrillicCount += 1
            case 0x0E00...0x0E7F:
                thaiCount += 1
            case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF:
                arabicCount += 1
            default:
                break
            }
        }

        // #7：用户手动指定原文语言时拥有最高优先级，不再先猜 script。
        if let source = options.sourceLanguagePreference, source != .automatic {
            let identifiers = filteredLanguages(
                source.recognitionLanguageIdentifiers,
                allowed: effectiveLanguages(for: options)
            )
            return RecognitionPlan(
                primary: (source.rawValue, identifiers),
                fallback: nil
            )
        }

        let japanese = ("ja", filteredLanguages(["ja-JP", "en-US"], allowed: options.languages))
        let chinese = ("zh", filteredLanguages(["zh-Hans", "zh-Hant", "en-US"], allowed: options.languages))
        let korean = ("ko", filteredLanguages(["ko-KR", "en-US"], allowed: options.languages))
        let english = ("en", filteredLanguages(["en-US"], allowed: options.languages))

        if kanaCount > 0 {
            return RecognitionPlan(primary: japanese, fallback: chinese)
        }
        if hangulCount > 0 {
            return RecognitionPlan(primary: korean, fallback: japanese)
        }
        // #9：Auto 模式补充西里尔/泰/阿拉伯文检测
        if cyrillicCount > 0 {
            let russian = ("ru", filteredLanguages(["ru-RU"], allowed: effectiveLanguages(for: options)))
            return RecognitionPlan(primary: russian, fallback: nil)
        }
        if thaiCount > 0 {
            let thai = ("th", filteredLanguages(["th-TH"], allowed: effectiveLanguages(for: options)))
            return RecognitionPlan(primary: thai, fallback: nil)
        }
        if arabicCount > 0 {
            let arabic = ("ar", filteredLanguages(["ar-SA"], allowed: effectiveLanguages(for: options)))
            return RecognitionPlan(primary: arabic, fallback: nil)
        }
        if cjkCount > 0 {
            // 用户显式指定原文语言时优先遵循，替代“用阅读方向猜中/日文”的弱启发（审查 #21）
            switch options.sourceLanguagePreference {
            case .japanese:
                return RecognitionPlan(primary: japanese, fallback: chinese)
            case .simplifiedChinese, .traditionalChinese:
                return RecognitionPlan(primary: chinese, fallback: japanese)
            default:
                return options.isRightToLeft
                    ? RecognitionPlan(primary: japanese, fallback: chinese)
                    : RecognitionPlan(primary: chinese, fallback: japanese)
            }
        }
        if latinCount > 0 {
            let allowed = effectiveLanguages(for: options)
            let primary: (name: String, languages: [String])
            if let preference = options.sourceLanguagePreference,
               [.french, .german, .spanish, .italian, .portuguese,
                .vietnamese, .indonesian, .english].contains(preference) {
                primary = (
                    preference.rawValue,
                    filteredLanguages(preference.recognitionLanguageIdentifiers, allowed: allowed)
                )
            } else {
                primary = english
            }
            return RecognitionPlan(primary: primary, fallback: options.isRightToLeft ? japanese : chinese)
        }

        let defaults = languagePasses()
        return RecognitionPlan(primary: defaults[0], fallback: defaults[1])
    }

    /// 用户显式指定原文语言时，优先使用该语言的识别标识（并保留默认语言作兜底），
    /// 让法语/德语等设置真正贯彻到 Apple Vision OCR（审查 #10）。
    nonisolated private static func effectiveLanguages(for options: Options) -> [String] {
        guard let preference = options.sourceLanguagePreference, preference != .automatic else {
            return options.languages
        }
        var merged = preference.recognitionLanguageIdentifiers
        for language in options.languages where !merged.contains(language) {
            merged.append(language)
        }
        return merged
    }

    nonisolated private static func filteredLanguages(_ preferred: [String], allowed: [String]) -> [String] {
        let filtered = preferred.filter(allowed.contains)
        return filtered.isEmpty ? preferred : filtered
    }

    nonisolated private static func downsampledImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let largestDimension = max(width, height)
        guard largestDimension > maxDimension else { return image }
        let scale = maxDimension / largestDimension
        let targetWidth = max(Int((width * scale).rounded()), 1)
        let targetHeight = max(Int((height * scale).rounded()), 1)
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let output = context.makeImage() else { return nil }
        return UIImage(cgImage: output, scale: image.scale, orientation: .up)
    }
}
