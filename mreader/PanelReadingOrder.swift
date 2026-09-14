import CoreGraphics

/// Deterministic comic-panel reading order.
///
/// The primary path is a recursive XY-cut: horizontal gutters are resolved first,
/// then vertical gutters follow the book direction. Pages that cannot be cleanly
/// guillotine-split fall back to a precedence graph/topological order instead of
/// asking a vision model to guess semantics.
nonisolated enum PanelReadingOrder {
    static func ordered(
        _ panels: [DetectedPanel],
        isRightToLeft: Bool
    ) -> [DetectedPanel] {
        guard panels.count > 1 else { return panels }
        return recursivelyOrdered(panels, isRightToLeft: isRightToLeft, depth: 0)
    }

    private static func recursivelyOrdered(
        _ panels: [DetectedPanel],
        isRightToLeft: Bool,
        depth: Int
    ) -> [DetectedPanel] {
        guard panels.count > 1 else { return panels }
        guard depth < 16 else {
            return precedenceOrdered(panels, isRightToLeft: isRightToLeft)
        }

        if let split = bestHorizontalSplit(in: panels) {
            return recursivelyOrdered(split.first, isRightToLeft: isRightToLeft, depth: depth + 1)
                + recursivelyOrdered(split.second, isRightToLeft: isRightToLeft, depth: depth + 1)
        }

        if let split = bestVerticalSplit(in: panels) {
            let first = isRightToLeft ? split.second : split.first
            let second = isRightToLeft ? split.first : split.second
            return recursivelyOrdered(first, isRightToLeft: isRightToLeft, depth: depth + 1)
                + recursivelyOrdered(second, isRightToLeft: isRightToLeft, depth: depth + 1)
        }

        return precedenceOrdered(panels, isRightToLeft: isRightToLeft)
    }

    private static func bestHorizontalSplit(
        in panels: [DetectedPanel]
    ) -> (first: [DetectedPanel], second: [DetectedPanel])? {
        let sorted = panels.sorted { $0.rect.minY < $1.rect.minY }
        guard sorted.count > 1 else { return nil }
        let bounds = unionBounds(of: sorted.map(\.rect))
        let minimumGap = max(0.012, bounds.height * 0.025)
        var best: (index: Int, gap: CGFloat)?

        for index in 1..<sorted.count {
            let first = Array(sorted[..<index])
            let second = Array(sorted[index...])
            let firstMax = first.map(\.rect.maxY).max() ?? 0
            let secondMin = second.map(\.rect.minY).min() ?? 1
            let gap = secondMin - firstMax
            guard gap >= minimumGap else { continue }
            if best == nil || gap > best!.gap {
                best = (index, gap)
            }
        }

        guard let best else { return nil }
        return (
            Array(sorted[..<best.index]),
            Array(sorted[best.index...])
        )
    }

    private static func bestVerticalSplit(
        in panels: [DetectedPanel]
    ) -> (first: [DetectedPanel], second: [DetectedPanel])? {
        let sorted = panels.sorted { $0.rect.minX < $1.rect.minX }
        guard sorted.count > 1 else { return nil }
        let bounds = unionBounds(of: sorted.map(\.rect))
        let minimumGap = max(0.012, bounds.width * 0.025)
        var best: (index: Int, gap: CGFloat)?

        for index in 1..<sorted.count {
            let first = Array(sorted[..<index])
            let second = Array(sorted[index...])
            let firstMax = first.map(\.rect.maxX).max() ?? 0
            let secondMin = second.map(\.rect.minX).min() ?? 1
            let gap = secondMin - firstMax
            guard gap >= minimumGap else { continue }
            if best == nil || gap > best!.gap {
                best = (index, gap)
            }
        }

        guard let best else { return nil }
        return (
            Array(sorted[..<best.index]),
            Array(sorted[best.index...])
        )
    }

    private static func precedenceOrdered(
        _ panels: [DetectedPanel],
        isRightToLeft: Bool
    ) -> [DetectedPanel] {
        let count = panels.count
        var edges = Array(repeating: Set<Int>(), count: count)
        var indegree = Array(repeating: 0, count: count)
        let epsilon: CGFloat = 0.012

        for lhs in 0..<count {
            for rhs in 0..<count where lhs != rhs {
                let a = panels[lhs].rect
                let b = panels[rhs].rect
                let verticalOverlap = overlapRatio(
                    startA: a.minY,
                    endA: a.maxY,
                    startB: b.minY,
                    endB: b.maxY
                )

                let lhsPrecedes: Bool
                if a.maxY + epsilon < b.minY {
                    lhsPrecedes = true
                } else if verticalOverlap >= 0.30 {
                    if isRightToLeft {
                        lhsPrecedes = a.minX > b.maxX - epsilon
                    } else {
                        lhsPrecedes = a.maxX - epsilon < b.minX
                    }
                } else {
                    lhsPrecedes = false
                }

                if lhsPrecedes, !edges[lhs].contains(rhs) {
                    edges[lhs].insert(rhs)
                    indegree[rhs] += 1
                }
            }
        }

        var available = (0..<count).filter { indegree[$0] == 0 }
        var result: [DetectedPanel] = []
        var emitted = Set<Int>()

        while !available.isEmpty {
            available.sort { preferred(panels[$0], panels[$1], isRightToLeft: isRightToLeft) }
            let index = available.removeFirst()
            guard emitted.insert(index).inserted else { continue }
            result.append(panels[index])
            for target in edges[index] {
                indegree[target] -= 1
                if indegree[target] == 0 {
                    available.append(target)
                }
            }
        }

        if result.count == count {
            return result
        }

        let remainder = (0..<count)
            .filter { !emitted.contains($0) }
            .map { panels[$0] }
            .sorted { preferred($0, $1, isRightToLeft: isRightToLeft) }
        return result + remainder
    }

    private static func preferred(
        _ lhs: DetectedPanel,
        _ rhs: DetectedPanel,
        isRightToLeft: Bool
    ) -> Bool {
        let rowTolerance = max(min(lhs.rect.height, rhs.rect.height) * 0.35, 0.045)
        if abs(lhs.rect.midY - rhs.rect.midY) > rowTolerance {
            return lhs.rect.midY < rhs.rect.midY
        }
        if abs(lhs.rect.midX - rhs.rect.midX) > 0.01 {
            return isRightToLeft
                ? lhs.rect.midX > rhs.rect.midX
                : lhs.rect.midX < rhs.rect.midX
        }
        return lhs.rect.minY < rhs.rect.minY
    }

    private static func overlapRatio(
        startA: CGFloat,
        endA: CGFloat,
        startB: CGFloat,
        endB: CGFloat
    ) -> CGFloat {
        let overlap = max(0, min(endA, endB) - max(startA, startB))
        let smaller = max(min(endA - startA, endB - startB), 0.0001)
        return overlap / smaller
    }

    private static func unionBounds(of rects: [CGRect]) -> CGRect {
        guard var result = rects.first else { return .zero }
        for rect in rects.dropFirst() {
            result = result.union(rect)
        }
        return result
    }
}
