import SwiftUI

#if DEBUG
struct MangaVisionDebugOverlayConfiguration: Sendable, Equatable {
    var showsPanels = true
    var showsTexts = true
    var showsFaces = true
    var showsBodies = true
    var showsRelations = true
}

struct MangaVisionDebugOverlay: View {
    let analysis: MangaPageAnalysis
    let semanticPage: MangaSemanticPage?
    let configuration: MangaVisionDebugOverlayConfiguration

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if configuration.showsPanels {
                    regionLayer(analysis.panels, size: proxy.size, lineWidth: 2.4)
                }
                if configuration.showsTexts {
                    regionLayer(analysis.texts, size: proxy.size, lineWidth: 1.5)
                }
                if configuration.showsFaces {
                    regionLayer(analysis.faces, size: proxy.size, lineWidth: 1.5)
                }
                if configuration.showsBodies {
                    regionLayer(analysis.bodies, size: proxy.size, lineWidth: 1.5)
                }
                if configuration.showsRelations, let semanticPage {
                    relationLayer(semanticPage, size: proxy.size)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func regionLayer(
        _ regions: [MangaVisionRegion],
        size: CGSize,
        lineWidth: CGFloat
    ) -> some View {
        ForEach(regions) { region in
            let rect = displayRect(region.normalizedRect, in: size)
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
    private func relationLayer(_ page: MangaSemanticPage, size: CGSize) -> some View {
        Canvas { context, _ in
            for (panelIndex, panel) in page.panels.enumerated() {
                let panelRect = displayRect(panel.panel.normalizedRect, in: size)
                context.draw(
                    Text("P\(panelIndex + 1)").font(.system(size: 10, weight: .bold)),
                    at: CGPoint(x: panelRect.minX + 12, y: panelRect.minY + 12)
                )
                for person in panel.persons {
                    let personRect = person.face?.normalizedRect ?? person.body?.normalizedRect
                    guard let personRect else { continue }
                    let from = CGPoint(
                        x: displayRect(personRect, in: size).midX,
                        y: displayRect(personRect, in: size).midY
                    )
                    let to = CGPoint(x: panelRect.midX, y: panelRect.midY)
                    var path = Path()
                    path.move(to: from)
                    path.addLine(to: to)
                    context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
                }
            }
        }
    }

    private func displayRect(_ normalized: CGRect, in size: CGSize) -> CGRect {
        CGRect(
            x: normalized.minX * size.width,
            y: normalized.minY * size.height,
            width: normalized.width * size.width,
            height: normalized.height * size.height
        )
    }

    private func dash(for type: MangaRegionType) -> [CGFloat] {
        switch type {
        case .panel: []
        case .text: [5, 2]
        case .face: [2, 2]
        case .body: [8, 3]
        }
    }
}
#endif
