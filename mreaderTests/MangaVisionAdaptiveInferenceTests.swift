import Foundation
import Testing
import UIKit
@testable import mreader

@Suite(.serialized)
@MainActor
struct MangaVisionAdaptiveInferenceTests {
    @Test func standardPageUsesSingleFullPagePass() {
        let plan = MangaVisionInferencePlanner.plan(
            sourceSize: CGSize(width: 1_600, height: 2_400),
            inputSize: CGSize(width: 640, height: 640),
            requestClass: .interactive,
            resourceState: MangaVisionResourceState(
                lowPowerModeEnabled: false,
                thermalLevel: .nominal
            )
        )

        #expect(plan.allowsInference)
        #expect(plan.refinementTiles.isEmpty)
        #expect(plan.reason == "standard-page-full-pass-only")
    }

    @Test func longStripBuildsBoundedOverlappingCoverage() {
        let plan = MangaVisionInferencePlanner.plan(
            sourceSize: CGSize(width: 1_200, height: 7_200),
            inputSize: CGSize(width: 640, height: 640),
            requestClass: .interactive,
            resourceState: MangaVisionResourceState(
                lowPowerModeEnabled: false,
                thermalLevel: .nominal
            )
        )

        #expect(plan.allowsInference)
        #expect(plan.refinementTiles.count == 5)
        #expect(plan.refinementTiles.count <= 6)
        #expect(abs(plan.refinementTiles.first!.sourceRect.minY) < 0.000_001)
        #expect(abs(plan.refinementTiles.last!.sourceRect.maxY - 1) < 0.000_001)

        for index in 1..<plan.refinementTiles.count {
            let previous = plan.refinementTiles[index - 1]
            let current = plan.refinementTiles[index]
            #expect(previous.sourceRect.maxY > current.sourceRect.minY)
            #expect(abs(previous.ownershipRect.maxY - current.ownershipRect.minY) < 0.000_001)
        }
    }

