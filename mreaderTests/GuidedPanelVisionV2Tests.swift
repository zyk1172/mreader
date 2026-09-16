import CoreGraphics
import CoreML
import Foundation
import Testing
@testable import mreader

@Suite(.serialized)
@MainActor
struct GuidedPanelVisionV2Tests {
    @Test func tolerantXYCutKeepsReadingRowsWhenDetectorBoxesSlightlyIntrude() {
        let top = DetectedPanel(
            rect: CGRect(x: 0.06, y: 0.05, width: 0.88, height: 0.35),
            confidence: 0.91,
            source: .coreML
        )
        let bottom = DetectedPanel(
            rect: CGRect(x: 0.06, y: 0.385, width: 0.88, height: 0.35),
            confidence: 0.90,
            source: .coreML
        )

        let plan = PanelReadingOrder.plan([bottom, top], isRightToLeft: true)

        #expect(plan.panels.map(\.rect.minY) == [top.rect.minY, bottom.rect.minY])
        #expect(plan.strategy == .tolerantXYCut)
    }

    @Test func ambiguousPanelGeometryUsesBalloonNarrativeAnchorOnlyAsTieBreaker() {
        let left = DetectedPanel(
            rect: CGRect(x: 0.05, y: 0.08, width: 0.62, height: 0.78),
            confidence: 0.90,
            source: .coreML
        )
        let right = DetectedPanel(
            rect: CGRect(x: 0.33, y: 0.10, width: 0.62, height: 0.78),
            confidence: 0.91,
            source: .coreML
        )
        let analysis = MangaPageAnalysis(
            pageIdentifier: MangaPageIdentifier(scope: "test", pageIndex: 0, sourceFingerprint: "fixture"),
            imageSize: CGSize(width: 1200, height: 1800),
            panels: [],
            texts: [],
            balloons: [
                MangaVisionRegion(
                    type: .balloon,
                    normalizedRect: CGRect(x: 0.10, y: 0.18, width: 0.10, height: 0.08),
                    confidence: 0.95
                ),
                MangaVisionRegion(
                    type: .balloon,
                    normalizedRect: CGRect(x: 0.79, y: 0.16, width: 0.10, height: 0.08),
                    confidence: 0.96
                )
            ],
            faces: [],
            bodies: [],
            modelIdentifier: "fixture",
            modelVersion: 4
        )
        let structure = MangaPageStructureGraph(
            panels: [left, right],
            analysis: analysis,
            isRightToLeft: true
        )

        let plan = PanelReadingOrder.plan(
            [left, right],
            isRightToLeft: true,
            structure: structure
        )

        #expect(plan.panels.first?.rect == right.rect)
        #expect(plan.strategy == .semanticAssisted)
        #expect(plan.semanticTieBreakCount > 0)
    }

    @Test func coreMLNestedPanelIsNotDiscardedAsDialogueRectangle() {
        let parent = DetectedPanel(
            rect: CGRect(x: 0.04, y: 0.04, width: 0.90, height: 0.88),
            confidence: 0.88,
            source: .coreML
        )
        let inset = DetectedPanel(
            rect: CGRect(x: 0.62, y: 0.61, width: 0.22, height: 0.20),
            confidence: 0.93,
            source: .coreML
        )

        let processed = PanelPostProcessor.process([parent, inset])
        let tolerance: CGFloat = 0.000_001
        func approximatelyEquals(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
            abs(lhs.minX - rhs.minX) <= tolerance
                && abs(lhs.minY - rhs.minY) <= tolerance
                && abs(lhs.width - rhs.width) <= tolerance
                && abs(lhs.height - rhs.height) <= tolerance
        }

        #expect(processed.count == 2)
        #expect(processed.contains { approximatelyEquals($0.rect, parent.rect) })
        #expect(processed.contains { approximatelyEquals($0.rect, inset.rect) })
    }

    @Test func cameraTravelUsesSingleStageLatencyBoundedMotion() {
        let source = CGRect(x: 0.60, y: 0.05, width: 0.30, height: 0.24)
        let sameRow = CGRect(x: 0.18, y: 0.06, width: 0.30, height: 0.24)
        let far = CGRect(x: 0.06, y: 0.68, width: 0.28, height: 0.22)

        let rowProfile = GuidedPanelMotionPlanner.profile(from: source, to: sameRow)
        let farProfile = GuidedPanelMotionPlanner.profile(from: source, to: far)
        let boundary = GuidedPanelMotionPlanner.profile(
            from: source,
            to: nil,
            crossesPageBoundary: true
        )
        let leadIn = GuidedPanelMotionPlanner.bridgeRect(from: source, to: far)

        #expect(rowProfile.kind == .sameRow)
        #expect(rowProfile.duration >= 0.36)
        #expect(rowProfile.duration <= 0.46)
        #expect(!rowProfile.usesContextBridge)
        #expect(rowProfile.bridgeDuration == 0)
        #expect(rowProfile.settleDuration == rowProfile.duration)

        #expect(farProfile.kind == .farJump)
        #expect(!farProfile.usesContextBridge)
        #expect(farProfile.bridgeDuration == 0)
        #expect(farProfile.settleDuration == farProfile.duration)
        #expect(farProfile.duration > rowProfile.duration)
        #expect(farProfile.duration >= 0.62)
        #expect(farProfile.duration <= 0.76)

        #expect(boundary.kind == .pageBoundary)
        #expect(!boundary.usesContextBridge)
        #expect(boundary.bridgeDuration == 0)
        #expect(boundary.duration == boundary.settleDuration)
        #expect(boundary.duration == 0.58)

        // The geometry helper remains valid even though the active camera path no longer
        // consumes it. Keep this coverage so any compatibility callers receive a sane rect.
        #expect(leadIn.midX < source.midX)
        #expect(leadIn.midX > far.midX)
        #expect(leadIn.midY > source.midY)
        #expect(leadIn.midY < far.midY)
        #expect(abs(leadIn.midX - source.midX) < abs(far.midX - leadIn.midX))
        #expect(abs(leadIn.midY - source.midY) < abs(far.midY - leadIn.midY))
        #expect(abs(leadIn.midX - source.midX) >= abs(far.midX - source.midX) * 0.10)
        #expect(abs(leadIn.midY - source.midY) >= abs(far.midY - source.midY) * 0.10)
    }

