import Foundation

nonisolated struct ReaderPageCacheWindow: Equatable {
    let forwardCount: Int
    let backwardCount: Int
}

nonisolated enum ReaderPageCacheWindowPolicy {
    static func window(for readingMode: ReadingMode) -> ReaderPageCacheWindow {
        switch readingMode {
        case .continuousScroll, .infiniteScroll:
            return ReaderPageCacheWindow(forwardCount: 4, backwardCount: 2)
        default:
            return ReaderPageCacheWindow(forwardCount: 8, backwardCount: 2)
        }
    }
}

nonisolated enum ReaderPrefetchPolicy {
    static func pageIndices(
        currentPageIndex: Int,
        pageCount: Int,
        readingDirection: ReadingDirection,
        readingMode: ReadingMode,
        scrollDirection: Int,
        forwardCount: Int,
        backwardCount: Int,
        includesCurrentPage: Bool
    ) -> [Int] {
        guard pageCount > 0 else { return [] }
        let current = min(max(currentPageIndex, 0), pageCount - 1)
        // `.infiniteScroll` has no independent implementation yet; it currently reuses
        // the continuous-scroll semantics, so it is intentionally treated identically here.
        let isContinuous = readingMode == .continuousScroll || readingMode == .infiniteScroll
        // Paged readers always advance their logical page index with `+1`; RTL only changes
        // gesture/visual direction. Using `-1` here for RTL meant Japanese manga preloaded the
        // pages behind the reader while the UI advanced to `currentPageIndex + 1`.
        let forwardStep = isContinuous
            ? (scrollDirection >= 0 ? 1 : -1)
            : 1
        var indices: [Int] = includesCurrentPage ? [current] : []
        if forwardCount > 0 {
            indices.append(contentsOf: (1...forwardCount).map { current + $0 * forwardStep })
        }
        if backwardCount > 0 {
            indices.append(contentsOf: (1...backwardCount).map { current - $0 * forwardStep })
        }
        var seen = Set<Int>()
        return indices.filter { $0 >= 0 && $0 < pageCount && seen.insert($0).inserted }
    }
}
