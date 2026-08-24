import Foundation
import UIKit
import TesseractSwift

/// A small, deliberately conservative coverage summary used to decide whether
/// the vertical Japanese fallback is worth the extra local OCR pass.
nonisolated struct JapaneseVerticalOCRCoverage: Equatable, Sendable {
    let averageConfidence: Double
    let usefulCharacterRatio: Double

    var isInsufficient: Bool {
        averageConfidence < JapaneseVerticalOCRService.minimumAverageConfidence
            || usefulCharacterRatio < JapaneseVerticalOCRService.minimumUsefulCharacterRatio
    }
}

/// Tesseract is not the primary OCR engine in MReader.  This service only
/// owns the narrow escape hatch for pages where Vision has evidence of
/// Japanese vertical writing but its result is incomplete.
nonisolated enum JapaneseVerticalOCRService {
    static let revision = "jpn-vert-tesseract-5.5.1-v1"
    static let minimumAverageConfidence = 0.58
    static let minimumUsefulCharacterRatio = 0.42

    private static let modelName = "jpn_vert"
    private static let sourceName = "tesseract:jpn_vert"
    private static let resourceLock = NSLock()

    private struct RawWord: Sendable {
        let text: String
        let rotatedBoundingBox: CGRect
        let confidence: Double
    }

    private final class ResourceToken {}

    /// Runs only for an explicitly Japanese page, or for automatic detection
    /// that already found kana.  A Chinese/English/Korean page therefore never
    /// pays for the Tesseract pass merely because the reader is RTL.
    static func recognizeIfNeeded(
        in image: UIImage,
        existingBlocks: [TextBlock],
        options: OCRPreprocessor.Options
    ) async -> [TextBlock] {
        guard shouldRunFallback(
            in: image,
            existingBlocks: existingBlocks,
            options: options
        ) else {
            return []
        }

        guard let normalized = normalizedImage(image),
              let rotated = rotatedForVerticalOCR(normalized),
              let imageData = rotated.pngData(),
              let dataPath = tessdataParentPath() else {
            print("MReader Japanese vertical OCR unavailable: jpn_vert resource is missing")
            return []
        }

        do {
            let rawWords = try await Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                return try recognizeWords(data: imageData, dataPath: dataPath)
            }.value

            let originalPixelSize = CGSize(
                width: normalized.cgImage?.width ?? 0,
                height: normalized.cgImage?.height ?? 0
            )
            guard originalPixelSize.width > 0, originalPixelSize.height > 0 else {
                return []
            }
            let rotatedPixelSize = CGSize(
                width: originalPixelSize.height,
                height: originalPixelSize.width
            )

            let blocks = rawWords.compactMap { word -> TextBlock? in
                let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                let rotatedBox = CGRect(
                    x: word.rotatedBoundingBox.minX / rotatedPixelSize.width,
                    y: word.rotatedBoundingBox.minY / rotatedPixelSize.height,
                    width: word.rotatedBoundingBox.width / rotatedPixelSize.width,
                    height: word.rotatedBoundingBox.height / rotatedPixelSize.height
                )
                let box = rotatedBoundingBoxToOriginal(rotatedBox)
                guard box.width > 0, box.height > 0 else { return nil }
                return TextBlock(
                    text: text,
                    boundingBox: box,
                    confidence: max(0, min(word.confidence, 1)),
                    ocrSource: sourceName,
                    estimatedFontScale: Double(box.width),
                    textOrientation: .vertical
                )
            }
            print("MReader Japanese vertical OCR fallback blocks=\(blocks.count)")
            return blocks
        } catch is CancellationError {
            return []
        } catch {
            // The fallback must never turn a successful Vision page into a
            // failed page.  Keep the diagnostic and let Vision's blocks flow
            // through the existing candidate resolver.
            print("MReader Japanese vertical OCR failed: \(error.localizedDescription)")
            return []
        }
    }

    static func shouldRunFallback(
        in image: UIImage?,
        existingBlocks: [TextBlock],
        options: OCRPreprocessor.Options
    ) -> Bool {
        shouldRequestPageRecovery(
            in: image,
            existingBlocks: existingBlocks,
            isRightToLeft: options.isRightToLeft,
            sourceLanguagePreference: options.sourceLanguagePreference
        )
    }

    static func shouldRequestPageRecovery(
        in image: UIImage?,
        existingBlocks: [TextBlock],
        isRightToLeft: Bool,
        sourceLanguagePreference: TranslationSourceLanguage?
    ) -> Bool {
        guard isRightToLeft,
              isJapanesePage(
                  existingBlocks: existingBlocks,
                  preference: sourceLanguagePreference
              ) else {
            return false
        }

        let coverage = coverage(for: existingBlocks, isRightToLeft: isRightToLeft)
        guard coverage.isInsufficient else { return false }

        let blockColumns = verticalColumnCount(in: existingBlocks)
        // Once Vision has produced horizontal observations, trust those
        // observations for orientation.  Pixel projection is reserved for the
        // genuinely empty-result case, where it is the only local evidence
        // available and can still discover two missed vertical columns.
        if blockColumns >= 2 { return true }
        guard existingBlocks.isEmpty else { return false }
        return (image.map(verticalColumnEvidence(in:)) ?? 0) >= 2
    }

    static func coverage(
        for blocks: [TextBlock],
        isRightToLeft: Bool
    ) -> JapaneseVerticalOCRCoverage {
        let resolved = OCRCandidateResolver.resolve(
            blocks,
            isRightToLeft: isRightToLeft
        ).resolvedBlocks
        guard !resolved.isEmpty else {
            return JapaneseVerticalOCRCoverage(averageConfidence: 0, usefulCharacterRatio: 0)
        }

        let confidence = resolved.reduce(0) { $0 + $1.confidence } / Double(resolved.count)
        let usefulCharacters = resolved.reduce(into: 0) { total, block in
            total += block.text.unicodeScalars.filter {
                CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
            }.count
        }
        let allCharacters = resolved.reduce(0) { $0 + $1.text.unicodeScalars.count }
        return JapaneseVerticalOCRCoverage(
            averageConfidence: confidence,
            usefulCharacterRatio: Double(usefulCharacters) / Double(max(allCharacters, 1))
        )
    }

    static func isJapanesePage(
        existingBlocks: [TextBlock],
        preference: TranslationSourceLanguage?
    ) -> Bool {
        if preference == .japanese { return true }
        guard preference == nil || preference == .automatic else { return false }
        let text = existingBlocks.map(\.text).joined()
        return text.unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value)
                || (0x31F0...0x31FF).contains(scalar.value)
        } || existingBlocks.contains { $0.ocrSource.localizedCaseInsensitiveContains(":ja") }
    }

    /// Returns the number of separated vertical text columns represented by
    /// local OCR observations.  This is intentionally a diagnostic-friendly
    /// pure function so it can be regression-tested without Vision or a model.
    static func verticalColumnCount(in blocks: [TextBlock]) -> Int {
        let verticalBlocks = blocks
            .filter { block in
                block.textOrientation == .vertical
                    || block.boundingBox.height >= block.boundingBox.width * 1.35
            }
            .sorted { $0.boundingBox.midX < $1.boundingBox.midX }
        guard !verticalBlocks.isEmpty else { return 0 }

        let averageWidth = verticalBlocks.reduce(0) { $0 + $1.boundingBox.width }
            / CGFloat(verticalBlocks.count)
        let maximumColumnGap = max(0.035, averageWidth * 1.8)
        var columnCenters: [CGFloat] = []
        for block in verticalBlocks {
            let center = block.boundingBox.midX
            if let last = columnCenters.last, abs(center - last) <= maximumColumnGap {
                columnCenters[columnCenters.count - 1] = (last + center) / 2
            } else {
                columnCenters.append(center)
            }
        }
        return columnCenters.count
    }

    /// The vertical model is trained on an image rotated counter-clockwise so
    /// the long edge is horizontal.  These two maps use top-left normalized
    /// coordinates and are kept public through diagnostics helpers for exact
    /// round-trip tests.
    static func rotatedBoundingBoxToOriginal(_ rotatedRect: CGRect) -> CGRect {
        CGRect(
            x: 1 - rotatedRect.minY - rotatedRect.height,
            y: rotatedRect.minX,
            width: rotatedRect.height,
            height: rotatedRect.width
        ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    static func originalBoundingBoxToRotated(_ originalRect: CGRect) -> CGRect {
        CGRect(
            x: originalRect.minY,
            y: 1 - originalRect.minX - originalRect.width,
            width: originalRect.height,
            height: originalRect.width
        ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    static func rotatedBoundingBoxToOriginalForDiagnostics(_ rect: CGRect) -> CGRect {
        rotatedBoundingBoxToOriginal(rect)
    }

    static func originalBoundingBoxToRotatedForDiagnostics(_ rect: CGRect) -> CGRect {
        originalBoundingBoxToRotated(rect)
    }

    private static func tessdataParentPath() -> String? {
        resourceLock.lock()
        defer { resourceLock.unlock() }
        let fileManager = FileManager.default
        let bundles = [Bundle(for: ResourceToken.self), Bundle.main]
        for bundle in bundles {
            for subdirectory in ["Resources/tessdata", "tessdata"] {
                guard let modelURL = bundle.url(
                    forResource: modelName,
                    withExtension: "traineddata",
                    subdirectory: subdirectory
                ) else {
                    continue
                }
                return modelURL.deletingLastPathComponent().path
            }

            // Xcode's synchronized source root intentionally flattens this
            // unknown `.traineddata` extension into the app bundle.  Stage it
            // once into the directory layout expected by Tesseract instead of
            // relying on an undocumented resource-folder preservation rule.
            guard let bundledModel = bundle.url(
                forResource: modelName,
                withExtension: "traineddata"
            ) else {
                continue
            }
            let stagingRoot = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MReaderTessdata", isDirectory: true)
            let tessdataDirectory = stagingRoot.appendingPathComponent("tessdata", isDirectory: true)
            let stagedModel = tessdataDirectory.appendingPathComponent("\(modelName).traineddata")
            do {
                try fileManager.createDirectory(
                    at: tessdataDirectory,
                    withIntermediateDirectories: true
                )
                if !fileManager.fileExists(atPath: stagedModel.path) {
                    try fileManager.copyItem(at: bundledModel, to: stagedModel)
                }
                return tessdataDirectory.path
            } catch {
                print("MReader Japanese vertical OCR resource staging failed: \(error.localizedDescription)")
            }
        }
        return nil
    }

    private static func normalizedImage(_ image: UIImage) -> UIImage? {
        guard image.cgImage != nil else { return nil }
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    private static func rotatedForVerticalOCR(_ image: UIImage) -> UIImage? {
        guard let sourceCGImage = image.cgImage else { return nil }
        let width = CGFloat(sourceCGImage.width)
        let height = CGFloat(sourceCGImage.height)
        let source = UIImage(cgImage: sourceCGImage, scale: 1, orientation: .up)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(
            size: CGSize(width: height, height: width),
            format: format
        ).image { context in
            context.cgContext.translateBy(x: 0, y: width)
            context.cgContext.rotate(by: -.pi / 2)
            source.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private static func recognizeWords(data: Data, dataPath: String) throws -> [RawWord] {
        guard let pix = PixImage(data: data) else {
            throw JapaneseVerticalOCRError.invalidImage
        }
        let api = try TesseractSwiftAPI(
            dataPath: dataPath,
            language: modelName,
            ocrEngineMode: .lstmOnly
        )
        api.pageSegmentationMode = .sparseText
        _ = try? api.setVariable(name: "tessedit_write_block_separators", bool: false)
        _ = try? api.setVariable(name: "tessedit_write_line_separators", bool: false)
        try api.setImage(pix)
        try api.recognize()
        return parseTSV(try api.getTSVText() ?? "")
    }

    private static func parseTSV(_ tsv: String) -> [RawWord] {
        tsv.split(whereSeparator: \.isNewline).compactMap { substring in
            let fields = substring.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 12,
                  fields[0] == "5",
                  let left = Double(fields[6]),
                  let top = Double(fields[7]),
                  let width = Double(fields[8]),
                  let height = Double(fields[9]),
                  let confidence = Double(fields[10]),
                  width > 0,
                  height > 0,
                  confidence >= 0 else {
                return nil
            }
            let text = String(fields[11]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            // The actual pixel dimensions are applied by the caller.  TSV is
            // retained in pixel space here to avoid losing precision early.
            return RawWord(
                text: text,
                rotatedBoundingBox: CGRect(x: left, y: top, width: width, height: height),
                confidence: confidence / 100
            )
        }
    }

    /// Lightweight image evidence for the no-observation case.  It counts
    /// separated narrow ink columns with support across several horizontal
    /// bands; broad horizontal prose does not normally satisfy both tests.
    private static func verticalColumnEvidence(in image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        let maxWidth = 160
        let maxHeight = 240
        let scale = min(
            1,
            min(CGFloat(maxWidth) / CGFloat(cgImage.width), CGFloat(maxHeight) / CGFloat(cgImage.height))
        )
        let width = max(Int(CGFloat(cgImage.width) * scale), 1)
        let height = max(Int(CGFloat(cgImage.height) * scale), 1)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var candidates = [Bool](repeating: false, count: width)
        for x in 0..<width {
            var darkPixels = 0
            var occupiedBands = Set<Int>()
            for y in 0..<height {
                let offset = (y * width + x) * 4
                let luminance = (Int(pixels[offset]) * 299
                    + Int(pixels[offset + 1]) * 587
                    + Int(pixels[offset + 2]) * 114) / 1000
                if luminance < 150 {
                    darkPixels += 1
                    occupiedBands.insert(min(7, y * 8 / max(height, 1)))
                }
            }
            candidates[x] = darkPixels >= max(4, height / 32) && occupiedBands.count >= 4
        }

        var groups: [(start: Int, end: Int)] = []
        var start: Int?
        for x in 0..<width {
            if candidates[x] {
                start = start ?? x
            } else if let currentStart = start {
                groups.append((currentStart, x - 1))
                start = nil
            }
        }
        if let currentStart = start {
            groups.append((currentStart, width - 1))
        }
        let maximumGroupWidth = max(Int(CGFloat(width) * 0.28), 4)
        return groups.filter { $0.end - $0.start + 1 <= maximumGroupWidth }.count
    }
}

private enum JapaneseVerticalOCRError: LocalizedError {
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .invalidImage: return "无法将页面交给日文竖排 OCR"
        }
    }
}
