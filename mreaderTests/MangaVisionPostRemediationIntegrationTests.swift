import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import mreader

@Suite(.serialized)
@MainActor
struct MangaVisionPostRemediationIntegrationTests {
    @Test func adaptiveMergeUsesVersionedLayout4CalibrationProfile() {
        let identifier = MangaPageIdentifier(
            scope: "post-remediation-calibration",
            pageIndex: 0,
            sourceFingerprint: "fixture"
        )
        let baselineSFX = MangaVisionRegion(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            type: .onomatopoeia,
            normalizedRect: CGRect(x: 0.10, y: 0.10, width: 0.30, height: 0.20),
            confidence: 0.92
        )
        let refinementSFX = MangaVisionRegion(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            type: .onomatopoeia,
            normalizedRect: CGRect(x: 0.12, y: 0.11, width: 0.29, height: 0.19),
            confidence: 0.84
        )
        let baselineBalloon = MangaVisionRegion(
            id: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
            type: .balloon,
            normalizedRect: CGRect(x: 0.10, y: 0.45, width: 0.30, height: 0.20),
            confidence: 0.90
        )
        let refinementBalloon = MangaVisionRegion(
            id: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!,
            type: .balloon,
            normalizedRect: CGRect(x: 0.185, y: 0.45, width: 0.30, height: 0.20),
            confidence: 0.82
        )
        let baseline = analysis(
            identifier: identifier,
            balloons: [baselineBalloon],
            onomatopoeias: [baselineSFX]
        )
        let refinement = analysis(
            identifier: identifier,
            balloons: [refinementBalloon],
            onomatopoeias: [refinementSFX]
        )

        let merged = MangaVisionAnalysisComposer.merge(
            baseline: baseline,
            refinements: [refinement]
        )
        let profile = MangaVisionCalibrationProfile.bundled
        let expectedSFX = profile.deduplicated(
            [baselineSFX, refinementSFX],
            type: .onomatopoeia
        )
        let expectedBalloons = profile.deduplicated(
            [baselineBalloon, refinementBalloon],
            type: .balloon
        )

        #expect(merged.onomatopoeias == expectedSFX)
        #expect(merged.balloons == expectedBalloons)
        #expect(profile.calibration(for: .onomatopoeia).nmsIOUThreshold == 0.45)
        #expect(profile.calibration(for: .balloon).nmsIOUThreshold == 0.45)
    }

    @Test func plannerAndReleaseGateShareOneInferencePassBudget() {
        let plan = MangaVisionInferencePlanner.plan(
            sourceSize: CGSize(width: 1_000, height: 20_000),
            inputSize: CGSize(width: 640, height: 640),
            requestClass: .interactive,
            resourceState: MangaVisionResourceState(
                lowPowerModeEnabled: false,
                thermalLevel: .nominal
            )
        )
        let maximumPassCount = MangaVisionInferencePlanner.maximumInferencePassCount

        #expect(plan.refinementTiles.count + 1 == maximumPassCount)
        #expect(
            MangaVisionRegressionGate.release.maximumInferenceCountPerPage
                == Double(maximumPassCount)
        )

        let atBudget = MangaVisionRegressionMetrics.aggregate([
            MangaVisionRegressionObservation(inferenceCount: maximumPassCount)
        ])
        #expect(atBudget.maximumInferenceCountOnPage == maximumPassCount)
        #expect(MangaVisionRegressionGate.release.failures(for: atBudget).isEmpty)

        let aboveBudget = MangaVisionRegressionMetrics.aggregate([
            MangaVisionRegressionObservation(inferenceCount: maximumPassCount + 1)
        ])
        #expect(
            MangaVisionRegressionGate.release.failures(for: aboveBudget).contains {
                $0.hasPrefix("maximum-inference-count-on-page:")
            }
        )
    }

    @Test func lowAverageCannotHideSinglePageInferenceBudgetViolation() {
        let maximumPassCount = MangaVisionInferencePlanner.maximumInferencePassCount
        let observations = [
            MangaVisionRegressionObservation(inferenceCount: 1),
            MangaVisionRegressionObservation(inferenceCount: 1),
            MangaVisionRegressionObservation(inferenceCount: 1),
            MangaVisionRegressionObservation(inferenceCount: maximumPassCount + 1)
        ]
        let metrics = MangaVisionRegressionMetrics.aggregate(observations)

        #expect(metrics.inferenceCountPerPage < Double(maximumPassCount))
        #expect(metrics.maximumInferenceCountOnPage == maximumPassCount + 1)
        #expect(
            MangaVisionRegressionGate.release.failures(for: metrics).contains {
                $0.hasPrefix("maximum-inference-count-on-page:")
            }
        )
    }

    @Test func serviceSnapshotSeparatesPageAnalysesFromAdaptiveModelPasses() async throws {
        let base = MangaVisionPassCountingFakeProvider()
        let adaptive = AdaptiveMangaVisionProvider(
            base: base,
            resourceStateOverride: MangaVisionResourceState(
                lowPowerModeEnabled: false,
                thermalLevel: .nominal
            )
        )
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreader-post-remediation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let service = MangaVisionService(
            provider: adaptive,
            cacheDirectory: cacheDirectory
        )
        let cgImage = try #require(makeImage(width: 128, height: 2_560))
        let pageURL = cacheDirectory.appendingPathComponent("long-strip.png")

        _ = try await service.analysis(
            comicID: UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE"),
            pageIndex: 0,
            pageURL: pageURL,
            image: UIImage(cgImage: cgImage),
            contentIdentity: .remote(
                provider: "test",
                resource: "long-strip",
                revision: "long-strip-v1"
            )
        )

        let snapshot = await service.performanceSnapshot()
        let providerPassCount = await adaptive.totalInferencePassCountForDiagnostics()
        #expect(snapshot.inferenceCount == 1)
        #expect(providerPassCount == MangaVisionInferencePlanner.maximumInferencePassCount)
        #expect(snapshot.modelInferencePassCount == providerPassCount)
    }

    private func analysis(
        identifier: MangaPageIdentifier,
        balloons: [MangaVisionRegion] = [],
        onomatopoeias: [MangaVisionRegion] = []
    ) -> MangaPageAnalysis {
        MangaPageAnalysis(
            pageIdentifier: identifier,
            imageSize: CGSize(width: 1_000, height: 2_000),
            panels: [],
            texts: [],
            balloons: balloons,
            onomatopoeias: onomatopoeias,
            modelIdentifier: "post-remediation-fixture",
            modelVersion: 1
        )
    }

    private func makeImage(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

private actor MangaVisionPassCountingFakeProvider: MangaVisionProvider {
    var descriptor: MangaVisionProviderDescriptor {
        get async {
            MangaVisionProviderDescriptor(
                modelIdentifier: "post-remediation-pass-counting-fake",
                modelVersion: 1,
                inputSize: CGSize(width: 640, height: 640),
                supportedRegionTypes: [.panel, .text, .balloon, .onomatopoeia]
            )
        }
    }

    func analyzePage(
        image: CGImage,
        sourceImageSize: CGSize,
        pageIdentifier: MangaPageIdentifier
    ) async throws -> MangaPageAnalysis {
        MangaPageAnalysis(
            pageIdentifier: pageIdentifier,
            imageSize: sourceImageSize,
            panels: [],
            texts: [],
            balloons: [],
            onomatopoeias: [],
            modelIdentifier: "post-remediation-pass-counting-fake",
            modelVersion: 1
        )
    }
}
