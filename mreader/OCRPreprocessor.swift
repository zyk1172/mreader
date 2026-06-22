import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UIKit
import Vision

struct OCRPreprocessor {
    struct Options {
        var isRightToLeft: Bool
        var minimumTextHeight: Double
        var languages: [String] = ["zh-Hans", "zh-Hant", "ja-JP", "en-US"]
    }

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
        let fullSize = pixelSize(for: image)
        guard fullSize.width > 8, fullSize.height > 8 else { return [] }

        let variants = makeVariants(for: image, fullPixelSize: fullSize)
        print("MReader OCR preprocess slices=\(Set(variants.map { "\(Int($0.sliceRect.minY))-\(Int($0.sliceRect.maxY))" }).count) variants=\(variants.count) image=\(Int(fullSize.width))x\(Int(fullSize.height))")

        var allBlocks: [TextBlock] = []
        for variant in variants {
            do {
                let blocks = try await recognizeVariant(variant, options: options)
                print("MReader OCR variant=\(variant.name) rect=\(Int(variant.sliceRect.minY))-\(Int(variant.sliceRect.maxY)) blocks=\(blocks.count) avgConfidence=\(String(format: "%.2f", averageConfidence(blocks)))")
                allBlocks.append(contentsOf: blocks)
            } catch {
                print("MReader OCR variant failed name=\(variant.name) error=\(error.localizedDescription)")
            }
        }

        let merged = deduplicated(allBlocks, isRightToLeft: options.isRightToLeft)
        print("MReader OCR merged blocks=\(merged.count) from=\(allBlocks.count)")
        return merged
    }

    nonisolated private static func makeVariants(for image: UIImage, fullPixelSize: CGSize) -> [OCRImageVariant] {
        let slices = sliceImage(image, fullPixelSize: fullPixelSize)
        var variants: [OCRImageVariant] = []
        for slice in slices {
            variants.append(OCRImageVariant(name: "original", image: slice.image, sliceRect: slice.rect, fullPixelSize: fullPixelSize))
            if let enhanced = enhancedImage(slice.image, inverted: false) {
                variants.append(OCRImageVariant(name: "enhanced", image: enhanced, sliceRect: slice.rect, fullPixelSize: fullPixelSize))
            }
            if isLikelyDark(slice.image), let inverted = enhancedImage(slice.image, inverted: true) {
                variants.append(OCRImageVariant(name: "inverted", image: inverted, sliceRect: slice.rect, fullPixelSize: fullPixelSize))
            }
        }
        return variants
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

        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let outputCGImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
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
        let bitsPerPixel = max(cgImage.bitsPerPixel, 32)
        let bytesPerPixel = max(bitsPerPixel / 8, 4)
        var total: CGFloat = 0
        var count: CGFloat = 0
        let xStep = max(width / 8, 1)
        let yStep = max(height / 8, 1)
        for y in stride(from: yStep / 2, to: height, by: yStep) {
            for x in stride(from: xStep / 2, to: width, by: xStep) {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let r = CGFloat(bytes[offset])
                let g = CGFloat(bytes[offset + min(1, bytesPerPixel - 1)])
                let b = CGFloat(bytes[offset + min(2, bytesPerPixel - 1)])
                total += (r + g + b) / 3
                count += 1
            }
        }
        guard count > 0 else { return false }
        return total / count < 92
    }

    nonisolated private static func recognizeVariant(_ variant: OCRImageVariant, options: Options) async throws -> [TextBlock] {
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
                    guard let candidate = observation.topCandidates(1).first else { continue }
                    let rect = mapVisionRect(
                        observation.boundingBox,
                        sliceRect: variant.sliceRect,
                        fullPixelSize: variant.fullPixelSize
                    )
                    blocks.append(TextBlock(
                        text: candidate.string,
                        boundingBox: rect,
                        confidence: Double(candidate.confidence),
                        ocrSource: variant.name
                    ))
                }
                continuation.resume(returning: AITranslator.sortedTextBlocks(blocks, isRightToLeft: options.isRightToLeft))
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.minimumTextHeight = min(max(Float(options.minimumTextHeight * 0.45), 0.0015), 0.04)
            request.recognitionLanguages = supportedRecognitionLanguages(from: options.languages, request: request)

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
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

    nonisolated private static func deduplicated(_ blocks: [TextBlock], isRightToLeft: Bool) -> [TextBlock] {
        var kept: [TextBlock] = []
        for block in AITranslator.sortedTextBlocks(blocks, isRightToLeft: isRightToLeft) {
            let normalized = normalize(block.text)
            guard !normalized.isEmpty else { continue }
            if let existingIndex = kept.firstIndex(where: { existing in
                normalize(existing.text) == normalized && existing.boundingBox.intersection(block.boundingBox).areaRatio(against: existing.boundingBox.union(block.boundingBox)) > 0.35
            }) {
                if block.confidence > kept[existingIndex].confidence {
                    kept[existingIndex] = block
                }
            } else {
                kept.append(block)
            }
        }
        return AITranslator.sortedTextBlocks(kept, isRightToLeft: isRightToLeft)
    }

    nonisolated private static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

    nonisolated private static func averageConfidence(_ blocks: [TextBlock]) -> Double {
        guard !blocks.isEmpty else { return 0 }
        return blocks.reduce(0) { $0 + $1.confidence } / Double(blocks.count)
    }
}

private extension CGRect {
    nonisolated func areaRatio(against rect: CGRect) -> CGFloat {
        guard !isNull, !rect.isNull, rect.width > 0, rect.height > 0 else { return 0 }
        let intersection = self.intersection(rect)
        guard !intersection.isNull else { return 0 }
        return (intersection.width * intersection.height) / max(rect.width * rect.height, 1)
    }
}
