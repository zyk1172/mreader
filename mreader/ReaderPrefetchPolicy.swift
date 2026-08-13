import Foundation

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
        let forwardStep = isContinuous
            ? (scrollDirection >= 0 ? 1 : -1)
            : (readingDirection == .rightToLeft ? -1 : 1)
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
