import Foundation

/// Guided Panel has a stricter latency budget than ordinary page reading: by the time the
/// reader reaches the last panel, the next page should already have both model output and a
/// decoded display image ready. This policy keeps those priorities explicit and testable.
nonisolated enum GuidedPanelPrefetchPolicy {
    static let bufferedPageTransitionDuration: TimeInterval = 0.34
    static let bufferedPageHandoffDelay: TimeInterval = 0.08
    static let bufferedPageRevealDuration: TimeInterval = 0.12

    /// Layout/image work stays tightly bounded: next page first, then one page farther ahead,
    /// then the previous page for backwards navigation.
    static func layoutIndices(currentPageIndex: Int, pageCount: Int) -> [Int] {
        prioritizedIndices(
            currentPageIndex: currentPageIndex,
            pageCount: pageCount,
            candidates: [currentPageIndex + 1, currentPageIndex + 2, currentPageIndex - 1]
        )
    }

    /// Core ML preanalysis does not need the 4096px display decode. Warm the two forward pages
    /// from small ImageIO thumbnails as soon as the current page becomes active so inference
    /// stays outside the visible panel-tap animation path.
    static func visionIndices(currentPageIndex: Int, pageCount: Int) -> [Int] {
        prioritizedIndices(
            currentPageIndex: currentPageIndex,
            pageCount: pageCount,
            candidates: [currentPageIndex + 1, currentPageIndex + 2]
        )
    }

    /// Panel taps must stay render-only. N+1/N+2 are already queued when the current page
    /// becomes active, so reaching the last panels must not suddenly start a 4096px decode or
    /// promote a Core ML request to userInitiated while the camera is animating. The existing
    /// ReaderView compatibility hook remains in place, but deliberately never fires.
    static func shouldPromoteNextPage(panelIndex: Int, panelCount: Int) -> Bool {
        _ = panelIndex
        _ = panelCount
        return false
    }

    private static func prioritizedIndices(
        currentPageIndex: Int,
        pageCount: Int,
        candidates: [Int]
    ) -> [Int] {
        guard pageCount > 0 else { return [] }
        var seen = Set<Int>()
        return candidates.filter { index in
            index >= 0
                && index < pageCount
                && index != currentPageIndex
                && seen.insert(index).inserted
        }
    }
}
