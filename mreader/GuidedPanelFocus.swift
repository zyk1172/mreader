import CoreGraphics
import Foundation
import Observation
import SwiftUI
import UIKit

nonisolated enum GuidedPanelFocusPolicy {
    enum Mode: Equatable, Sendable {
        case liquidGlass
        // Source compatibility for older callers/tests. Guided Panel now always resolves
        // to native Liquid Glass and never generates a blurred page bitmap.
        case gaussian
        case spotlight
    }

    static let panelExpansionRatio: CGFloat = 0.018
    static let featherBlurRadius: CGFloat = 88
    static let nearClearance: CGFloat = 38
    static let glassTintOpacity: Double = 0.24
    static let farDimOpacity: Double = 0.06
    static let focusStrokeOpacity: Double = 0.08
    static let focusCornerRadius: CGFloat = 9

    static func mode(
        isLowPowerModeEnabled: Bool,
        thermalState: ProcessInfo.ThermalState
    ) -> Mode {
        // Liquid Glass is a native compositing effect. Unlike the old Gaussian preview,
        // it does not compete with N+1 image decode / panel inference, so the visual style
        // remains stable under power and thermal pressure.
        _ = isLowPowerModeEnabled
        _ = thermalState
        return .liquidGlass
    }

    static var currentMode: Mode {
        mode(
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: ProcessInfo.processInfo.thermalState
        )
    }

    /// Smooth convex response used by the distance feather.
    /// f(t) = t² is C1-continuous on [0, 1], starts with zero slope and accelerates
    /// monotonically without the abrupt mid-field darkening produced by the old t³ ramp.
    static func acceleratedFeatherAlpha(_ alpha: Double) -> Double {
        let t = min(max(alpha, 0), 1)
        return t * t
    }
}

nonisolated enum GuidedPanelFocusGeometry {
    static func expandedNormalizedPanel(
        _ panel: CGRect,
        expansionRatio: CGFloat = GuidedPanelFocusPolicy.panelExpansionRatio
    ) -> CGRect {
        GuidedPanelViewport.expandedAndClamped(
            panel,
            contextPadding: min(max(expansionRatio, 0), 0.20)
        )
    }

    static func pageFocusRect(
        normalizedPanel: CGRect,
        sourceSize: CGSize,
        viewportSize: CGSize,
        expansionRatio: CGFloat = GuidedPanelFocusPolicy.panelExpansionRatio
    ) -> CGRect {
        guard sourceSize.width > 0,
              sourceSize.height > 0,
              viewportSize.width > 0,
              viewportSize.height > 0 else { return .zero }

        let imageRect = GuidedPanelViewport.aspectFitRect(
            aspectRatio: sourceSize.width / sourceSize.height,
            in: CGRect(origin: .zero, size: viewportSize)
        )
        let panel = expandedNormalizedPanel(
            normalizedPanel,
            expansionRatio: expansionRatio
        )
        return CGRect(
            x: imageRect.minX + panel.minX * imageRect.width,
            y: imageRect.minY + panel.minY * imageRect.height,
            width: panel.width * imageRect.width,
            height: panel.height * imageRect.height
        )
    }

    static func screenFocusRect(
        normalizedPanel: CGRect,
        sourceSize: CGSize,
        viewportSize: CGSize,
        cameraScale: CGFloat,
        cameraOffset: CGSize,
        expansionRatio: CGFloat = GuidedPanelFocusPolicy.panelExpansionRatio
    ) -> CGRect {
        let pageRect = pageFocusRect(
            normalizedPanel: normalizedPanel,
            sourceSize: sourceSize,
            viewportSize: viewportSize,
            expansionRatio: expansionRatio
        )
        guard !pageRect.isEmpty else { return .zero }

        let scale = max(cameraScale, 0)
        let center = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        return CGRect(
            x: (pageRect.minX - center.x) * scale + center.x + cameraOffset.width,
            y: (pageRect.minY - center.y) * scale + center.y + cameraOffset.height,
            width: pageRect.width * scale,
            height: pageRect.height * scale
        )
    }
}

/// Compatibility shell retained so the reader's page-transition code does not need to change
/// identity or state ownership. Liquid Glass is rendered directly by SwiftUI, therefore this
/// store deliberately performs no bitmap generation, Core Image work, or page-cache reads.
/// Keeping `prewarm` as a no-op also removes the regression where focus-preview work competed
/// with N+1 decode and panel-layout prefetch at the exact moment the reader approached a page edge.
@MainActor
@Observable
final class GuidedPanelFocusPreviewStore {
    private(set) var previews: [String: UIImage] = [:]

    func preview(for url: URL) -> UIImage? {
        _ = url
        return nil
    }

