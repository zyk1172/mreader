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

nonisolated struct JapaneseVerticalOCRDiagnosticWord: Equatable, Sendable {
    let text: String
    let rotatedBoundingBox: CGRect
    let confidence: Double
    let blockNumber: Int
    let paragraphNumber: Int
    let lineNumber: Int
    let wordNumber: Int
}

nonisolated struct JapaneseVerticalOCRFragmentationQuality: Equatable, Sendable {
    let rawWordCount: Int
    let groupedRunCount: Int
    let totalCharacterCount: Int
    let averageCharactersPerRun: Double
    let medianGlyphSize: Double

    func isSeverelyFragmented(
        referenceCharacterCount: Int? = nil,
        visionBlockCount: Int = 0
    ) -> Bool {
        guard groupedRunCount >= 48,
              averageCharactersPerRun < 2.2 else { return false }
        let referenceMismatch = referenceCharacterCount.map {
            $0 >= max(totalCharacterCount + 12, totalCharacterCount * 2)
                || $0 >= groupedRunCount * 2
        } ?? false
        let visionMismatch = visionBlockCount > 0
            && groupedRunCount >= max(48, visionBlockCount * 5)
        // A page which still contains dozens of one-character runs after the
        // geometry pass is not safe to inject into the translation pipeline,
        // even when a reference transcript is unavailable.
        return groupedRunCount >= 80 || referenceMismatch || visionMismatch
    }
}

