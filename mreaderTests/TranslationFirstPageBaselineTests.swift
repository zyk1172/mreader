import Foundation
import UIKit
import XCTest
@testable import mreader

final class TranslationFirstPageBaselineTests: XCTestCase {
    @MainActor
    func testCandidateGeneratedFromObservedPipelineDataRemainsNonReportable() throws {
        let line = TextBlock(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            text: "テストです。",
            boundingBox: CGRect(x: 0.60, y: 0.20, width: 0.18, height: 0.10),
            confidence: 0.93,
            ocrSource: "vision:dialogue",
            bubbleBox: CGRect(x: 0.56, y: 0.16, width: 0.28, height: 0.20),
            layoutSafeRegion: CGRect(x: 0.58, y: 0.18, width: 0.24, height: 0.16),
            textOrientation: .horizontal,
            layoutRole: .dialogue
        )
        let result = OCRPipelineResult(
            rawBlocks: [line],
            resolvedBlocks: [line],
            lineBlocks: [line],
            bubbleBlocks: [line],
            rejectedBlocks: [],
            detectedLanguage: "ja"
        )
        let report = TranslationFirstPageBaseline.makeReport(
            sampleID: "fixture",
            result: result,
            elapsedMilliseconds: 42
        )
        let candidate = TranslationFirstPageBaseline.candidateGold(
            sampleID: "fixture",
            report: report
        )

        XCTAssertEqual(report.schemaVersion, 2)
        XCTAssertEqual(report.lineCount, 1)
        XCTAssertEqual(report.bubbleBlockCount, 1)
        XCTAssertEqual(report.physicalBubbleCount, 1)
        XCTAssertEqual(report.transcript, "テストです。")
        XCTAssertEqual(candidate.verificationStatus, .candidate)
        XCTAssertEqual(candidate.expectedPageState, .unknown)
        XCTAssertFalse(candidate.isReportableGold)
        XCTAssertEqual(candidate.regions.count, 1)
        XCTAssertEqual(candidate.regions[0].text, "テストです。")
        XCTAssertNotNil(candidate.regions[0].bubbleID)
    }

    @MainActor
    func testBubbleBlockCountDoesNotPretendEveryGroupHasPhysicalBubble() {
        let line = TextBlock(
            text: "枠なし",
            boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.1, height: 0.2),
            confidence: 0.9,
            ocrSource: "vision:sfx",
            bubbleBox: nil,
            textOrientation: .vertical,
            layoutRole: .standalone
        )
        let result = OCRPipelineResult(
            rawBlocks: [line],
            resolvedBlocks: [line],
            lineBlocks: [line],
            bubbleBlocks: [line],
            rejectedBlocks: [],
            detectedLanguage: "ja"
        )

        let report = TranslationFirstPageBaseline.makeReport(
            sampleID: "fixture",
            result: result,
            elapsedMilliseconds: 1
        )