    @Test func lowPowerPrefetchKeepsOnlyCheapBaseline() {
        let resourceState = MangaVisionResourceState(
            lowPowerModeEnabled: true,
            thermalLevel: .nominal
        )
        let plan = MangaVisionInferencePlanner.plan(
            sourceSize: CGSize(width: 1_000, height: 5_000),
            inputSize: CGSize(width: 640, height: 640),
            requestClass: .prefetch,
            resourceState: resourceState
        )

        #expect(plan.allowsInference)
        #expect(plan.refinementTiles.isEmpty)
        #expect(plan.reason == "low-power-background-full-pass-only")
        #expect(
            MangaVisionInferencePlanner.prefetchMaximumSourceDimension(
                inputSize: CGSize(width: 640, height: 640),
                resourceState: resourceState
            ) == 640
        )
        #expect(MangaVisionInferencePlanner.prefetchPageLimit(resourceState: resourceState) == 1)
    }

    @Test func seriousThermalStateDefersBackgroundButNotInteractiveBaseline() {
        let resourceState = MangaVisionResourceState(
            lowPowerModeEnabled: false,
            thermalLevel: .serious
        )
        let background = MangaVisionInferencePlanner.plan(
            sourceSize: CGSize(width: 1_000, height: 5_000),
            inputSize: CGSize(width: 640, height: 640),
            requestClass: .prefetch,
            resourceState: resourceState
        )
        let interactive = MangaVisionInferencePlanner.plan(
            sourceSize: CGSize(width: 1_000, height: 5_000),
            inputSize: CGSize(width: 640, height: 640),
            requestClass: .interactive,
            resourceState: resourceState
        )

        #expect(!background.allowsInference)
        #expect(background.reason == "background-deferred-thermal")
        #expect(interactive.allowsInference)
        #expect(interactive.refinementTiles.isEmpty)
        #expect(interactive.reason == "thermal-full-pass-only")
        #expect(
            MangaVisionInferencePlanner.prefetchMaximumSourceDimension(
                inputSize: CGSize(width: 640, height: 640),
                resourceState: resourceState
            ) == nil
        )
        #expect(MangaVisionInferencePlanner.prefetchPageLimit(resourceState: resourceState) == 0)
    }

    @Test func schedulerLetsInteractiveWorkPassQueuedPrefetch() async {
        let scheduler = MangaVisionInferenceScheduler()
        let recorder = MangaVisionSchedulerOrderRecorder()

        await scheduler.acquire(for: .prefetch)
        let background = Task {
            await scheduler.acquire(for: .prefetch)
            await recorder.append("prefetch")
            await scheduler.release()
        }
        await waitForScheduler(
            scheduler,
            interactiveWaiters: 0,
            prefetchWaiters: 1
        )

        let interactive = Task {
            await scheduler.acquire(for: .interactive)
            await recorder.append("interactive")
            await scheduler.release()
        }
        await waitForScheduler(
            scheduler,
            interactiveWaiters: 1,
            prefetchWaiters: 1
        )

        await scheduler.release()
        _ = await interactive.value
        _ = await background.value

        #expect(await recorder.values() == ["interactive", "prefetch"])
    }

    @Test func adaptiveProviderRunsBaselineThenBoundedTileRefinement() async throws {
        let manifest = MangaVisionModelManifest(
            modelID: "adaptive-fake",
            modelBuildID: "build-1",
            modelFileHash: "hash-1",
            inputSize: CGSize(width: 64, height: 64),
            semanticClasses: [.panel, .text, .balloon],
            outputContractRevision: "contract-v1",
            analysisSchemaRevision: "analysis-v1",
            postProcessRevision: "post-v1",
            calibrationRevision: "calibration-v1"
        )
        let base = MangaVisionAdaptiveFakeProvider(manifest: manifest)
        let provider = AdaptiveMangaVisionProvider(
            base: base,
            resourceStateOverride: MangaVisionResourceState(
                lowPowerModeEnabled: false,
                thermalLevel: .nominal
            )
        )
        let image = makeImage(size: CGSize(width: 128, height: 512)).cgImage!
        let identifier = MangaPageIdentifier(
            scope: "adaptive-test",
            pageIndex: 0,
            sourceFingerprint: "source"
        )

        let result = try await provider.analyzeSourceImage(
            image: image,
            sourceImageSize: CGSize(width: image.width, height: image.height),
            pageIdentifier: identifier,
            requestClass: .interactive
        )

        #expect(await base.inferenceCalls() == 5)
        #expect(result.panels.count >= 2)
        let adaptiveManifest = await provider.mangaVisionManifest()
        #expect(adaptiveManifest.postProcessRevision.contains(MangaVisionInferencePlanner.revision))
    }

    @Test func tileRemappingUsesPageCoordinatesAndOwnership() {
        let identifier = MangaPageIdentifier(
            scope: "remap",
            pageIndex: 2,
            sourceFingerprint: "source"
        )
        let region = MangaVisionRegion(
            type: .panel,
            normalizedRect: CGRect(x: 0.10, y: 0.20, width: 0.40, height: 0.30),
            confidence: 0.8,
            contour: MangaVisionContour(points: [
                CGPoint(x: 0.10, y: 0.20),
                CGPoint(x: 0.50, y: 0.20),
                CGPoint(x: 0.50, y: 0.50)
            ])
        )
        let local = MangaPageAnalysis(
            pageIdentifier: identifier,
            imageSize: CGSize(width: 1_000, height: 4_000),
            panels: [region],
            texts: [],
            faces: [],
            bodies: [],
            modelIdentifier: "fake",
            modelVersion: 1
        )

        let mapped = MangaVisionAnalysisComposer.remap(
            local,
            from: CGRect(x: 0, y: 0.50, width: 1, height: 0.25),
            acceptingCentersIn: CGRect(x: 0, y: 0.50, width: 1, height: 0.25)
        )

        #expect(mapped.panels.count == 1)
        #expect(abs(mapped.panels[0].normalizedRect.minX - 0.10) < 0.000_001)
        #expect(abs(mapped.panels[0].normalizedRect.minY - 0.55) < 0.000_001)
        #expect(abs(mapped.panels[0].normalizedRect.height - 0.075) < 0.000_001)
        #expect(abs(mapped.panels[0].contour!.cgPoints[0].y - 0.55) < 0.000_001)
    }

    private func waitForScheduler(
        _ scheduler: MangaVisionInferenceScheduler,
        interactiveWaiters: Int,
        prefetchWaiters: Int
    ) async {
        for _ in 0..<200 {
            let snapshot = await scheduler.snapshotForDiagnostics()
            if snapshot.interactiveWaiterCount == interactiveWaiters,
               snapshot.prefetchWaiterCount == prefetchWaiters {
                return
            }
            await Task.yield()
        }
        let snapshot = await scheduler.snapshotForDiagnostics()
        Issue.record(
            "scheduler queue did not settle: interactive=\(snapshot.interactiveWaiterCount) prefetch=\(snapshot.prefetchWaiterCount)"
        )
    }

    private func makeImage(size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.black.setFill()
            context.fill(CGRect(x: 8, y: 8, width: max(size.width - 16, 1), height: 24))
        }
    }
}

private actor MangaVisionSchedulerOrderRecorder {
    private var order: [String] = []

    func append(_ value: String) {
        order.append(value)
    }

    func values() -> [String] {
        order
    }
}

private actor MangaVisionAdaptiveFakeProvider: MangaVisionProvider, MangaVisionManifestProviding {
    private let manifest: MangaVisionModelManifest
    private var callCount = 0

    init(manifest: MangaVisionModelManifest) {
        self.manifest = manifest
    }

    var descriptor: MangaVisionProviderDescriptor {
        get async { manifest.compatibilityDescriptor }
    }

    func mangaVisionManifest() async -> MangaVisionModelManifest {
        manifest
    }

    func analyzePage(
        image: CGImage,
        sourceImageSize: CGSize,
        pageIdentifier: MangaPageIdentifier
    ) async throws -> MangaPageAnalysis {
        _ = image
        callCount += 1
        return MangaPageAnalysis(
            pageIdentifier: pageIdentifier,
            imageSize: sourceImageSize,
            panels: [
                MangaVisionRegion(
                    type: .panel,
                    normalizedRect: CGRect(x: 0.10, y: 0.10, width: 0.32, height: 0.30),
                    confidence: 0.82
                )
            ],
            texts: [],
            balloons: [],
            faces: [],
            bodies: [],
            modelIdentifier: manifest.modelID,
            modelVersion: manifest.compatibilityDescriptor.modelVersion
        )
    }

    func inferenceCalls() -> Int {
        callCount
    }
}