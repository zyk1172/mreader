import SwiftUI

/// Development-only visualizer for validating detected boxes, confidence and reading order.
/// It is deliberately passive: it never changes the reader image or consumes gestures.
struct PanelDebugOverlay: View {
    let layout: PanelPageLayout
    let activePanelIndex: Int?
    let imageAspectRatio: CGFloat

    init(
        layout: PanelPageLayout,
        activePanelIndex: Int? = nil,
        imageAspectRatio: CGFloat
    ) {
        self.layout = layout
        self.activePanelIndex = activePanelIndex
        self.imageAspectRatio = imageAspectRatio
    }

    var body: some View {
        GeometryReader { proxy in
            let imageRect = GuidedPanelViewport.aspectFitRect(
                aspectRatio: imageAspectRatio,
                in: CGRect(origin: .zero, size: proxy.size)
            )
            ZStack(alignment: .topLeading) {
                ForEach(layout.panels.indices, id: \.self) { index in
                    let panel = layout.panels[index]
                    let rect = displayRect(panel.rect.cgRect, in: imageRect)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(
                            index == activePanelIndex ? Color.green : Color.orange,
                            style: StrokeStyle(
                                lineWidth: index == activePanelIndex ? 3 : 1.5,
                                dash: index == activePanelIndex ? [] : [6, 3]
                            )
                        )
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)

                    Text(label(for: panel, index: index))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(.white)
                        .position(
                            x: min(max(rect.minX + 48, 48), max(proxy.size.width - 48, 48)),
                            y: max(rect.minY + 10, 10)
                        )
                }

                Text(statusLabel)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.72), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(8)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var statusLabel: String {
        let fallback = layout.usedFallback ? " fallback" : ""
        return "\(layout.detectorIdentifier) · \(layout.panels.count) panels\(fallback)"
    }

    private func label(for panel: PanelLayoutPanel, index: Int) -> String {
        let confidence = Int((panel.confidence * 100).rounded())
        return "#\(index + 1) \(confidence)% \(panel.source.rawValue)"
    }

    private func displayRect(_ normalized: CGRect, in imageRect: CGRect) -> CGRect {
        CGRect(
            x: imageRect.minX + normalized.minX * imageRect.width,
            y: imageRect.minY + normalized.minY * imageRect.height,
            width: normalized.width * imageRect.width,
            height: normalized.height * imageRect.height
        )
    }
}
