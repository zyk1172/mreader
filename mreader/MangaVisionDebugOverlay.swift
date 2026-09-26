import SwiftUI

#if DEBUG
struct MangaVisionDebugOverlayConfiguration: Sendable, Equatable {
    var showsPanels = true
    var showsTexts = true
    var showsBalloons = true
    var showsOnomatopoeias = true
    var showsRelations = true
}

/// Developer-only overlay for inspecting the shared Manga Vision analysis.
/// `imageRect` is the actual displayed comic-page rectangle inside the reader
/// viewport, so normalized page coordinates stay correct under aspect-fit,
/// letterboxing, zoom and the existing reader coordinate system.
struct MangaVisionDebugOverlay: View {
    let analysis: MangaPageAnalysis
    let semanticPage: MangaSemanticPage?
    let imageRect: CGRect
    let configuration: MangaVisionDebugOverlayConfiguration

    var body: some View {
        ZStack(alignment: .topLeading) {
            if configuration.showsPanels {
                regionLayer(analysis.panels, lineWidth: 2.4)
            }
            if configuration.showsTexts {
                regionLayer(analysis.texts, lineWidth: 1.5)
            }
            if configuration.showsBalloons {
                regionLayer(analysis.balloons, lineWidth: 1.8)
            }
            if configuration.showsOnomatopoeias {
                regionLayer(analysis.onomatopoeias, lineWidth: 1.5)
            }
            if configuration.showsRelations, let semanticPage {
                relationLayer(semanticPage)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func regionLayer(
        _ regions: [MangaVisionRegion],
        lineWidth: CGFloat
    ) -> some View {
        ForEach(regions) { region in
            let rect = displayRect(region.normalizedRect)
            Rectangle()
                .stroke(style: StrokeStyle(lineWidth: lineWidth, dash: dash(for: region.type)))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .overlay(alignment: .topLeading) {
                    Text("\(region.type.rawValue) \(Int(region.confidence * 100))")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(.black.opacity(0.72))
                        .offset(x: rect.minX, y: rect.minY)
                }
        }
    }

    @ViewBuilder
    private func relationLayer(_ page: MangaSemanticPage) -> some View {
        Canvas { context, _ in
            for (panelIndex, panel) in page.panels.enumerated() {
                let panelRect = displayRect(panel.panel.normalizedRect)
                context.draw(
                    Text("P\(panelIndex + 1)").font(.system(size: 10, weight: .bold)),
                    at: CGPoint(x: panelRect.minX + 12, y: panelRect.minY + 12)
                )
                for semanticRegion in panel.texts {
                    let contentRect = displayRect(semanticRegion.region.normalizedRect)
                    let from = CGPoint(x: contentRect.midX, y: contentRect.midY)
                    let to = CGPoint(x: panelRect.midX, y: panelRect.midY)
                    var path = Path()
                    path.move(to: from)
                    path.addLine(to: to)
                    context.stroke(
                        path,
                        with: .foreground,
                        style: StrokeStyle(lineWidth: 0.6, dash: [3, 3])
                    )
                }
            }
        }
    }

    private func displayRect(_ normalized: CGRect) -> CGRect {
        CGRect(
            x: imageRect.minX + normalized.minX * imageRect.width,
            y: imageRect.minY + normalized.minY * imageRect.height,
            width: normalized.width * imageRect.width,
            height: normalized.height * imageRect.height
        )
    }

    private func dash(for type: MangaRegionType) -> [CGFloat] {
        switch type {
        case .panel: []
        case .text: [5, 2]
        case .balloon: [10, 2, 2, 2]
        case .onomatopoeia: [3, 2, 8, 2]
        }
    }
}
#endif
