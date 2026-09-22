import CoreGraphics
import Foundation

nonisolated struct MangaPanelStructureNode: Sendable, Equatable {
    let panel: DetectedPanel
    let balloonRegions: [CGRect]
    let textRegions: [CGRect]
    let narrativeAnchor: CGPoint?
    let semanticConfidence: CGFloat
}

/// Shared page-structure view built from the same Manga Vision result used by OCR
/// and translation. Guided Panel consumes it only as secondary ordering evidence:
/// clear panel geometry always wins over dialogue/text hints.
nonisolated struct MangaPageStructureGraph: Sendable {
    let nodes: [MangaPanelStructureNode]
    let unassignedBalloons: [CGRect]
    let unassignedTexts: [CGRect]

    static let empty = MangaPageStructureGraph(
        nodes: [],
        unassignedBalloons: [],
        unassignedTexts: []
    )

    private init(
        nodes: [MangaPanelStructureNode],
        unassignedBalloons: [CGRect],
        unassignedTexts: [CGRect]
    ) {
        self.nodes = nodes
        self.unassignedBalloons = unassignedBalloons
        self.unassignedTexts = unassignedTexts
    }

    init(
        panels: [DetectedPanel],
        analysis: MangaPageAnalysis?,
        isRightToLeft: Bool
    ) {
        guard !panels.isEmpty, let analysis else {
            self = .empty
            return
        }

        var balloonsByPanel = Array(repeating: [CGRect](), count: panels.count)
        var textsByPanel = Array(repeating: [CGRect](), count: panels.count)
        var unassignedBalloons: [CGRect] = []
        var unassignedTexts: [CGRect] = []

        for region in analysis.balloons {
            if let index = Self.bestPanelIndex(for: region.normalizedRect, panels: panels) {
                balloonsByPanel[index].append(region.normalizedRect)
            } else {
                unassignedBalloons.append(region.normalizedRect)
            }
        }
        for region in analysis.texts {
            if let index = Self.bestPanelIndex(for: region.normalizedRect, panels: panels) {
                textsByPanel[index].append(region.normalizedRect)
            } else {
                unassignedTexts.append(region.normalizedRect)
            }
        }

        self.nodes = panels.indices.map { index in
            let balloons = balloonsByPanel[index]
            let texts = textsByPanel[index]
            let anchorCandidates = balloons.isEmpty ? texts : balloons
            let ordered = Self.orderedNarrativeRegions(
                anchorCandidates,
                isRightToLeft: isRightToLeft
            )
            let anchor = ordered.first.map { CGPoint(x: $0.midX, y: $0.midY) }
            let evidenceCount = balloons.count * 2 + texts.count
            let confidence = min(CGFloat(evidenceCount) / 4, 1)
            return MangaPanelStructureNode(
                panel: panels[index],
                balloonRegions: balloons,
                textRegions: texts,
                narrativeAnchor: anchor,
                semanticConfidence: confidence
            )
        }
        self.unassignedBalloons = unassignedBalloons
        self.unassignedTexts = unassignedTexts
    }

    func node(for panel: DetectedPanel) -> MangaPanelStructureNode? {
        nodes.first { Self.nearlyEqual($0.panel.rect, panel.rect) }
    }

    /// Returns a preference only when both panels have meaningful semantic anchors.
    /// The caller decides whether geometry is ambiguous enough to consult it.
    func semanticPreference(
        _ lhs: DetectedPanel,
        _ rhs: DetectedPanel,
        isRightToLeft: Bool
    ) -> Bool? {
        guard let lhsNode = node(for: lhs),
              let rhsNode = node(for: rhs),
              let lhsAnchor = lhsNode.narrativeAnchor,
              let rhsAnchor = rhsNode.narrativeAnchor,
              max(lhsNode.semanticConfidence, rhsNode.semanticConfidence) >= 0.25 else {
            return nil
        }

        let verticalDelta = lhsAnchor.y - rhsAnchor.y
        if abs(verticalDelta) >= 0.055 {
            return lhsAnchor.y < rhsAnchor.y
        }
        let horizontalDelta = lhsAnchor.x - rhsAnchor.x
        if abs(horizontalDelta) >= 0.045 {
            return isRightToLeft ? lhsAnchor.x > rhsAnchor.x : lhsAnchor.x < rhsAnchor.x
        }
        return nil
    }

    private static func bestPanelIndex(
        for region: CGRect,
        panels: [DetectedPanel]
    ) -> Int? {
        let regionArea = max(MangaPageCoordinateSpace.area(region), 0.000_001)
        let center = CGPoint(x: region.midX, y: region.midY)
        var best: (index: Int, score: CGFloat)?

        for (index, panel) in panels.enumerated() {
            let intersection = panel.rect.intersection(region)
            let intersectionArea = intersection.isNull ? 0 : MangaPageCoordinateSpace.area(intersection)
            let containment = intersectionArea / regionArea
            let centerInside = contains(center, panel: panel)
            guard centerInside || containment >= 0.28 else { continue }

            // Prefer the smallest convincing containing panel. This is important
            // for inset panels: a text/balloon inside the inset must not be assigned
            // to the much larger parent frame simply because both contain it.
            let panelArea = max(MangaPageCoordinateSpace.area(panel.rect), 0.000_001)
            let score = containment * 2.4
                + (centerInside ? 1.2 : 0)
                + CGFloat(panel.confidence) * 0.15
                - panelArea * 0.08
            if best == nil || score > best!.score {
                best = (index, score)
            }
        }
        return best?.index
    }

    private static func contains(_ point: CGPoint, panel: DetectedPanel) -> Bool {
        guard panel.rect.contains(point) else { return false }
        guard let contour = panel.contour, contour.count >= 3 else { return true }
        return pointInPolygon(point, polygon: contour)
    }

    private static func orderedNarrativeRegions(
        _ regions: [CGRect],
        isRightToLeft: Bool
    ) -> [CGRect] {
        MangaReadingGeometry.ordered(
            regions,
            isRightToLeft: isRightToLeft,
            minimumRowTolerance: 0.035,
            rect: { $0 },
            identity: { "\($0.minX)|\($0.minY)|\($0.width)|\($0.height)" }
        )
    }

    private static func pointInPolygon(_ point: CGPoint, polygon: [CGPoint]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var previous = polygon.last!
        for current in polygon {
            let crosses = (current.y > point.y) != (previous.y > point.y)
            if crosses {
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

    private static func nearlyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 0.0005
            && abs(lhs.minY - rhs.minY) < 0.0005
            && abs(lhs.width - rhs.width) < 0.0005
            && abs(lhs.height - rhs.height) < 0.0005
    }
}

