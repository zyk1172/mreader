import CoreGraphics
import Foundation

nonisolated enum MangaVisionTextROIPlanner {
    static let defaultPaddingFraction: CGFloat = 0.08

    static func recognitionRegions(
        from textRegions: [MangaVisionRegion],
        paddingFraction: CGFloat = defaultPaddingFraction
    ) -> [CGRect] {
        let usable = textRegions.filter { region in
            guard region.type == .text, region.confidence >= 0.12 else { return false }
            let rect = region.normalizedRect
            return rect.width >= 0.002
                && rect.height >= 0.002
                && MangaPageCoordinateSpace.area(rect) >= 0.000_02
        }
        let deduplicated = MangaVisionRegionPostProcessor.deduplicated(
            usable,
            iouThreshold: 0.58,
            containmentThreshold: 0.88
        )
        var padded: [CGRect] = []
        for region in deduplicated.sorted(by: { readingGeometryPrecedes($0.normalizedRect, $1.normalizedRect) }) {
            let rect = MangaPageCoordinateSpace.paddedNormalizedRect(
                region.normalizedRect,
                fraction: paddingFraction
            )
            guard rect.width > 0, rect.height > 0 else { continue }
            if let index = padded.firstIndex(where: {
                MangaPageCoordinateSpace.intersectionOverUnion($0, rect) >= 0.68
                    || MangaPageCoordinateSpace.containment(of: rect, in: $0) >= 0.90
                    || MangaPageCoordinateSpace.containment(of: $0, in: rect) >= 0.90
            }) {
                padded[index] = MangaPageCoordinateSpace.clampedNormalizedRect(padded[index].union(rect))
            } else {
                padded.append(rect)
            }
        }
        return padded
    }

    private static func readingGeometryPrecedes(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        if abs(lhs.midY - rhs.midY) > 0.02 { return lhs.midY < rhs.midY }
        return lhs.minX < rhs.minX
    }
}

