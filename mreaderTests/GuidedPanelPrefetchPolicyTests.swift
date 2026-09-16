import CoreGraphics
import Testing
@testable import mreader

@Suite
struct GuidedPanelPrefetchPolicyTests {
    @Test func guidedPanelPrefetchPrioritizesTwoForwardPages() {
        #expect(GuidedPanelPrefetchPolicy.layoutIndices(currentPageIndex: 4, pageCount: 12) == [5, 6, 3])
        #expect(GuidedPanelPrefetchPolicy.visionIndices(currentPageIndex: 4, pageCount: 12) == [5, 6])
    }

    @Test func guidedPanelPrefetchClampsAtBookEdges() {
        #expect(GuidedPanelPrefetchPolicy.layoutIndices(currentPageIndex: 0, pageCount: 2) == [1])
        #expect(GuidedPanelPrefetchPolicy.layoutIndices(currentPageIndex: 1, pageCount: 2) == [0])
        #expect(GuidedPanelPrefetchPolicy.visionIndices(currentPageIndex: 1, pageCount: 2).isEmpty)
    }

    @Test func panelTapsNeverStartLatencyCriticalPrefetch() {
        #expect(!GuidedPanelPrefetchPolicy.shouldPromoteNextPage(panelIndex: 2, panelCount: 8))
        #expect(!GuidedPanelPrefetchPolicy.shouldPromoteNextPage(panelIndex: 5, panelCount: 8))
        #expect(!GuidedPanelPrefetchPolicy.shouldPromoteNextPage(panelIndex: 7, panelCount: 8))
    }

    @Test func inPageCameraProfilesAreSingleStageAndBounded() {
        let sameRow = GuidedPanelMotionPlanner.profile(
            from: CGRect(x: 0.56, y: 0.05, width: 0.38, height: 0.30),
            to: CGRect(x: 0.06, y: 0.05, width: 0.38, height: 0.30)
        )
        #expect(sameRow.kind == .sameRow)
        #expect(!sameRow.usesContextBridge)
        #expect(sameRow.bridgeDuration == 0)
        #expect(sameRow.duration >= 0.36 && sameRow.duration <= 0.46)
        #expect(sameRow.settleDuration == sameRow.duration)

        let nextRow = GuidedPanelMotionPlanner.profile(
            from: CGRect(x: 0.06, y: 0.05, width: 0.38, height: 0.30),
            to: CGRect(x: 0.06, y: 0.48, width: 0.38, height: 0.30)
        )
        #expect(nextRow.kind == .nextRow)
        #expect(!nextRow.usesContextBridge)
        #expect(nextRow.bridgeDuration == 0)
        #expect(nextRow.duration >= 0.52 && nextRow.duration <= 0.62)
        #expect(nextRow.settleDuration == nextRow.duration)
    }

    @Test func farJumpDoesNotReintroduceBridgeTransaction() {
        let profile = GuidedPanelMotionPlanner.profile(
            from: CGRect(x: 0.68, y: 0.03, width: 0.18, height: 0.16),
            to: CGRect(x: 0.05, y: 0.72, width: 0.42, height: 0.22)
        )
        #expect(profile.kind == .farJump)
        #expect(!profile.usesContextBridge)
        #expect(profile.bridgeDuration == 0)
        #expect(profile.duration >= 0.62 && profile.duration <= 0.76)
    }

    @Test func rtlPagedPrefetchStillWarmsLogicalNextPages() {
        let indices = ReaderPrefetchPolicy.pageIndices(
            currentPageIndex: 5,
            pageCount: 12,
            readingDirection: .rightToLeft,
            readingMode: .guidedPanel,
            scrollDirection: 1,
            forwardCount: 3,
            backwardCount: 1,
            includesCurrentPage: false
        )

        #expect(indices == [6, 7, 8, 4])
    }

    @Test func continuousPrefetchStillFollowsActualScrollDirection() {
        let indices = ReaderPrefetchPolicy.pageIndices(
            currentPageIndex: 5,
            pageCount: 12,
            readingDirection: .rightToLeft,
            readingMode: .continuousScroll,
            scrollDirection: -1,
            forwardCount: 2,
            backwardCount: 1,
            includesCurrentPage: false
        )

        #expect(indices == [4, 3, 6])
    }
}
