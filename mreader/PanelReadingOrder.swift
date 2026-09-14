import CoreGraphics

nonisolated enum PanelReadingOrderStrategy: String, Codable, Sendable, Equatable {
    case strictXYCut
    case tolerantXYCut
    case semanticAssisted
    case precedenceGraph
    case fullPageFallback
}

nonisolated struct PanelReadingPlan: Sendable, Equatable {
    let panels: [DetectedPanel]
    let strategy: PanelReadingOrderStrategy
    let semanticTieBreakCount: Int
}

/// Deterministic comic-panel reading order.
///
/// The primary path is a Manga109-style recursive XY-cut. Unlike the original
/// box-only implementation, the tolerant path accepts small detector-box
/// intrusions and consults mask contours before declaring two panels overlapping.
/// Balloon/text semantics are only a tie-breaker for geometry that remains
/// ambiguous; they never override a clear spatial ordering.
nonisolated enum PanelReadingOrder {
    private struct ResolutionState {
        var usedTolerantCut = false
        var usedPrecedenceGraph = false
        var semanticTieBreakCount = 0
    }

    private struct SplitCandidate {
        let index: Int
        let gap: CGFloat
        let conflictRatio: CGFloat
        let isTolerant: Bool
    }

    static func ordered(
        _ panels: [DetectedPanel],
        isRightToLeft: Bool,
        structure: MangaPageStructureGraph? = nil
    ) -> [DetectedPanel] {
        plan(panels, isRightToLeft: isRightToLeft, structure: structure).panels
    }

    static func plan(
        _ panels: [DetectedPanel],
        isRightToLeft: Bool,
        structure: MangaPageStructureGraph? = nil
    ) -> PanelReadingPlan {
        guard panels.count > 1 else {
            return PanelReadingPlan(
                panels: panels,
                strategy: .strictXYCut,
                semanticTieBreakCount: 0
            )
        }
        var state = ResolutionState()
        let ordered = recursivelyOrdered(
            panels,
            isRightToLeft: isRightToLeft,
            structure: structure,
            depth: 0,
            state: &state
        )
        let strategy: PanelReadingOrderStrategy
        if state.semanticTieBreakCount > 0 {
            strategy = .semanticAssisted
        } else if state.usedTolerantCut {
            strategy = .tolerantXYCut
        } else if state.usedPrecedenceGraph {
            strategy = .precedenceGraph
        } else {
            strategy = .strictXYCut
        }
        return PanelReadingPlan(
            panels: ordered,
            strategy: strategy,
            semanticTieBreakCount: state.semanticTieBreakCount
        )
    }

    private static func recursivelyOrdered(
        _ panels: [DetectedPanel],
        isRightToLeft: Bool,
        structure: MangaPageStructureGraph?,
        depth: Int,
        state: inout ResolutionState
    ) -> [DetectedPanel] {
        guard panels.count > 1 else { return panels }
        guard depth < 16 else {
            state.usedPrecedenceGraph = true
            return precedenceOrdered(
                panels,
                isRightToLeft: isRightToLeft,
                structure: structure,
                state: &state
            )
        }

        if let split = bestHorizontalSplit(in: panels) {
            if split.isTolerant { state.usedTolerantCut = true }
            let sorted = panels.sorted { $0.rect.minY < $1.rect.minY }
            let first = Array(sorted[..<split.index])
            let second = Array(sorted[split.index...])
            return recursivelyOrdered(
                first,
                isRightToLeft: isRightToLeft,
                structure: structure,
                depth: depth + 1,
                state: &state
            ) + recursivelyOrdered(
                second,
                isRightToLeft: isRightToLeft,
                structure: structure,
                depth: depth + 1,
                state: &state
            )
        }

        if let split = bestVerticalSplit(in: panels) {
            if split.isTolerant { state.usedTolerantCut = true }
            let sorted = panels.sorted { $0.rect.minX < $1.rect.minX }
            let left = Array(sorted[..<split.index])
            let right = Array(sorted[split.index...])
            let first = isRightToLeft ? right : left
            let second = isRightToLeft ? left : right
            return recursivelyOrdered(
                first,
                isRightToLeft: isRightToLeft,
                structure: structure,
                depth: depth + 1,
                state: &state
            ) + recursivelyOrdered(
                second,
                isRightToLeft: isRightToLeft,
                structure: structure,
                depth: depth + 1,
                state: &state
            )
        }

        state.usedPrecedenceGraph = true
        return precedenceOrdered(
            panels,
            isRightToLeft: isRightToLeft,
            structure: structure,
            state: &state
        )
    }

    private static func bestHorizontalSplit(in panels: [DetectedPanel]) -> SplitCandidate? {
        let sorted = panels.sorted { $0.rect.minY < $1.rect.minY }
        guard sorted.count > 1 else { return nil }
        let bounds = unionBounds(of: sorted.map(\.rect))
        let minimumGap = max(0.008, bounds.height * 0.018)
        let intrusionTolerance = min(max(0.018, bounds.height * 0.045), 0.055)
        var strictCandidates: [SplitCandidate] = []
        var tolerantCandidates: [SplitCandidate] = []

        for index in 1..<sorted.count {
            let first = Array(sorted[..<index])
            let second = Array(sorted[index...])
            let firstMax = first.map(\.rect.maxY).max() ?? 0
            let secondMin = second.map(\.rect.minY).min() ?? 1
            let gap = secondMin - firstMax
            if gap >= minimumGap {
                strictCandidates.append(SplitCandidate(
                    index: index,
                    gap: gap,
                    conflictRatio: 0,
                    isTolerant: false
                ))
                continue
            }
            guard gap >= -intrusionTolerance else { continue }
            let firstCenter = first.map(\.rect.midY).reduce(0, +) / CGFloat(first.count)
            let secondCenter = second.map(\.rect.midY).reduce(0, +) / CGFloat(second.count)
            guard secondCenter - firstCenter >= max(bounds.height * 0.12, 0.05) else { continue }
            let conflict = crossGroupConflictRatio(first, second, horizontalSplit: true)
            guard conflict <= 0.28 else { continue }
            tolerantCandidates.append(SplitCandidate(
                index: index,
                gap: gap,
                conflictRatio: conflict,
                isTolerant: true
            ))
        }

        if let best = strictCandidates.max(by: { $0.gap < $1.gap }) { return best }
        return tolerantCandidates.max {
            tolerantScore($0, axisExtent: bounds.height) < tolerantScore($1, axisExtent: bounds.height)
        }
    }

    private static func bestVerticalSplit(in panels: [DetectedPanel]) -> SplitCandidate? {
        let sorted = panels.sorted { $0.rect.minX < $1.rect.minX }
        guard sorted.count > 1 else { return nil }
        let bounds = unionBounds(of: sorted.map(\.rect))
        let minimumGap = max(0.008, bounds.width * 0.018)
        let intrusionTolerance = min(max(0.018, bounds.width * 0.045), 0.055)
        var strictCandidates: [SplitCandidate] = []
        var tolerantCandidates: [SplitCandidate] = []

        for index in 1..<sorted.count {
            let first = Array(sorted[..<index])
            let second = Array(sorted[index...])
            let firstMax = first.map(\.rect.maxX).max() ?? 0
            let secondMin = second.map(\.rect.minX).min() ?? 1
            let gap = secondMin - firstMax
            if gap >= minimumGap {
                strictCandidates.append(SplitCandidate(
                    index: index,
                    gap: gap,
                    conflictRatio: 0,
                    isTolerant: false
                ))
                continue
            }
            guard gap >= -intrusionTolerance else { continue }
            let firstCenter = first.map(\.rect.midX).reduce(0, +) / CGFloat(first.count)
            let secondCenter = second.map(\.rect.midX).reduce(0, +) / CGFloat(second.count)
            guard secondCenter - firstCenter >= max(bounds.width * 0.12, 0.05) else { continue }
            let conflict = crossGroupConflictRatio(first, second, horizontalSplit: false)
            guard conflict <= 0.28 else { continue }
            tolerantCandidates.append(SplitCandidate(
                index: index,
                gap: gap,
                conflictRatio: conflict,
                isTolerant: true
            ))
        }

        if let best = strictCandidates.max(by: { $0.gap < $1.gap }) { return best }
        return tolerantCandidates.max {
            tolerantScore($0, axisExtent: bounds.width) < tolerantScore($1, axisExtent: bounds.width)
        }
    }

    private static func tolerantScore(_ candidate: SplitCandidate, axisExtent: CGFloat) -> CGFloat {
        candidate.gap - candidate.conflictRatio * max(axisExtent, 0.1) * 0.45
    }

    private static func crossGroupConflictRatio(
        _ first: [DetectedPanel],
        _ second: [DetectedPanel],
        horizontalSplit: Bool
    ) -> CGFloat {
        var conflicts = 0
        var comparisons = 0
        for lhs in first {
            for rhs in second {
                comparisons += 1
                let splitAxisOverlap = horizontalSplit
                    ? overlapRatio(
                        startA: lhs.rect.minY,
                        endA: lhs.rect.maxY,
                        startB: rhs.rect.minY,
                        endB: rhs.rect.maxY
                    )
                    : overlapRatio(
                        startA: lhs.rect.minX,
                        endA: lhs.rect.maxX,
                        startB: rhs.rect.minX,
                        endB: rhs.rect.maxX
                    )
                let crossAxisOverlap = horizontalSplit
                    ? overlapRatio(
                        startA: lhs.rect.minX,
                        endA: lhs.rect.maxX,
                        startB: rhs.rect.minX,
                        endB: rhs.rect.maxX
                    )
                    : overlapRatio(
                        startA: lhs.rect.minY,
                        endA: lhs.rect.maxY,
                        startB: rhs.rect.minY,
                        endB: rhs.rect.maxY
                    )
                guard splitAxisOverlap > 0.10, crossAxisOverlap > 0.20 else { continue }
                if panelShapesConflict(lhs, rhs) { conflicts += 1 }
            }
        }
        guard comparisons > 0 else { return 0 }
        return CGFloat(conflicts) / CGFloat(comparisons)
    }

    private static func panelShapesConflict(_ lhs: DetectedPanel, _ rhs: DetectedPanel) -> Bool {
        if let lhsContour = lhs.contour, lhsContour.count >= 3,
           let rhsContour = rhs.contour, rhsContour.count >= 3 {
            return polygonsOverlap(lhsContour, rhsContour)
        }
        let intersection = lhs.rect.intersection(rhs.rect)
        guard !intersection.isNull else { return false }
        let smaller = min(
            MangaPageCoordinateSpace.area(lhs.rect),
            MangaPageCoordinateSpace.area(rhs.rect)
        )
        return MangaPageCoordinateSpace.area(intersection) / max(smaller, 0.0001) > 0.14
    }

    private static func precedenceOrdered(
        _ panels: [DetectedPanel],
        isRightToLeft: Bool,
        structure: MangaPageStructureGraph?,
        state: inout ResolutionState
    ) -> [DetectedPanel] {
        let count = panels.count
        var edges = Array(repeating: Set<Int>(), count: count)
        var indegree = Array(repeating: 0, count: count)
        let epsilon: CGFloat = 0.014

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
            var usedSemanticThisRound = false
            available.sort { lhsIndex, rhsIndex in
                let lhs = panels[lhsIndex]
                let rhs = panels[rhsIndex]
                if geometryIsAmbiguous(lhs, rhs),
                   let semantic = structure?.semanticPreference(
                       lhs,
                       rhs,
                       isRightToLeft: isRightToLeft
                   ) {
                    usedSemanticThisRound = true
                    return semantic
                }
                return preferredGeometry(lhs, rhs, isRightToLeft: isRightToLeft)
            }
            if usedSemanticThisRound { state.semanticTieBreakCount += 1 }
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

        if result.count == count { return result }

        let remainder = (0..<count)
            .filter { !emitted.contains($0) }
            .map { panels[$0] }
            .sorted { preferredGeometry($0, $1, isRightToLeft: isRightToLeft) }
        return result + remainder
    }

    private static func geometryIsAmbiguous(_ lhs: DetectedPanel, _ rhs: DetectedPanel) -> Bool {
        let horizontalOverlap = overlapRatio(
            startA: lhs.rect.minX,
            endA: lhs.rect.maxX,
            startB: rhs.rect.minX,
            endB: rhs.rect.maxX
        )
        let verticalOverlap = overlapRatio(
            startA: lhs.rect.minY,
            endA: lhs.rect.maxY,
            startB: rhs.rect.minY,
            endB: rhs.rect.maxY
        )
        if horizontalOverlap >= 0.28, verticalOverlap >= 0.28 { return true }
        let lhsContainment = MangaPageCoordinateSpace.containment(of: lhs.rect, in: rhs.rect)
        let rhsContainment = MangaPageCoordinateSpace.containment(of: rhs.rect, in: lhs.rect)
        return lhsContainment >= 0.72 || rhsContainment >= 0.72
    }

    private static func preferredGeometry(
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

    private static func polygonsOverlap(_ lhs: [CGPoint], _ rhs: [CGPoint]) -> Bool {
        for lhsIndex in lhs.indices {
            let lhsNext = lhs[(lhsIndex + 1) % lhs.count]
            for rhsIndex in rhs.indices {
                let rhsNext = rhs[(rhsIndex + 1) % rhs.count]
                if segmentsIntersect(lhs[lhsIndex], lhsNext, rhs[rhsIndex], rhsNext) {
                    return true
                }
            }
        }
        return pointInPolygon(lhs[0], polygon: rhs)
            || pointInPolygon(rhs[0], polygon: lhs)
    }

    private static func segmentsIntersect(
    _ a: CGPoint,
    _ b: CGPoint,
    _ c: CGPoint,
    _ d: CGPoint
) -> Bool {
    let epsilon: CGFloat = 0.000_001

    func orientation(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> CGFloat {
        (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
    }

    func isOnSegment(_ point: CGPoint, from start: CGPoint, to end: CGPoint) -> Bool {
        point.x >= min(start.x, end.x) - epsilon
            && point.x <= max(start.x, end.x) + epsilon
            && point.y >= min(start.y, end.y) - epsilon
            && point.y <= max(start.y, end.y) + epsilon
    }

    let o1 = orientation(a, b, c)
    let o2 = orientation(a, b, d)
    let o3 = orientation(c, d, a)
    let o4 = orientation(c, d, b)
    let abStraddles = (o1 > epsilon && o2 < -epsilon)
        || (o1 < -epsilon && o2 > epsilon)
    let cdStraddles = (o3 > epsilon && o4 < -epsilon)
        || (o3 < -epsilon && o4 > epsilon)
    if abStraddles && cdStraddles { return true }

    if abs(o1) <= epsilon, isOnSegment(c, from: a, to: b) { return true }
    if abs(o2) <= epsilon, isOnSegment(d, from: a, to: b) { return true }
    if abs(o3) <= epsilon, isOnSegment(a, from: c, to: d) { return true }
    if abs(o4) <= epsilon, isOnSegment(b, from: c, to: d) { return true }
    return false
}

    private static func pointInPolygon(_ point: CGPoint, polygon: [CGPoint]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var previous = polygon.last!
        for current in polygon {
            if (current.y > point.y) != (previous.y > point.y) {
                let denominator = previous.y - current.y
                if abs(denominator) > 0.000_001 {
                    let xIntersection = (previous.x - current.x)
                        * (point.y - current.y) / denominator + current.x
                    if point.x < xIntersection { inside.toggle() }
                }
            }
            previous = current
        }
        return inside
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