        XCTAssertEqual(report.bubbleBlockCount, 1)
        XCTAssertEqual(report.physicalBubbleCount, 0)
    }

    func testHumanVerifiedUnknownStateStillCannotBecomeReportableGold() {
        let annotation = TranslationBenchmarkPageGold(
            schemaVersion: 1,
            sampleID: "fixture",
            verificationStatus: .humanVerified,
            expectedPageState: .unknown,
            regions: [],
            referenceTranslations: [:],
            notes: nil
        )

        XCTAssertTrue(annotation.isInternallyConsistent)
        XCTAssertFalse(annotation.isReportableGold)
    }

    func testShirohageFixtureCannotBeScoredBeforeHumanVerification() throws {
        let manifest: TranslationQualityBenchmarkManifest = try decodeFixture(
            "translation_quality_manifest",
            extension: "json"
        )
        let sample = try XCTUnwrap(
            manifest.samples.first { $0.id == "manga-page-shirohage-ja" }
        )
        XCTAssertEqual(sample.annotationStatus, .pending)

        if let goldAnnotation = sample.goldAnnotation {
            let url = URL(fileURLWithPath: goldAnnotation)
            let gold: TranslationBenchmarkPageGold = try decodeFixture(
                url.deletingPathExtension().lastPathComponent,
                extension: url.pathExtension
            )
            XCTAssertFalse(gold.isReportableGold)
            XCTAssertEqual(gold.verificationStatus, .candidate)
            XCTAssertEqual(gold.expectedPageState, .unknown)
        }
    }

    /// Opt-in benchmark against the actual licensed manga page. Normal CI skips
    /// this because Vision output is OS/runtime dependent and the point is to
    /// capture a baseline, not to turn one simulator OCR result into a golden
    /// assertion. Set MREADER_RUN_PAGE_BENCHMARK=1 to execute it.
    @MainActor
    func testGenerateShirohagePageBaselineWhenOptedIn() async throws {
        guard ProcessInfo.processInfo.environment["MREADER_RUN_PAGE_BENCHMARK"] == "1" else {
            throw XCTSkip("Set MREADER_RUN_PAGE_BENCHMARK=1 to run the real-page OCR baseline.")
        }

        let bundle = Bundle(for: TranslationFirstPageBaselineTests.self)
        let imageURL = try XCTUnwrap(
            bundle.url(
                forResource: "sample_shirohage_manga",
                withExtension: "jpg",
                subdirectory: "Fixtures"
            ) ?? bundle.url(
                forResource: "sample_shirohage_manga",
                withExtension: "jpg"
            )
        )
        let image = try XCTUnwrap(UIImage(contentsOfFile: imageURL.path))

        var options = OCRPreprocessor.Options(
            isRightToLeft: true,
            minimumTextHeight: 0.006
        )
        options.languages = ["ja-JP", "zh-Hans", "zh-Hant", "ko-KR", "en-US"]
        options.recognitionMode = .maximumAccuracy
        options.sourceLanguagePreference = .japanese

        let startedAt = CFAbsoluteTimeGetCurrent()
        let result = try await MangaOCRPipeline.recognize(in: image, options: options)
        let elapsedMilliseconds = (CFAbsoluteTimeGetCurrent() - startedAt) * 1_000
        let report = TranslationFirstPageBaseline.makeReport(
            sampleID: "manga-page-shirohage-ja",
            result: result,
            elapsedMilliseconds: elapsedMilliseconds,
            capture: currentCapture()
        )
        let candidate = TranslationFirstPageBaseline.candidateGold(
            sampleID: "manga-page-shirohage-ja",
            report: report
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let reportData = try encoder.encode(report)
        let candidateData = try encoder.encode(candidate)

        let reportAttachment = XCTAttachment(data: reportData, uniformTypeIdentifier: "public.json")
        reportAttachment.name = "sample_shirohage_manga.baseline.json"
        reportAttachment.lifetime = .keepAlways
        add(reportAttachment)

        let candidateAttachment = XCTAttachment(data: candidateData, uniformTypeIdentifier: "public.json")
        candidateAttachment.name = "sample_shirohage_manga.gold.candidate.json"
        candidateAttachment.lifetime = .keepAlways
        add(candidateAttachment)

        print("MREADER_BASELINE_BASE64=\(reportData.base64EncodedString())")
        print("MREADER_CANDIDATE_BASE64=\(candidateData.base64EncodedString())")
        print(
            "MReader benchmark sample=manga-page-shirohage-ja language=\(report.detectedLanguage ?? "unknown") "
                + "raw=\(report.rawCount) resolved=\(report.resolvedCount) lines=\(report.lineCount) "
                + "bubbleBlocks=\(report.bubbleBlockCount) physicalBubbles=\(report.physicalBubbleCount) "
                + "rejected=\(report.rejectedCount) elapsedMs=\(String(format: "%.0f", report.elapsedMilliseconds))"
        )

        XCTAssertEqual(report.sampleID, "manga-page-shirohage-ja")
        XCTAssertNotNil(report.capture)
        XCTAssertEqual(candidate.expectedPageState, .unknown)
        XCTAssertFalse(candidate.isReportableGold)
    }

    @MainActor
    private func currentCapture() -> TranslationBaselineCapture {
        let environment = ProcessInfo.processInfo.environment
        let info = Bundle.main.infoDictionary ?? [:]
        let isGitHubActions = environment["GITHUB_ACTIONS"] == "true"
        return TranslationBaselineCapture(
            commitSHA: environment["MREADER_BENCHMARK_COMMIT_SHA"] ?? environment["GITHUB_SHA"],
            xcodeVersion: info["DTXcode"] as? String,
            xcodeBuild: info["DTXcodeBuild"] as? String,
            platformName: UIDevice.current.systemName,
            platformVersion: environment["SIMULATOR_RUNTIME_VERSION"] ?? UIDevice.current.systemVersion,
            deviceModel: environment["SIMULATOR_DEVICE_NAME"] ?? UIDevice.current.model,
            captureSource: isGitHubActions ? "github-actions" : "local-xctest"
        )
    }

    private func decodeFixture<T: Decodable>(
        _ name: String,
        extension fileExtension: String
    ) throws -> T {
        let bundle = Bundle(for: TranslationFirstPageBaselineTests.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: name, withExtension: fileExtension, subdirectory: "Fixtures")
                ?? bundle.url(forResource: name, withExtension: fileExtension)
        )
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }
}