nonisolated enum MangaSemanticAnalyzer {
    static func makeSemanticPage(
        from analysis: MangaPageAnalysis,
        isRightToLeft: Bool
    ) -> MangaSemanticPage {
        let panels = orderedPanels(
            MangaVisionRegionPostProcessor.deduplicated(
                analysis.panels,
                iouThreshold: 0.68,
                containmentThreshold: 0.96
            ),
            isRightToLeft: isRightToLeft
        )
        let texts = MangaVisionRegionPostProcessor.deduplicated(
            analysis.texts,
            iouThreshold: 0.58,
            containmentThreshold: 0.88
        )
        let people = personCandidates(
            faces: analysis.faces,
            bodies: analysis.bodies,
            panels: panels
        )

        var textsByPanel: [UUID: [MangaVisionRegion]] = [:]
        var unassignedTextRegions: [MangaVisionRegion] = []
        for text in texts {
            if let panel = owningPanel(for: text.normalizedRect, panels: panels) {
                textsByPanel[panel.id, default: []].append(text)
            } else {
                unassignedTextRegions.append(text)
            }
        }

        let personsByPanel = Dictionary(grouping: people.compactMap { person -> MangaPersonCandidate? in
            guard person.panelID != nil else { return nil }
            return person
        }, by: { $0.panelID! })
        let unassignedPersons = people.filter { $0.panelID == nil }

        let panelAnalyses = panels.map { panel -> MangaPanelAnalysis in
            let panelPersons = personsByPanel[panel.id] ?? []
            let orderedTexts = orderedTextRegions(
                textsByPanel[panel.id] ?? [],
                isRightToLeft: isRightToLeft
            )
            let semanticTexts = orderedTexts.map { text in
                MangaSemanticText(
                    region: text,
                    speakerCandidates: speakerCandidates(for: text, persons: panelPersons)
                )
            }
            return MangaPanelAnalysis(
                panel: panel,
                texts: semanticTexts,
                persons: panelPersons
            )
        }
        let unassignedTexts = orderedTextRegions(
            unassignedTextRegions,
            isRightToLeft: isRightToLeft
        ).map {
            MangaSemanticText(region: $0, speakerCandidates: [])
        }
        return MangaSemanticPage(
            pageAnalysis: analysis,
            panels: panelAnalyses,
            unassignedTexts: unassignedTexts,
            unassignedPersons: unassignedPersons
        )
    }

    static func owningPanel(
        for regionRect: CGRect,
        panels: [MangaVisionRegion]
    ) -> MangaVisionRegion? {
        let rect = MangaPageCoordinateSpace.clampedNormalizedRect(regionRect)
        guard rect.width > 0, rect.height > 0 else { return nil }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let centerContaining = panels.filter { panel in
            panel.normalizedRect.insetBy(dx: -0.002, dy: -0.002).contains(center)
        }
        if !centerContaining.isEmpty {
            return centerContaining.min {
                MangaPageCoordinateSpace.area($0.normalizedRect)
                    < MangaPageCoordinateSpace.area($1.normalizedRect)
            }
        }
        let overlapping = panels.compactMap { panel -> (MangaVisionRegion, CGFloat)? in
            let containment = MangaPageCoordinateSpace.containment(
                of: rect,
                in: panel.normalizedRect
            )
            guard containment >= 0.35 else { return nil }
            return (panel, containment)
        }
        return overlapping.max(by: { $0.1 < $1.1 })?.0
    }

    static func orderedTextRegions(
        _ regions: [MangaVisionRegion],
        isRightToLeft: Bool
    ) -> [MangaVisionRegion] {
        regions.sorted { lhs, rhs in
            let a = lhs.normalizedRect
            let b = rhs.normalizedRect
            let rowTolerance = max(min(a.height, b.height) * 0.45, 0.018)
            if abs(a.midY - b.midY) > rowTolerance {
                return a.midY < b.midY
            }
            if abs(a.midX - b.midX) > 0.006 {
                return isRightToLeft ? a.midX > b.midX : a.midX < b.midX
            }
            return a.minY < b.minY
        }
    }

    static func personCandidates(
        faces: [MangaVisionRegion],
        bodies: [MangaVisionRegion],
        panels: [MangaVisionRegion]
    ) -> [MangaPersonCandidate] {
        let cleanFaces = MangaVisionRegionPostProcessor.deduplicated(faces)
        let cleanBodies = MangaVisionRegionPostProcessor.deduplicated(bodies)
        struct PairScore {
            let faceIndex: Int
            let bodyIndex: Int
            let score: Float
        }
        var scores: [PairScore] = []
        for (faceIndex, face) in cleanFaces.enumerated() {
            for (bodyIndex, body) in cleanBodies.enumerated() {
                let score = faceBodyScore(face: face.normalizedRect, body: body.normalizedRect)
                if score >= 0.42 {
                    scores.append(PairScore(
                        faceIndex: faceIndex,
                        bodyIndex: bodyIndex,
                        score: score
                    ))
                }
            }
        }
        scores.sort { $0.score > $1.score }
        var usedFaces = Set<Int>()
        var usedBodies = Set<Int>()
        var result: [MangaPersonCandidate] = []
        for pair in scores {
            guard usedFaces.insert(pair.faceIndex).inserted else { continue }
            guard usedBodies.insert(pair.bodyIndex).inserted else {
                usedFaces.remove(pair.faceIndex)
                continue
            }
            let face = cleanFaces[pair.faceIndex]
            let body = cleanBodies[pair.bodyIndex]
            let personRect = face.normalizedRect.union(body.normalizedRect)
            result.append(MangaPersonCandidate(
                panelID: owningPanel(for: personRect, panels: panels)?.id,
                face: face,
                body: body,
                confidence: min(1, (face.confidence + body.confidence + pair.score) / 3)
            ))
        }
        for (index, face) in cleanFaces.enumerated() where !usedFaces.contains(index) {
            result.append(MangaPersonCandidate(
                panelID: owningPanel(for: face.normalizedRect, panels: panels)?.id,
                face: face,
                body: nil,
                confidence: face.confidence
            ))
        }
        for (index, body) in cleanBodies.enumerated() where !usedBodies.contains(index) {
            result.append(MangaPersonCandidate(
                panelID: owningPanel(for: body.normalizedRect, panels: panels)?.id,
                face: nil,
                body: body,
                confidence: body.confidence
            ))
        }
        return result
    }

    static func speakerCandidates(
        for text: MangaVisionRegion,
        persons: [MangaPersonCandidate]
    ) -> [MangaSpeakerCandidate] {
        let textCenter = CGPoint(
            x: text.normalizedRect.midX,
            y: text.normalizedRect.midY
        )
        return persons.compactMap { person -> MangaSpeakerCandidate? in
            let anchorRect = person.face?.normalizedRect ?? person.body?.normalizedRect
            guard let anchorRect else { return nil }
            let anchor = CGPoint(x: anchorRect.midX, y: anchorRect.midY)
            let distance = hypot(textCenter.x - anchor.x, textCenter.y - anchor.y)
            let proximity = max(0, 1 - Float(distance / 0.75))
            let faceBonus: Float = person.face == nil ? 0 : 0.12
            let score = min(1, proximity * 0.82 + person.confidence * 0.18 + faceBonus)
            guard score >= 0.18 else { return nil }
            return MangaSpeakerCandidate(person: person, score: score)
        }.sorted { $0.score > $1.score }
    }

    static func translationContext(
        semanticPage: MangaSemanticPage,
        blocks: [TextBlock]
    ) -> String {
        guard !semanticPage.panels.isEmpty else { return "" }
        var lines: [String] = ["漫画页面结构（仅作翻译消歧提示，不代表确定人物身份或说话人）："]
        for (panelIndex, panel) in semanticPage.panels.enumerated() {
            let panelRect = panel.panel.normalizedRect
            lines.append(String(
                format: "Panel %d rect=(%.3f,%.3f,%.3f,%.3f) persons=%d",
                panelIndex + 1,
                Double(panelRect.minX), Double(panelRect.minY),
                Double(panelRect.width), Double(panelRect.height),
                panel.persons.count
            ))
            for semanticText in panel.texts {
                guard let block = nearestOCRBlock(to: semanticText.region, blocks: blocks) else { continue }
                let source = block.text
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !source.isEmpty else { continue }
                let hints = semanticText.speakerCandidates.prefix(3)
                    .map { String(format: "personHint=%.2f", $0.score) }
                    .joined(separator: ",")
                lines.append("  text=\(source)\(hints.isEmpty ? "" : " [\(hints)]")")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func orderedPanels(
        _ panels: [MangaVisionRegion],
        isRightToLeft: Bool
    ) -> [MangaVisionRegion] {
        guard panels.count > 1 else { return panels }
        let detected = panels.map {
            DetectedPanel(
                rect: $0.normalizedRect,
                confidence: $0.confidence,
                source: .coreML
            )
        }
        let ordered = PanelReadingOrder.ordered(detected, isRightToLeft: isRightToLeft)
        var remaining = panels
        return ordered.compactMap { item in
            guard let index = remaining.firstIndex(where: {
                abs($0.normalizedRect.minX - item.rect.minX) < 0.000_01
                    && abs($0.normalizedRect.minY - item.rect.minY) < 0.000_01
                    && abs($0.normalizedRect.width - item.rect.width) < 0.000_01
                    && abs($0.normalizedRect.height - item.rect.height) < 0.000_01
            }) else { return nil }
            return remaining.remove(at: index)
        } + remaining
    }

    private static func faceBodyScore(face: CGRect, body: CGRect) -> Float {
        let f = MangaPageCoordinateSpace.clampedNormalizedRect(face)
        let b = MangaPageCoordinateSpace.clampedNormalizedRect(body)
        guard f.width > 0, f.height > 0, b.width > 0, b.height > 0 else { return 0 }
        let faceCenter = CGPoint(x: f.midX, y: f.midY)
        let upperBody = CGRect(
            x: b.minX - b.width * 0.12,
            y: b.minY - b.height * 0.12,
            width: b.width * 1.24,
            height: b.height * 0.78
        )
        let inUpperBody: Float = upperBody.contains(faceCenter) ? 0.50 : 0
        let containment = Float(MangaPageCoordinateSpace.containment(of: f, in: b))
        let horizontalDistance = abs(f.midX - b.midX) / max(b.width, 0.001)
        let horizontalScore = Float(max(0, 1 - horizontalDistance)) * 0.14
        let expectedHead = CGPoint(x: b.midX, y: b.minY + b.height * 0.18)
        let distance = hypot(faceCenter.x - expectedHead.x, faceCenter.y - expectedHead.y)
        let distanceScore = Float(max(0, 1 - distance / max(b.height, 0.04))) * 0.16
        return min(1, inUpperBody + containment * 0.20 + horizontalScore + distanceScore)
    }

    private static func nearestOCRBlock(
        to region: MangaVisionRegion,
        blocks: [TextBlock]
    ) -> TextBlock? {
        blocks.max { lhs, rhs in
            MangaPageCoordinateSpace.containment(
                of: lhs.boundingBox,
                in: region.normalizedRect
            ) < MangaPageCoordinateSpace.containment(
                of: rhs.boundingBox,
                in: region.normalizedRect
            )
        }.flatMap { block in
            let overlap = MangaPageCoordinateSpace.containment(
                of: block.boundingBox,
                in: region.normalizedRect
            )
            return overlap >= 0.20 ? block : nil
        }
    }
}