/// Tesseract is not the primary OCR engine in MReader.  This service only
/// owns the narrow escape hatch for pages where Vision has evidence of
/// Japanese vertical writing but its result is incomplete. Automatic mode
/// uses kana, Japanese source hints, and vertical Kanji evidence; it does not
/// require the reader's page direction to be RTL.
nonisolated enum JapaneseVerticalOCRService {
    static let revision = "jpn-vert-tesseract-5.5.1-v4-geometry-gated"
    static let minimumAverageConfidence = 0.58
    static let minimumUsefulCharacterRatio = 0.42

    private static let modelName = "jpn_vert"
    private static let sourceName = "tesseract:jpn_vert"
    private static let resourceLock = NSLock()

    private struct RawTSVRecord: Sendable {
        let pageNumber: Int
        let blockNumber: Int
        let paragraphNumber: Int
        let lineNumber: Int
        let wordNumber: Int
        let text: String
        let rotatedBoundingBox: CGRect
        let confidence: Double
    }

    private struct RawWord: Sendable {
        let text: String
        let rotatedBoundingBox: CGRect
        let confidence: Double
        let blockNumber: Int
        let paragraphNumber: Int
        let lineNumber: Int
        let wordNumber: Int
        let glyphThickness: CGFloat
    }

    private struct TSVGroupingResult: Sendable {
        let words: [RawWord]
        let quality: JapaneseVerticalOCRFragmentationQuality
    }

    private final class ResourceToken {}

    /// Runs only for an explicitly Japanese page, or for automatic detection
    /// with Japanese script/vertical-page evidence. A Chinese/English/Korean
    /// page therefore never pays for the Tesseract pass merely because the
    /// reader is RTL.
    static func recognizeIfNeeded(
        in image: UIImage,
        existingBlocks: [TextBlock],
        options: OCRPreprocessor.Options,
        visionKitReference: AppleOCRReference? = nil
    ) async -> [TextBlock] {
        guard shouldRunFallback(
            in: image,
            existingBlocks: existingBlocks,
            options: options,
            visionKitReference: visionKitReference
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

            let fragmentation = rawWords.quality
            guard !fragmentation.isSeverelyFragmented(
                referenceCharacterCount: visionKitReference?.characterCount,
                visionBlockCount: existingBlocks.count
            ) else {
                print("MReader Japanese vertical OCR rejected fragmented output raw=\(fragmentation.rawWordCount) grouped=\(fragmentation.groupedRunCount) chars=\(fragmentation.totalCharacterCount) charsPerRun=\(String(format: "%.2f", fragmentation.averageCharactersPerRun)) referenceChars=\(visionKitReference?.characterCount ?? 0) visionBlocks=\(existingBlocks.count)")
                return []
            }

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

            let blocks = rawWords.words.compactMap { word -> TextBlock? in
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
                    // In vertical mode the normalized original width is the
                    // glyph thickness. Use the robust run estimate instead of
                    // the merged column's long axis.
                    estimatedFontScale: Double(word.glyphThickness / max(rotatedPixelSize.height, 1)),
                    textOrientation: .vertical
                )
            }
            print("MReader Japanese vertical OCR fallback blocks=\(blocks.count) raw=\(fragmentation.rawWordCount) grouped=\(fragmentation.groupedRunCount) chars=\(fragmentation.totalCharacterCount) charsPerRun=\(String(format: "%.2f", fragmentation.averageCharactersPerRun))")
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
        options: OCRPreprocessor.Options,
        visionKitReference: AppleOCRReference? = nil
    ) -> Bool {
        guard isJapaneseRecoveryCandidate(
            in: image,
            existingBlocks: existingBlocks,
            isRightToLeft: options.isRightToLeft,
            sourceLanguagePreference: options.sourceLanguagePreference,
            visionKitReference: visionKitReference
        ) else {
            return false
        }

        // Maximum accuracy is an explicit cost/quality choice, but the reader
        // direction is not OCR language metadata. Require at least one local
        // vertical OCR column; image-only dark columns are never sufficient.
        if options.recognitionMode == .maximumAccuracy {
            return verticalColumnCount(in: existingBlocks) >= 1
        }

        return shouldRequestPageRecovery(
            in: image,
            existingBlocks: existingBlocks,
            isRightToLeft: options.isRightToLeft,
            sourceLanguagePreference: options.sourceLanguagePreference,
            visionKitReference: visionKitReference
        )
    }

    static func shouldRequestPageRecovery(
        in image: UIImage?,
        existingBlocks: [TextBlock],
        isRightToLeft: Bool,
        sourceLanguagePreference: TranslationSourceLanguage?,
        visionKitReference: AppleOCRReference? = nil
    ) -> Bool {
        guard isJapaneseRecoveryCandidate(
            in: image,
            existingBlocks: existingBlocks,
            isRightToLeft: isRightToLeft,
            sourceLanguagePreference: sourceLanguagePreference,
            visionKitReference: visionKitReference
        ) else {
            return false
        }

        let localColumnCenters = verticalColumnCenters(in: existingBlocks)
        let imageColumnCenters = image.map(verticalColumnEvidenceCenters(in:)) ?? []
        let coverage = coverage(for: existingBlocks, isRightToLeft: isRightToLeft)
        guard coverage.isInsufficient else { return false }

        // Keep recovery for pages where local OCR already supplies multiple
        // vertical columns. The image probe may add confidence only when it
        // overlaps at least one local OCR column; it cannot create Japanese
        // evidence from artwork lines on its own.
        if localColumnCenters.count >= 2 { return true }
        guard imageColumnCenters.count >= 2,
              hasSpatiallyMatchedImageEvidence(
                imageColumnCenters,
                localColumnCenters: localColumnCenters,
                existingBlocks: existingBlocks
              ) else {
            return false
        }
        guard let visionKitReference,
              visionKitReference.isJapaneseEvidence else {
            return false
        }
        return true
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

    private static func isJapaneseRecoveryCandidate(
        in image: UIImage?,
        existingBlocks: [TextBlock],
        isRightToLeft: Bool,
        sourceLanguagePreference: TranslationSourceLanguage?,
        visionKitReference: AppleOCRReference?
    ) -> Bool {
        if isJapanesePage(
            existingBlocks: existingBlocks,
            preference: sourceLanguagePreference
        ) {
            return true
        }
        if let visionKitReference,
           AppleOCRReferenceService.suggestsJapanese(
                visionKitReference,
                blocks: existingBlocks,
                options: OCRPreprocessor.Options(
                    isRightToLeft: isRightToLeft,
                    minimumTextHeight: 0.006,
                    sourceLanguagePreference: sourceLanguagePreference
                ),
                image: image
           ) {
            return true
        }
        guard sourceLanguagePreference == nil || sourceLanguagePreference == .automatic else {
            return false
        }

        // Automatic mode cannot use kana as its only Japanese signal: a
        // poorly recognized page may contain only Kanji. Treat Kanji-only
        // text as a Japanese recovery candidate when there is vertical-page
        // evidence or a Japanese OCR pass hint. Reader paging direction is
        // deliberately excluded from this language decision.
        let hasCJK = existingBlocks
            .map(\.text)
            .joined()
            .unicodeScalars
            .contains { scalar in
                (0x3400...0x4DBF).contains(scalar.value)
                    || (0x4E00...0x9FFF).contains(scalar.value)
                    || (0xF900...0xFAFF).contains(scalar.value)
            }
        guard hasCJK else { return false }
        if existingBlocks.contains(where: { block in
            let source = block.ocrSource.lowercased()
            return source.contains(":ja") || source.contains("-ja") || source.contains("_ja")
        }) {
            return true
        }
        if verticalColumnCount(in: existingBlocks) >= 1 {
            return true
        }
        // RTL reading can affect sorting/layout, but must not be promoted to
        // Japanese OCR evidence. Without kana, Japanese OCR source hints, or
        // local OCR vertical geometry, an automatic CJK page remains ambiguous.
        return false
    }

    private static func hasSpatiallyMatchedImageEvidence(
        _ imageCenters: [CGFloat],
        localColumnCenters: [CGFloat],
        existingBlocks: [TextBlock]
    ) -> Bool {
        guard !localColumnCenters.isEmpty else { return false }
        let tolerance = max(
            0.05,
            verticalColumnAverageWidth(in: existingBlocks) * 2.4
        )
        let hasMatchedColumn = imageCenters.contains { imageCenter in
            localColumnCenters.contains { localCenter in
                abs(imageCenter - localCenter) <= tolerance
            }
        }
        let hasUncoveredColumn = imageCenters.contains { imageCenter in
            !localColumnCenters.contains { localCenter in
                abs(imageCenter - localCenter) <= tolerance
            }
        }
        return hasMatchedColumn && hasUncoveredColumn
    }

    /// Returns the number of separated vertical text columns represented by
    /// local OCR observations.  This is intentionally a diagnostic-friendly
    /// pure function so it can be regression-tested without Vision or a model.
    static func verticalColumnCount(in blocks: [TextBlock]) -> Int {
        verticalColumnCenters(in: blocks).count
    }

    /// Exposes lightweight image evidence for diagnostics only. It must not be
    /// used as a standalone trigger for Japanese recovery.
    static func verticalColumnEvidenceCount(in image: UIImage) -> Int {
        verticalColumnEvidenceCenters(in: image).count
    }

    private static func verticalColumnCenters(in blocks: [TextBlock]) -> [CGFloat] {
        let verticalBlocks = blocks
            .filter { block in
                block.textOrientation == .vertical
                    || block.boundingBox.height >= block.boundingBox.width * 1.35
            }
            .sorted { $0.boundingBox.midX < $1.boundingBox.midX }
        guard !verticalBlocks.isEmpty else { return [] }

        let averageWidth = verticalColumnAverageWidth(in: verticalBlocks)
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
        return columnCenters
    }

    private static func verticalColumnAverageWidth(in blocks: [TextBlock]) -> CGFloat {
        let verticalBlocks = blocks.filter { block in
            block.textOrientation == .vertical
                || block.boundingBox.height >= block.boundingBox.width * 1.35
        }
        guard !verticalBlocks.isEmpty else { return 0 }
        return verticalBlocks.reduce(0) { $0 + $1.boundingBox.width }
            / CGFloat(verticalBlocks.count)
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

    private static func recognizeWords(data: Data, dataPath: String) throws -> TSVGroupingResult {
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
        return parseTSVResult(try api.getTSVText() ?? "")
    }

    private static func parseTSV(_ tsv: String) -> [RawWord] {
        parseTSVResult(tsv).words
    }

    private static func parseTSVResult(_ tsv: String) -> TSVGroupingResult {
        let records = parseTSVRecords(tsv)
        let words = groupTSVRecords(records)
        let totalCharacters = words.reduce(0) { $0 + $1.text.unicodeScalars.count }
        let averageCharactersPerRun = words.isEmpty
            ? 0
            : Double(totalCharacters) / Double(words.count)
        return TSVGroupingResult(
            words: words,
            quality: JapaneseVerticalOCRFragmentationQuality(
                rawWordCount: records.count,
                groupedRunCount: words.count,
                totalCharacterCount: totalCharacters,
                averageCharactersPerRun: averageCharactersPerRun,
                medianGlyphSize: Double(median(records.map { max($0.rotatedBoundingBox.width, $0.rotatedBoundingBox.height) }))
            )
        )
    }

    /// Diagnostic parser used by regression tests. It exercises the same
    /// hierarchy-aware grouping as the production Tesseract path without
    /// requiring a bundled image or a live OCR engine.
    static func parseTSVForDiagnostics(_ tsv: String) -> [JapaneseVerticalOCRDiagnosticWord] {
        parseTSVResult(tsv).words.map {
            JapaneseVerticalOCRDiagnosticWord(
                text: $0.text,
                rotatedBoundingBox: $0.rotatedBoundingBox,
                confidence: $0.confidence,
                blockNumber: $0.blockNumber,
                paragraphNumber: $0.paragraphNumber,
                lineNumber: $0.lineNumber,
                wordNumber: $0.wordNumber
            )
        }
    }

    static func fragmentationQualityForDiagnostics(
        _ tsv: String
    ) -> JapaneseVerticalOCRFragmentationQuality {
        parseTSVResult(tsv).quality
    }

    private static func parseTSVRecords(_ tsv: String) -> [RawTSVRecord] {
        tsv.split(whereSeparator: \.isNewline).compactMap { substring in
            let fields = substring.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 12,
                  fields[0] == "5",
                  let pageNumber = Int(fields[1]),
                  let blockNumber = Int(fields[2]),
                  let paragraphNumber = Int(fields[3]),
                  let lineNumber = Int(fields[4]),
                  let wordNumber = Int(fields[5]),
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
            return RawTSVRecord(
                pageNumber: pageNumber,
                blockNumber: blockNumber,
                paragraphNumber: paragraphNumber,
                lineNumber: lineNumber,
                wordNumber: wordNumber,
                text: text,
                rotatedBoundingBox: CGRect(x: left, y: top, width: width, height: height),
                confidence: confidence / 100
            )
        }
    }

    private static func groupTSVRecords(_ records: [RawTSVRecord]) -> [RawWord] {
        guard !records.isEmpty else { return [] }

        // Tesseract's page/block/paragraph/line fields are only affinity hints.
        // In Japanese vertical pages a single column is frequently emitted as
        // one TSV hierarchy per glyph, so geometry is the actual reconstruction
        // boundary. Rotation makes an original vertical column a horizontal row:
        // rotated Y identifies the column, rotated X is top-to-bottom order.
        var output: [RawWord] = []
        let pages = Dictionary(grouping: records, by: \.pageNumber)
        for pageNumber in pages.keys.sorted() {
            guard let pageRecords = pages[pageNumber] else { continue }
            let typicalThickness = median(pageRecords.map { $0.rotatedBoundingBox.height })
            var columns: [[RawTSVRecord]] = []

            for record in pageRecords.sorted(by: spatialRecordOrder) {
                let candidateIndex = columns.indices
                    .compactMap { index -> (index: Int, distance: CGFloat)? in
                        let column = columns[index]
                        let center = median(column.map { $0.rotatedBoundingBox.midY })
                        let thickness = median(column.map { $0.rotatedBoundingBox.height })
                        let minimumThickness = min(thickness, record.rotatedBoundingBox.height)
                        let maximumThickness = max(thickness, record.rotatedBoundingBox.height)
                        let similarSize = minimumThickness > 0
                            && maximumThickness / minimumThickness <= 1.8
                        let tolerance = max(
                            typicalThickness * 1.20,
                            minimumThickness * 0.75,
                            4
                        )
                        guard similarSize,
                              abs(record.rotatedBoundingBox.midY - center) <= tolerance else {
                            return nil
                        }
                        return (index, abs(record.rotatedBoundingBox.midY - center))
                    }
                    .min { $0.distance < $1.distance }

                if let candidateIndex {
                    columns[candidateIndex.index].append(record)
                } else {
                    columns.append([record])
                }
            }

            for column in columns.sorted(by: { lhs, rhs in
                median(lhs.map { $0.rotatedBoundingBox.midY })
                    < median(rhs.map { $0.rotatedBoundingBox.midY })
            }) {
                let sorted = column.sorted(by: spatialRecordXOrder)
                let typicalAdvance = median(sorted.map { $0.rotatedBoundingBox.width })
                let typicalSize = median(sorted.map { $0.rotatedBoundingBox.height })
                let maximumGap = max(typicalAdvance * 2.0, 8)
                var runs: [[RawTSVRecord]] = []

                for record in sorted {
                    guard let previous = runs.last?.last else {
                        runs.append([record])
                        continue
                    }
                    let gap = record.rotatedBoundingBox.minX - previous.rotatedBoundingBox.maxX
                    let minimumSize = min(typicalSize, record.rotatedBoundingBox.height)
                    let maximumSize = max(typicalSize, record.rotatedBoundingBox.height)
                    let similarSize = minimumSize > 0 && maximumSize / minimumSize <= 1.8
                    if gap <= maximumGap && similarSize {
                        runs[runs.count - 1].append(record)
                    } else {
                        runs.append([record])
                    }
                }

                for run in runs {
                    guard let first = run.first else { continue }
                    let union = run.dropFirst().reduce(first.rotatedBoundingBox) { $0.union($1.rotatedBoundingBox) }
                    output.append(RawWord(
                        text: run.map(\.text).joined(),
                        rotatedBoundingBox: union,
                        confidence: run.reduce(0) { $0 + $1.confidence } / Double(run.count),
                        blockNumber: first.blockNumber,
                        paragraphNumber: first.paragraphNumber,
                        lineNumber: first.lineNumber,
                        wordNumber: first.wordNumber,
                        glyphThickness: median(run.map { $0.rotatedBoundingBox.height })
                    ))
                }
            }
        }
        return output
    }

    private static func spatialRecordOrder(_ lhs: RawTSVRecord, _ rhs: RawTSVRecord) -> Bool {
        if lhs.pageNumber != rhs.pageNumber { return lhs.pageNumber < rhs.pageNumber }
        if lhs.rotatedBoundingBox.midY != rhs.rotatedBoundingBox.midY {
            return lhs.rotatedBoundingBox.midY < rhs.rotatedBoundingBox.midY
        }
        return spatialRecordXOrder(lhs, rhs)
    }

    private static func spatialRecordXOrder(_ lhs: RawTSVRecord, _ rhs: RawTSVRecord) -> Bool {
        if lhs.rotatedBoundingBox.minX != rhs.rotatedBoundingBox.minX {
            return lhs.rotatedBoundingBox.minX < rhs.rotatedBoundingBox.minX
        }
        if lhs.blockNumber != rhs.blockNumber { return lhs.blockNumber < rhs.blockNumber }
        if lhs.lineNumber != rhs.lineNumber { return lhs.lineNumber < rhs.lineNumber }
        return lhs.wordNumber < rhs.wordNumber
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 1 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// Lightweight image evidence for both empty and partial OCR results. It
    /// returns normalized column centers so the caller can distinguish a
    /// column already covered by Vision from a column that was missed.
    private static func verticalColumnEvidenceCenters(in image: UIImage) -> [CGFloat] {
        guard let cgImage = image.cgImage else { return [] }
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
        ) else { return [] }
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
        return groups
            .filter { $0.end - $0.start + 1 <= maximumGroupWidth }
            .map { CGFloat($0.start + $0.end + 1) / (2 * CGFloat(width)) }
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
