import CoreGraphics
import Foundation
@testable import mreader

struct TranslationBaselineBlock: Codable, Equatable, Sendable {
    let id: String
    let text: String
    let rect: TranslationBenchmarkRect
    let confidence: Double
    let source: String
    let orientation: String
    let role: String
    let bubbleRect: TranslationBenchmarkRect?
    let layoutSafeRegion: TranslationBenchmarkRect?
    let filterReason: String?
}

struct TranslationBaselineQuality: Codable, Equatable, Sendable {
    let score: Double
    let averageConfidence: Double
    let characterCount: Int
    let blockCount: Int
    let verticalColumnCount: Int
    let japaneseScriptRatio: Double
    let kanaCount: Int
    let hanCount: Int
    let latinCount: Int
    let visionKitCharacterCount: Int
    let visionKitCoverage: Double
    let suspicious: Bool
}

struct TranslationFirstPageBaselineReport: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let sampleID: String
    let detectedLanguage: String?
    let elapsedMilliseconds: Double
    let rawCount: Int
    let resolvedCount: Int
    let lineCount: Int
    let bubbleCount: Int
    let rejectedCount: Int
    let quality: TranslationBaselineQuality?
    let lineBlocks: [TranslationBaselineBlock]
    let bubbleBlocks: [TranslationBaselineBlock]
    let rejectedBlocks: [TranslationBaselineBlock]

    var transcript: String {
        bubbleBlocks.map(\.text).joined(separator: "\n")
    }
}

enum TranslationFirstPageBaseline {
    static let schemaVersion = 1

    static func makeReport(
        sampleID: String,
        result: OCRPipelineResult,
        elapsedMilliseconds: Double
    ) -> TranslationFirstPageBaselineReport {
        TranslationFirstPageBaselineReport(
            schemaVersion: schemaVersion,
            sampleID: sampleID,
            detectedLanguage: result.detectedLanguage,
            elapsedMilliseconds: max(elapsedMilliseconds, 0),
            rawCount: result.rawBlocks.count,
            resolvedCount: result.resolvedBlocks.count,
            lineCount: result.lineBlocks.count,
            bubbleCount: result.bubbleBlocks.count,
            rejectedCount: result.rejectedBlocks.count,
            quality: result.quality.map { quality in
                TranslationBaselineQuality(
                    score: quality.score,
                    averageConfidence: quality.averageConfidence,
                    characterCount: quality.characterCount,
                    blockCount: quality.blockCount,
                    verticalColumnCount: quality.verticalColumnCount,
                    japaneseScriptRatio: quality.japaneseScriptRatio,
                    kanaCount: quality.kanaCount,
                    hanCount: quality.hanCount,
                    latinCount: quality.latinCount,
                    visionKitCharacterCount: quality.visionKitCharacterCount,
                    visionKitCoverage: quality.visionKitCoverage,
                    suspicious: quality.isSuspicious
                )
            },
            lineBlocks: result.lineBlocks.map(makeBlock),
            bubbleBlocks: result.bubbleBlocks.map(makeBlock),
            rejectedBlocks: result.rejectedBlocks.map(makeBlock)
        )
    }

    /// Produces a machine-assisted annotation candidate from the exact local OCR
    /// pipeline that ships in the app. It is deliberately never reportable gold:
    /// a person must correct text/geometry/order/grouping and flip the verification
    /// status only after comparing every region against the source page.
    static func candidateGold(
        sampleID: String,
        report: TranslationFirstPageBaselineReport
    ) -> TranslationBenchmarkPageGold {
        let regions = report.lineBlocks.enumerated().map { index, block in
            TranslationBenchmarkRegion(
                id: String(format: "region-%03d", index + 1),
                text: block.text,
                rect: block.rect,
                readingOrder: index,
                bubbleID: bubbleID(for: block.bubbleRect)
            )
        }
        return TranslationBenchmarkPageGold(
            schemaVersion: 1,
            sampleID: sampleID,
            verificationStatus: .candidate,
            expectedPageState: regions.isEmpty ? .noText : .completed,
            regions: regions,
            referenceTranslations: [:],
            notes: "Machine-assisted candidate generated from MangaOCRPipeline. Human review must correct text, normalized regions, reading order and bubble grouping before marking humanVerified. Reference translations remain intentionally empty until reviewed."
        )
    }

    private static func makeBlock(_ block: TextBlock) -> TranslationBaselineBlock {
        TranslationBaselineBlock(
            id: block.id.uuidString,
            text: block.text,
            rect: benchmarkRect(block.boundingBox),
            confidence: block.confidence,
            source: block.ocrSource,
            orientation: block.textOrientation.rawValue,
            role: block.translationContentRole.rawValue,
            bubbleRect: block.bubbleBox.map(benchmarkRect),
            layoutSafeRegion: block.layoutSafeRegion.map(benchmarkRect),
            filterReason: block.filterReason
        )
    }

    private static func benchmarkRect(_ rect: CGRect) -> TranslationBenchmarkRect {
        TranslationBenchmarkRect(
            x: Double(rect.origin.x),
            y: Double(rect.origin.y),
            width: Double(rect.size.width),
            height: Double(rect.size.height)
        )
    }

    private static func bubbleID(for rect: TranslationBenchmarkRect?) -> String? {
        guard let rect else { return nil }
        let values = [rect.x, rect.y, rect.width, rect.height].map {
            Int(($0 * 10_000).rounded())
        }
        return "bubble-" + values.map(String.init).joined(separator: "-")
    }
}
