import CoreGraphics
import Foundation

/// Row membership is decided once, against a fixed anchor, before sorting within
/// each row. Pairwise fuzzy comparisons can produce A < B < C < A.
nonisolated enum MangaReadingGeometry {
    static func ordered<Element>(
        _ values: [Element],
        isRightToLeft: Bool,
        minimumRowTolerance: CGFloat = 0.018,
        rect: (Element) -> CGRect,
        identity: (Element) -> String
    ) -> [Element] {
        let byY = values.sorted { lhs, rhs in
            let a = rect(lhs), b = rect(rhs)
            if a.midY != b.midY { return a.midY < b.midY }
            if a.midX != b.midX { return a.midX < b.midX }
            if a.width != b.width { return a.width < b.width }
            if a.height != b.height { return a.height < b.height }
            return identity(lhs) < identity(rhs)
        }
        var rows: [[Element]] = []
        for value in byY {
            if let index = rows.indices.last, let anchor = rows[index].first {
                let a = rect(anchor), b = rect(value)
                let tolerance = max(min(a.height, b.height) * 0.45, minimumRowTolerance)
                if abs(a.midY - b.midY) <= tolerance {
                    rows[index].append(value)
                    continue
                }
            }
            rows.append([value])
        }
        return rows.flatMap { row in
            row.sorted { lhs, rhs in
                let a = rect(lhs), b = rect(rhs)
                if a.midX != b.midX { return isRightToLeft ? a.midX > b.midX : a.midX < b.midX }
                if a.midY != b.midY { return a.midY < b.midY }
                if a.width != b.width { return a.width < b.width }
                if a.height != b.height { return a.height < b.height }
                return identity(lhs) < identity(rhs)
            }
        }
    }
}
