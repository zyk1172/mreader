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

/// Runtime provenance for an observed OCR baseline. These values describe the
/// environment that produced the observation; they are not quality metrics.
struct TranslationBaselineCapture: Codable, Equatable, Sendable {
    let capturedAt: String?
    let commitSHA: String?
    let workflowRunID: String?
    let xcodeVersion: String?
    let xcodeBuild: String?
    let sdkName: String?
    let platformName: String
    let platformVersion: String
    let deviceModel: String
    let captureSource: String
}

struct TranslationFirstPageBaselineReport: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let sampleID: String
    let capture: TranslationBaselineCapture?
    let detectedLanguage: String?
    let elapsedMilliseconds: Double
    let rawCount: Int
    let resolvedCount: Int
    let lineCount: Int
    /// Number of output blocks produced by the grouping stage. This does not
    /// imply that the same number of physical speech balloons were detected.
    let bubbleBlockCount: Int
    /// Unique non-nil physical bubble rectangles carried by output blocks.
    let physicalBubbleCount: Int
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
    static let schemaVersion = 2

    @MainActor
    static func makeReport(
        sampleID: String,
        result: OCRPipelineResult,
        elapsedMilliseconds: Double,
        capture: TranslationBaselineCapture? = nil
    ) -> TranslationFirstPageBaselineReport {
        let physicalBubbleKeys = Set(
            result.bubbleBlocks.compactMap { block in
                block.bubbleBox.map(physicalBubbleKey)
            }
        )
        return TranslationFirstPageBaselineReport(
            schemaVersion: schemaVersion,
            sampleID: sampleID,
            capture: capture,
            detectedLanguage: result.detectedLanguage,
            elapsedMilliseconds: max(elapsedMilliseconds, 0),
            rawCount: result.rawBlocks.count,
            resolvedCount: result.resolvedBlocks.count,
            lineCount: result.lineBlocks.count,
            bubbleBlockCount: result.bubbleBlocks.count,
            physicalBubbleCount: physicalBubbleKeys.count,
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
    /// a person must correct text/geometry/order/grouping, explicitly determine
    /// the expected page state, and only then flip the verification status.
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
            expectedPageState: .unknown,
            regions: regions,
            referenceTranslations: [:],
            notes: "Machine-assisted candidate generated from MangaOCRPipeline. Human review must correct text, normalized regions, reading order and bubble grouping, then explicitly resolve expectedPageState before marking humanVerified. Reference translations remain intentionally empty until reviewed."
        )
    }

    @MainActor
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

    private static func physicalBubbleKey(_ rect: CGRect) -> String {
        let values = [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height].map {
            Int(($0 * 10_000).rounded())
        }
        return values.map(String.init).joined(separator: ":")
    }

    private static func bubbleID(for rect: TranslationBenchmarkRect?) -> String? {
        guard let rect else { return nil }
        let values = [rect.x, rect.y, rect.width, rect.height].map {
            Int(($0 * 10_000).rounded())
        }
        return "bubble-" + values.map(String.init).joined(separator: "-")
    }
}
