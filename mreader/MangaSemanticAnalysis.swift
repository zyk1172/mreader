import CoreGraphics
import Foundation

nonisolated enum MangaVisionTextROIPlanner {
    static let defaultPaddingFraction: CGFloat = 0.08

    static func recognitionRegions(
        from contentRegions: [MangaVisionRegion],
        paddingFraction: CGFloat = defaultPaddingFraction
    ) -> [CGRect] {
        let usable = contentRegions.filter { region in
            guard region.type == .text || region.type == .onomatopoeia else { return false }
            let threshold = MangaVisionCalibrationProfile.bundled
                .calibration(for: region.type)
                .confidenceThreshold
            guard region.confidence >= threshold else { return false }
            let rect = region.normalizedRect
            return rect.width >= 0.002
                && rect.height >= 0.002
                && MangaPageCoordinateSpace.area(rect) >= 0.000_02
        }
        let profile = MangaVisionCalibrationProfile.bundled
        let deduplicated = profile.deduplicated(
            usable.filter { $0.type == .text },
            type: .text
        ) + profile.deduplicated(
            usable.filter { $0.type == .onomatopoeia },
            type: .onomatopoeia
        )
        var padded: [CGRect] = []
        for region in MangaReadingGeometry.ordered(
            deduplicated,
            isRightToLeft: false,
            rect: { $0.normalizedRect },
            identity: { $0.id.uuidString }
        ) {
            let regionPadding = region.type == .onomatopoeia
                ? max(paddingFraction, 0.14)
                : paddingFraction
            let rect = MangaPageCoordinateSpace.paddedNormalizedRect(
                region.normalizedRect,
                fraction: regionPadding
            )
            guard rect.width > 0, rect.height > 0 else { continue }
            if let index = padded.firstIndex(where: {
                MangaPageCoordinateSpace.intersectionOverUnion($0, rect) >= 0.68
                    || MangaPageCoordinateSpace.containment(of: rect, in: $0) >= 0.90
                    || MangaPageCoordinateSpace.containment(of: $0, in: rect) >= 0.90
            }) {
                padded[index] = MangaPageCoordinateSpace.clampedNormalizedRect(
                    padded[index].union(rect)
                )
            } else {
                padded.append(rect)
            }
        }
        return padded
    }
}

nonisolated enum MangaSemanticAnalyzer {
    static func makeSemanticPage(
        from analysis: MangaPageAnalysis,
        isRightToLeft: Bool
    ) -> MangaSemanticPage {
        let profile = MangaVisionCalibrationProfile.bundled
        let panels = orderedPanels(
            profile.deduplicated(analysis.panels, type: .panel),
            isRightToLeft: isRightToLeft
        )
        let content = profile.deduplicated(
            analysis.texts,
            type: .text
        ) + profile.deduplicated(
            analysis.onomatopoeias,
            type: .onomatopoeia
        )

        var contentByPanel: [UUID: [MangaVisionRegion]] = [:]
        var unassignedRegions: [MangaVisionRegion] = []
        for region in content {
            if let panel = owningPanel(for: region.normalizedRect, panels: panels) {
                contentByPanel[panel.id, default: []].append(region)
            } else {
                unassignedRegions.append(region)
            }
        }

        let panelAnalyses = panels.map { panel -> MangaPanelAnalysis in
            let ordered = orderedTextRegions(
                contentByPanel[panel.id] ?? [],
                isRightToLeft: isRightToLeft
            )
            return MangaPanelAnalysis(
                panel: panel,
                texts: ordered.map { MangaSemanticText(region: $0) }
            )
        }
        let unassignedTexts = orderedTextRegions(
            unassignedRegions,
            isRightToLeft: isRightToLeft
        ).map { MangaSemanticText(region: $0) }

        return MangaSemanticPage(
            pageAnalysis: analysis,
            panels: panelAnalyses,
            unassignedTexts: unassignedTexts
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
        MangaReadingGeometry.ordered(
            regions,
            isRightToLeft: isRightToLeft,
            rect: { $0.normalizedRect },
            identity: { $0.id.uuidString }
        )
    }

    static func translationContext(
        semanticPage: MangaSemanticPage,
        blocks: [TextBlock]
    ) -> String {
        guard !semanticPage.panels.isEmpty else { return "" }
        var lines: [String] = [
            "漫画页面视觉上下文（MangaLayout4 V1；frame=分镜、text=文字、balloon=气泡、onomatopoeia=拟声词；仅用于几何、阅读顺序与翻译消歧）："
        ]
        for (panelIndex, panel) in semanticPage.panels.enumerated() {
            let panelRect = panel.panel.normalizedRect
            lines.append(String(
                format: "Panel %d rect=(%.3f,%.3f,%.3f,%.3f) semanticRegions=%d",
                panelIndex + 1,
                Double(panelRect.minX), Double(panelRect.minY),
                Double(panelRect.width), Double(panelRect.height),
                panel.texts.count
            ))
            for semanticText in panel.texts {
                guard let block = nearestOCRBlock(to: semanticText.region, blocks: blocks) else {
                    continue
                }
                let source = block.text
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !source.isEmpty else { continue }

                let order = (blocks.firstIndex(where: { $0.id == block.id }) ?? 0) + 1
                let textRect = block.boundingBox
                var metadata = "order=\(order) visionClass=\(semanticText.region.type.rawValue) role=\(block.layoutRole.rawValue) orientation=\(block.textOrientation.rawValue)"
                metadata += String(
                    format: " textRect=(%.3f,%.3f,%.3f,%.3f)",
                    Double(textRect.minX), Double(textRect.minY),
                    Double(textRect.width), Double(textRect.height)
                )
                if let bubble = block.bubbleBox {
                    metadata += String(
                        format: " bubbleRect=(%.3f,%.3f,%.3f,%.3f)",
                        Double(bubble.minX), Double(bubble.minY),
                        Double(bubble.width), Double(bubble.height)
                    )
                }
                lines.append("  [\(metadata)] source=\(source)")
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
