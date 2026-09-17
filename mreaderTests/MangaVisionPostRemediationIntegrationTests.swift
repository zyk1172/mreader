import CoreGraphics
import Foundation
import Testing
@testable import mreader

@Suite(.serialized)
@MainActor
struct MangaVisionPostRemediationIntegrationTests {
    @Test func adaptiveMergeUsesVersionedCalibrationProfile() {
        let identifier = MangaPageIdentifier(
            scope: "post-remediation-calibration",
            pageIndex: 0,
            sourceFingerprint: "fixture"
        )
        let baselineFace = MangaVisionRegion(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            type: .face,
            normalizedRect: CGRect(x: 0.10, y: 0.10, width: 0.30, height: 0.20),
            confidence: 0.92
        )
        let refinementFace = MangaVisionRegion(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            type: .face,
            normalizedRect: CGRect(x: 0.195, y: 0.10, width: 0.30, height: 0.20),
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
            faces: [baselineFace]
        )
        let refinement = analysis(
            identifier: identifier,
            balloons: [refinementBalloon],
            faces: [refinementFace]
        )

        let merged = MangaVisionAnalysisComposer.merge(
            baseline: baseline,
            refinements: [refinement]
        )
        let profile = MangaVisionCalibrationProfile.bundled
        let expectedFaces = profile.deduplicated(
            [baselineFace, refinementFace],
            type: .face
        )
        let expectedBalloons = profile.deduplicated(
            [baselineBalloon, refinementBalloon],
            type: .balloon
        )

        // These geometries intentionally sit between the old adaptive thresholds and
        // the revisioned profile so a copied/hard-coded threshold set fails this test.
        #expect(expectedFaces.count == 1)
        #expect(expectedBalloons.count == 2)
        #expect(merged.faces == expectedFaces)
        #expect(merged.balloons == expectedBalloons)
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

    private func analysis(
        identifier: MangaPageIdentifier,
        balloons: [MangaVisionRegion] = [],
        faces: [MangaVisionRegion] = []
    ) -> MangaPageAnalysis {
        MangaPageAnalysis(
            pageIdentifier: identifier,
            imageSize: CGSize(width: 1_000, height: 2_000),
            panels: [],
            texts: [],
            balloons: balloons,
            faces: faces,
            bodies: [],
            modelIdentifier: "post-remediation-fixture",
            modelVersion: 1
        )
    }
}
