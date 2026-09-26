import CoreGraphics
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

    @Test func layout4NavigationRejectsBalloonAliasButKeepsContainingFrame() {
        let realFrame = DetectedPanel(
            rect: CGRect(x: 0.08, y: 0.08, width: 0.78, height: 0.72),
            confidence: 0.24,
            source: .coreML
        )
        let balloonAlias = DetectedPanel(
            rect: CGRect(x: 0.56, y: 0.18, width: 0.20, height: 0.16),
            confidence: 0.16,
            source: .coreML
        )
        let balloon = MangaVisionRegion(
            type: .balloon,
            normalizedRect: CGRect(x: 0.555, y: 0.175, width: 0.205, height: 0.17),
            confidence: 0.19
        )

        let processed = PanelPostProcessor.process(
            [realFrame, balloonAlias],
            semanticRegions: [balloon]
        )

        #expect(processed.map(\.rect).contains(realFrame.rect))
        #expect(!processed.map(\.rect).contains(balloonAlias.rect))
    }

    @Test func layout4NavigationDoesNotRejectRealFrameMerelyBecauseItContainsBalloon() {
        let realFrame = DetectedPanel(
            rect: CGRect(x: 0.08, y: 0.08, width: 0.78, height: 0.72),
            confidence: 0.22,
            source: .coreML
        )
        let balloon = MangaVisionRegion(
            type: .balloon,
            normalizedRect: CGRect(x: 0.56, y: 0.18, width: 0.20, height: 0.16),
            confidence: 0.30
        )

        let processed = PanelPostProcessor.process(
            [realFrame],
            semanticRegions: [balloon]
        )

        #expect(processed.map(\.rect) == [realFrame.rect])
    }

    @Test func layout4NavigationDropsWholePageContainerAroundRealFrames() {
        let container = DetectedPanel(
            rect: CGRect(x: 0.02, y: 0.02, width: 0.96, height: 0.96),
            confidence: 0.11,
            source: .coreML
        )
        let frames = [
            DetectedPanel(rect: CGRect(x: 0.04, y: 0.05, width: 0.43, height: 0.40), confidence: 0.20, source: .coreML),
            DetectedPanel(rect: CGRect(x: 0.53, y: 0.05, width: 0.43, height: 0.40), confidence: 0.19, source: .coreML),
            DetectedPanel(rect: CGRect(x: 0.04, y: 0.53, width: 0.43, height: 0.40), confidence: 0.18, source: .coreML),
            DetectedPanel(rect: CGRect(x: 0.53, y: 0.53, width: 0.43, height: 0.40), confidence: 0.17, source: .coreML)
        ]

        let processed = PanelPostProcessor.process([container] + frames)

        #expect(processed.count == 4)
        #expect(!processed.contains { $0.rect == container.rect })
        for frame in frames {
            #expect(processed.contains { $0.rect == frame.rect })
        }
    }

    @Test func layout4NavigationDoesNotTurnQFLLowScoreTailIntoExtraStops() {
        let strong = DetectedPanel(
            rect: CGRect(x: 0.05, y: 0.05, width: 0.42, height: 0.40),
            confidence: 0.50,
            source: .coreML
        )
        let valid = DetectedPanel(
            rect: CGRect(x: 0.53, y: 0.05, width: 0.42, height: 0.40),
            confidence: 0.20,
            source: .coreML
        )
        let lowScoreTail = DetectedPanel(
            rect: CGRect(x: 0.10, y: 0.58, width: 0.35, height: 0.30),
            confidence: 0.06,
            source: .coreML
        )

        let processed = PanelPostProcessor.process([strong, valid, lowScoreTail])

        #expect(processed.map(\.rect).contains(strong.rect))
        #expect(processed.map(\.rect).contains(valid.rect))
        #expect(!processed.map(\.rect).contains(lowScoreTail.rect))
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

    @Test func semanticViewportUsesBalloonAndTextOnlyInsideLargeSelectedPanel() throws {
        let panel = CGRect(x: 0.05, y: 0.06, width: 0.90, height: 0.82)
        let balloon = semanticRegion(
            .balloon,
            x: 0.58,
            y: 0.16,
            width: 0.22,
            height: 0.18,
            confidence: 0.92
        )
        let text = semanticRegion(
            .text,
            x: 0.64,
            y: 0.20,
            width: 0.08,
            height: 0.10,
            confidence: 0.94
        )
        let analysis = semanticAnalysis(
            texts: [text],
            balloons: [balloon]
        )

        let focus = try #require(
            GuidedPanelSemanticViewportPlanner.focusRects(
                panels: [panel],
                analysis: analysis
            ).first ?? nil
        )

        #expect(panel.contains(focus))
        #expect(focus.contains(balloon.normalizedRect))
        #expect(focus.contains(text.normalizedRect))
        #expect(focus.width < panel.width)
        #expect(focus.height < panel.height)
    }

    @Test func noLayout4SemanticEvidenceLeavesGuidedFocusUntightened() {
        let panel = CGRect(x: 0.05, y: 0.06, width: 0.90, height: 0.82)
        let analysis = semanticAnalysis()

        let focus = GuidedPanelSemanticViewportPlanner.focusRects(
            panels: [panel],
            analysis: analysis
        )

        #expect(focus.count == 1)
        #expect(focus[0] == nil)
    }

    @Test func onomatopoeiaCanTightenLargeSelectedFrame() throws {
        let panel = CGRect(x: 0.05, y: 0.06, width: 0.90, height: 0.82)
        let sfx = semanticRegion(
            .onomatopoeia,
            x: 0.62,
            y: 0.23,
            width: 0.14,
            height: 0.16,
            confidence: 0.88
        )
        let analysis = semanticAnalysis(onomatopoeias: [sfx])

        let focus = try #require(
            GuidedPanelSemanticViewportPlanner.focusRects(
                panels: [panel],
                analysis: analysis
            ).first ?? nil
        )

        #expect(panel.contains(focus))
        #expect(focus.contains(sfx.normalizedRect))
        #expect(focus.width < panel.width)
        #expect(focus.height < panel.height)
    }

    @Test func semanticEvidenceOutsideSelectedFrameCannotRecenterFocus() throws {
        let selected = CGRect(x: 0.05, y: 0.06, width: 0.42, height: 0.82)
        let other = CGRect(x: 0.53, y: 0.06, width: 0.42, height: 0.82)
        let text = semanticRegion(
            .text,
            x: 0.14,
            y: 0.20,
            width: 0.10,
            height: 0.12,
            confidence: 0.92
        )
        let distantSFX = semanticRegion(
            .onomatopoeia,
            x: 0.70,
            y: 0.22,
            width: 0.14,
            height: 0.15,
            confidence: 0.95
        )
        let analysis = semanticAnalysis(
            texts: [text],
            onomatopoeias: [distantSFX]
        )

        let focuses = GuidedPanelSemanticViewportPlanner.focusRects(
            panels: [selected, other],
            analysis: analysis
        )
        let selectedFocus = try #require(focuses[0])
        let otherFocus = try #require(focuses[1])

        #expect(selected.contains(selectedFocus))
        #expect(!selectedFocus.intersects(distantSFX.normalizedRect))
        #expect(other.contains(otherFocus))
        #expect(otherFocus.contains(distantSFX.normalizedRect))
    }

    @Test func semanticViewportDoesNotTightenAlreadySmallPanels() {
        let panel = CGRect(x: 0.58, y: 0.08, width: 0.30, height: 0.30)
        let analysis = semanticAnalysis(
            balloons: [
                semanticRegion(.balloon, x: 0.66, y: 0.13, width: 0.12, height: 0.10)
            ]
        )

        let focus = GuidedPanelSemanticViewportPlanner.focusRects(
            panels: [panel],
            analysis: analysis
        )

        #expect(focus == [nil])
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

    private func semanticAnalysis(
        texts: [MangaVisionRegion] = [],
        balloons: [MangaVisionRegion] = [],
        onomatopoeias: [MangaVisionRegion] = []
    ) -> MangaPageAnalysis {
        MangaPageAnalysis(
            pageIdentifier: MangaPageIdentifier(
                scope: "guided-semantic-viewport",
                pageIndex: 0,
                sourceFingerprint: "fixture"
            ),
            imageSize: CGSize(width: 1200, height: 1800),
            panels: [],
            texts: texts,
            balloons: balloons,
            onomatopoeias: onomatopoeias,
            modelIdentifier: MangaLayout4V1Provider.modelIdentifier,
            modelVersion: 1
        )
    }

    private func semanticRegion(
        _ type: MangaRegionType,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
        confidence: Float = 0.90
    ) -> MangaVisionRegion {
        MangaVisionRegion(
            type: type,
            normalizedRect: CGRect(x: x, y: y, width: width, height: height),
            confidence: confidence
        )
    }
}
