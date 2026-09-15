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

    @Test func guidedPanelPromotesNextPageWhenTwoPanelsRemain() {
        #expect(!GuidedPanelPrefetchPolicy.shouldPromoteNextPage(panelIndex: 2, panelCount: 8))
        #expect(GuidedPanelPrefetchPolicy.shouldPromoteNextPage(panelIndex: 5, panelCount: 8))
        #expect(GuidedPanelPrefetchPolicy.shouldPromoteNextPage(panelIndex: 7, panelCount: 8))
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