    @Test func focusEntryStaysShortEnoughToFeelImmediate() {
        let entry = GuidedPanelMotionPlanner.profile(from: nil, to: nil)

        #expect(entry.kind == .focusEntry)
        #expect(entry.duration == 0.52)
        #expect(!entry.usesContextBridge)
        #expect(entry.bridgeDuration == 0)
        #expect(entry.settleDuration == entry.duration)
    }

    @Test func smallPanelGetsMoreZoomHeadroomThanLargePanel() {
        let small = GuidedPanelMotionPlanner.viewportTuning(
            for: CGRect(x: 0.70, y: 0.10, width: 0.14, height: 0.14)
        )
        let large = GuidedPanelMotionPlanner.viewportTuning(
            for: CGRect(x: 0.05, y: 0.08, width: 0.88, height: 0.58)
        )

        #expect(small.maximumScale > large.maximumScale)
        #expect(small.contextPadding >= large.contextPadding)
    }

    @Test func directSegmentationMaskProducesPageContour() throws {
        let detections = try MLMultiArray(shape: [1, 1, 6], dataType: .float32)
        detections[0] = 80
        detections[1] = 80
        detections[2] = 560
        detections[3] = 560
        detections[4] = 0.95
        detections[5] = 0

        let masks = try MLMultiArray(shape: [1, 1, 8, 8], dataType: .float32)
        for y in 2...5 {
            for x in 2...5 {
                masks[y * 8 + x] = 1
            }
        }

        let regions = YOLOMangaVisionProvider.decodeForDiagnostics(
            detections,
            segmentationOutput: masks,
            analysisImageSize: CGSize(width: 640, height: 640),
            labelsByClassID: [0: "frame"]
        )

        #expect(regions.count == 1)
        #expect(regions[0].type == .panel)
        #expect((regions[0].contour?.points.count ?? 0) >= 3)
        #expect((regions[0].contour?.bounds.width ?? 0) > 0.2)
    }

    @Test func guidedPanelDirectionSurvivesComicBookCodingIndependently() throws {
        let comic = ComicBook(
            title: "Direction persistence",
            bookmarkData: Data(),
            totalPages: 10,
            readingDirectionRaw: ReadingDirection.leftToRight.rawValue,
            guidedPanelReadingDirectionRaw: ReadingDirection.rightToLeft.rawValue
        )

        let data = try JSONEncoder().encode(comic)
        let decoded = try JSONDecoder().decode(ComicBook.self, from: data)

        #expect(decoded.readingDirectionRaw == ReadingDirection.leftToRight.rawValue)
        #expect(decoded.guidedPanelReadingDirectionRaw == ReadingDirection.rightToLeft.rawValue)
    }

    @Test func legacySyncedMetadataFallsBackPanelDirectionToNormalDirection() throws {
        let source = SyncedComicMetadata(
            identity: "local:test.cbz",
            metadataUpdatedAt: Date(timeIntervalSince1970: 100),
            readingDirectionRaw: ReadingDirection.rightToLeft.rawValue,
            guidedPanelReadingDirectionRaw: ReadingDirection.leftToRight.rawValue
        )
        let encoded = try JSONEncoder().encode(source)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "guidedPanelReadingDirectionRaw")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(SyncedComicMetadata.self, from: legacy)

        #expect(decoded.guidedPanelReadingDirectionRaw == ReadingDirection.rightToLeft.rawValue)
    }

    @Test func iCloudMetadataMergeKeepsNewerPerComicPanelDirection() throws {
        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)
        let localComic = SyncedComicMetadata(
            identity: "local:test.cbz",
            metadataUpdatedAt: newer,
            readingDirectionRaw: ReadingDirection.leftToRight.rawValue,
            guidedPanelReadingDirectionRaw: ReadingDirection.rightToLeft.rawValue
        )
        let remoteComic = SyncedComicMetadata(
            identity: "local:test.cbz",
            metadataUpdatedAt: older,
            readingDirectionRaw: ReadingDirection.rightToLeft.rawValue,
            guidedPanelReadingDirectionRaw: ReadingDirection.leftToRight.rawValue
        )
        let local = ICloudMetadataPayload(
            updatedAt: newer,
            deviceID: "local-device",
            comics: [localComic],
            activityDays: []
        )
        let remote = ICloudMetadataPayload(
            updatedAt: older,
            deviceID: "remote-device",
            comics: [remoteComic],
            activityDays: []
        )

        let merged = ICloudMetadataMergePolicy.merge(local: local, remote: remote)
        let comic = try #require(merged.comics.first)

        #expect(comic.guidedPanelReadingDirectionRaw == ReadingDirection.rightToLeft.rawValue)
        #expect(comic.readingDirectionRaw == ReadingDirection.leftToRight.rawValue)
    }
}