    func prewarm(
        url: URL,
        image: UIImage,
        modeOverride: GuidedPanelFocusPolicy.Mode? = nil
    ) {
        _ = url
        _ = image
        _ = modeOverride
    }

    func cancelAll() {
        previews.removeAll(keepingCapacity: true)
    }
}

nonisolated private struct GuidedPanelInverseFocusMask: Shape {
    var focusRect: CGRect

    var animatableData: AnimatablePair<
        AnimatablePair<CGFloat, CGFloat>,
        AnimatablePair<CGFloat, CGFloat>
    > {
        get {
            AnimatablePair(
                AnimatablePair(focusRect.origin.x, focusRect.origin.y),
                AnimatablePair(focusRect.size.width, focusRect.size.height)
            )
        }
        set {
            focusRect = CGRect(
                x: newValue.first.first,
                y: newValue.first.second,
                width: newValue.second.first,
                height: newValue.second.second
            )
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        if focusRect.width > 0, focusRect.height > 0 {
            path.addRoundedRect(
                in: focusRect,
                cornerSize: CGSize(
                    width: GuidedPanelFocusPolicy.focusCornerRadius,
                    height: GuidedPanelFocusPolicy.focusCornerRadius
                )
            )
        }
        return path
    }
}

/// Smooth continuous feather for Liquid Glass.
///
/// One blurred inverse rounded-rectangle gives a single continuous 2D field across edges and
/// corners. Squaring that field by masking it with itself implements f(t)=t²: the change rate
/// starts near zero beside the active panel, then increases steadily with distance. The larger
/// clearance keeps the first visible glass faint instead of producing a dark ring at the panel.
private struct GuidedPanelGlassFeatherMask: View {
    let focusRect: CGRect
    let viewportSize: CGSize

    private var expandedFocusRect: CGRect {
        focusRect.insetBy(
            dx: -GuidedPanelFocusPolicy.nearClearance,
            dy: -GuidedPanelFocusPolicy.nearClearance
        )
    }

    private var baseMask: some View {
        GuidedPanelInverseFocusMask(focusRect: expandedFocusRect)
            .fill(Color.white, style: FillStyle(eoFill: true))
            .blur(radius: GuidedPanelFocusPolicy.featherBlurRadius)
            .frame(width: viewportSize.width, height: viewportSize.height)
            .clipped()
    }

    var body: some View {
        baseMask
            .mask { baseMask }
    }
}

struct GuidedPanelFocusOverlay: View {
    let store: GuidedPanelFocusPreviewStore
    let pageURL: URL
    let requestPreview: () -> Void
    let cancelPreviewWork: () -> Void
    let normalizedPanel: CGRect?
    let sourceSize: CGSize
    let viewportSize: CGSize
    let cameraScale: CGFloat
    let cameraOffset: CGSize
    var opacity: Double = 1

    var body: some View {
        if let normalizedPanel,
           sourceSize.width > 0,
           sourceSize.height > 0,
           viewportSize.width > 0,
           viewportSize.height > 0 {
            let focusRect = GuidedPanelFocusGeometry.screenFocusRect(
                normalizedPanel: normalizedPanel,
                sourceSize: sourceSize,
                viewportSize: viewportSize,
                cameraScale: cameraScale,
                cameraOffset: cameraOffset
            )

            ZStack {
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: viewportSize.width, height: viewportSize.height)
                    .glassEffect(
                        .regular.tint(Color.black.opacity(GuidedPanelFocusPolicy.glassTintOpacity)),
                        in: Rectangle()
                    )

                // Keep only a very small neutral veil. The obscuring effect now comes from
                // Liquid Glass itself rather than a black curtain, so the material stays visible.
                Color.black.opacity(GuidedPanelFocusPolicy.farDimOpacity)
            }
            .frame(width: viewportSize.width, height: viewportSize.height)
            .mask {
                GuidedPanelGlassFeatherMask(
                    focusRect: focusRect,
                    viewportSize: viewportSize
                )
            }
            .overlay {
                RoundedRectangle(
                    cornerRadius: GuidedPanelFocusPolicy.focusCornerRadius,
                    style: .continuous
                )
                .strokeBorder(
                    Color.white.opacity(GuidedPanelFocusPolicy.focusStrokeOpacity),
                    lineWidth: 0.5
                )
                .frame(width: max(focusRect.width, 0), height: max(focusRect.height, 0))
                .position(x: focusRect.midX, y: focusRect.midY)
                .shadow(color: .black.opacity(0.12), radius: 1)
            }
            .opacity(opacity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                // Keep the old call-site contract inert. In particular, do not request or
                // generate a per-page focus bitmap here; next-page buffering has priority.
                _ = store
                _ = pageURL
                _ = requestPreview
                _ = cancelPreviewWork
            }
        }
    }
}
