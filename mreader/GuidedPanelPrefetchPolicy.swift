import Foundation

/// Guided Panel has a stricter latency budget than ordinary page reading: by the time the
/// reader reaches the last panel, the next page should already have both model output and a
/// decoded display image ready. This policy keeps those priorities explicit and testable.
nonisolated enum GuidedPanelPrefetchPolicy {
    static let bufferedPageTransitionDuration: TimeInterval = 0.34
    static let bufferedPageHandoffDelay: TimeInterval = 0.08
    static let bufferedPageRevealDuration: TimeInterval = 0.12

    /// Keep four forward pages warm. Image prefetch already maintains a broad forward window;
    /// Guided Panel must keep layout/model output at comparable depth or a decoded N+1 page can
    /// still fall back to the visible detector spinner at the page boundary.
    static func layoutIndices(currentPageIndex: Int, pageCount: Int) -> [Int] {
        prioritizedIndices(
            currentPageIndex: currentPageIndex,
            pageCount: pageCount,
            candidates: [
                currentPageIndex + 1,
                currentPageIndex + 2,
                currentPageIndex + 3,
                currentPageIndex + 4,
                currentPageIndex - 1
            ]
        )
    }

    /// Core ML preanalysis uses small model-sized thumbnails, so warming four forward pages is
    /// substantially cheaper than four 4096px display decodes and gives short pages enough lead
    /// time to avoid synchronous-looking page-boundary work.
    static func visionIndices(currentPageIndex: Int, pageCount: Int) -> [Int] {
        prioritizedIndices(
            currentPageIndex: currentPageIndex,
            pageCount: pageCount,
            candidates: [
                currentPageIndex + 1,
                currentPageIndex + 2,
                currentPageIndex + 3,
                currentPageIndex + 4
            ]
        )
    }

    /// Normal pages stay render-only on taps. Only unusually short two/three-panel pages get the
    /// legacy N+1 promotion because they may be consumed before the proactive warm window has
    /// time to finish. This avoids reintroducing the PR #71 tap-jank regression on normal pages.
    static func shouldPromoteNextPage(panelIndex: Int, panelCount: Int) -> Bool {
        guard panelCount >= 2, panelCount <= 3 else { return false }
        let clamped = min(max(panelIndex, 0), panelCount - 1)
        return panelCount - clamped <= 2
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
