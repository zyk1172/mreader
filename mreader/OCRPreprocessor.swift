import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UIKit
@preconcurrency import Vision

struct OCRPreprocessor {
    struct Options {
        var isRightToLeft: Bool
        var minimumTextHeight: Double
        var languages: [String] = ["zh-Hans", "zh-Hant", "ja-JP", "ko-KR", "en-US"]
    }

    // CIContext 创建成本高，整个 OCR 预处理共享一个
    nonisolated private static let sharedCIContext = CIContext(options: [.useSoftwareRenderer: false])

    private struct OCRImageVariant {
        let name: String
        let image: UIImage
        let sliceRect: CGRect
        let fullPixelSize: CGSize
    }

    nonisolated static func highResolutionImage(from url: URL, fallback: UIImage?) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            if RemotePageLoader.isRemotePageURL(url),
               let data = await RemotePageLoader.imageData(forRemotePageURL: url),
               let image = imageFromData(data, maxPixelSize: 12000) {
                return image
            }
            if ComicManager.isArchivePageURL(url),
               let data = ComicManager.imageData(forArchivePageURL: url),
               let image = imageFromData(data, maxPixelSize: 12000) {
                return image
            }
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let image = imageFromSource(source, maxPixelSize: 12000) {
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
        print("MReader OCR preprocess slices=\(slices.count) strategy=adaptive image=\(Int(fullSize.width))x\(Int(fullSize.height))")
        var allBlocks: [TextBlock] = []
        for slice in slices {
            let original = OCRImageVariant(
                name: "original",
                image: slice.image,
                sliceRect: slice.rect,
                fullPixelSize: fullSize
            )
            var sliceBlocks = await recognize(
                original,
                options: options,
                passes: languagePasses()
            )

            let originalNeedsFallback = needsEnhancedFallback(sliceBlocks)
            if originalNeedsFallback,
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
                    passes: languagePasses()
                ))
            }

            let shouldTryInverted = isLikelyDark(slice.image) || needsEnhancedFallback(sliceBlocks)
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
                    passes: languagePasses()
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
        passes: [(name: String, languages: [String])]
    ) async -> [TextBlock] {
        var blocks: [TextBlock] = []
        for pass in passes {
            do {
                let result = try await recognizeVariant(
                    variant,
                    options: options,
                    languages: pass.languages,
                    passName: pass.name
                )
                print("MReader OCR variant=\(variant.name) languagePass=\(pass.name) rect=\(Int(variant.sliceRect.minY))-\(Int(variant.sliceRect.maxY)) blocks=\(result.count) avgConfidence=\(String(format: "%.2f", averageConfidence(result)))")
                blocks.append(contentsOf: result)
            } catch {
                print("MReader OCR variant failed name=\(variant.name) languagePass=\(pass.name) error=\(error.localizedDescription)")
            }
        }
        return blocks
    }

    nonisolated private static func needsEnhancedFallback(_ candidates: [TextBlock]) -> Bool {
        let resolved = OCRCandidateResolver.resolve(candidates, isRightToLeft: false).resolvedBlocks
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
        guard let cgImage = image.cgImage,
              let dataProvider = cgImage.dataProvider,
              let data = dataProvider.data,
              let bytes = CFDataGetBytePtr(data) else {
            return false
        }
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = cgImage.bytesPerRow
        // 灰度/索引色图的 bytesPerPixel 可能小于 4，按真实值计算并校验边界，避免越界读取
        let bytesPerPixel = max(cgImage.bitsPerPixel / 8, 1)
        let dataLength = CFDataGetLength(data)
        var total: CGFloat = 0
        var count: CGFloat = 0
        let xStep = max(width / 8, 1)
        let yStep = max(height / 8, 1)
        for y in stride(from: yStep / 2, to: height, by: yStep) {
            for x in stride(from: xStep / 2, to: width, by: xStep) {
                let offset = y * bytesPerRow + x * bytesPerPixel
                guard offset + bytesPerPixel <= dataLength else { continue }
                if bytesPerPixel >= 3 {
                    let r = CGFloat(bytes[offset])
                    let g = CGFloat(bytes[offset + 1])
                    let b = CGFloat(bytes[offset + 2])
                    total += (r + g + b) / 3
                } else {
                    total += CGFloat(bytes[offset])
                }
                count += 1
            }
        }
        guard count > 0 else { return false }
        return total / count < 92
    }

    nonisolated private static func recognizeVariant(
        _ variant: OCRImageVariant,
        options: Options,
        languages: [String],
        passName: String
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
                    for candidate in observation.topCandidates(3) {
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

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
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
        let supported = (try? request.supportedRecognitionLanguages()) ?? preferredLanguages
        let filtered = preferredLanguages.filter { supported.contains($0) }
        return filtered.isEmpty ? preferredLanguages : filtered
    }

    nonisolated static func languagePassesForDiagnostics() -> [[String]] {
        languagePasses().map(\.languages)
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
}
