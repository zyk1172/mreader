import SwiftUI

#if DEBUG
struct MangaVisionDebugOverlayConfiguration: Sendable, Equatable {
    var showsPanels = true
    var showsTexts = true
    var showsBalloons = true
    var showsOnomatopoeias = true
}

/// Developer-only overlay for inspecting the shared Manga Vision analysis.
/// `imageRect` is the actual displayed comic-page rectangle inside the reader
/// viewport, so normalized page coordinates stay correct under aspect-fit,
/// letterboxing, zoom and the existing reader coordinate system.
struct MangaVisionDebugOverlay: View {
    let analysis: MangaPageAnalysis
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
            if configuration.showsPanels {
                contourLayer(analysis.panels)
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

    /// Draws the mask-derived outline that the segmentation model produces for every
    /// region. A missing outline means the mask was rejected, not that the model is
    /// bounding-box-only.
    @ViewBuilder
    private func contourLayer(_ regions: [MangaVisionRegion]) -> some View {
        ForEach(regions) { region in
            if let contour = region.contour, contour.points.count >= 3 {
                Path { path in
                    let points = contour.cgPoints.map(displayPoint)
                    guard let first = points.first else { return }
                    path.move(to: first)
                    for point in points.dropFirst() { path.addLine(to: point) }
                    path.closeSubpath()
                }
                .stroke(Color.accentColor.opacity(0.85), lineWidth: 0.8)
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

    private func displayPoint(_ normalized: CGPoint) -> CGPoint {
        CGPoint(
            x: imageRect.minX + normalized.x * imageRect.width,
            y: imageRect.minY + normalized.y * imageRect.height
        )
    }

    private func dash(for type: MangaRegionType) -> [CGFloat] {
        switch type {
        case .panel: []
        case .text: [5, 2]
        case .balloon: [10, 2, 2, 2]
        case .onomatopoeia: [2, 2]
        }
    }
}
#endif
