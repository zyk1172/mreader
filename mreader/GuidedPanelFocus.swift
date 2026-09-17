import CoreGraphics
import Foundation
import Observation
import SwiftUI
import UIKit

nonisolated enum GuidedPanelFocusPolicy {
    enum Mode: Equatable, Sendable {
        case spotlight
    }

    static let panelExpansionRatio: CGFloat = 0.018
    static let dimOpacity: Double = 0.30
    static let vignetteOpacity: Double = 0.16
    static let focusStrokeOpacity: Double = 0.18
    static let focusCornerRadius: CGFloat = 9

    static func mode(
        isLowPowerModeEnabled: Bool,
        thermalState: ProcessInfo.ThermalState
    ) -> Mode {
        // Spotlight uses only lightweight vector compositing. There is no duplicate
        // page texture or Gaussian render, so the same visual treatment is safe in
        // Low Power Mode and under thermal pressure.
        _ = isLowPowerModeEnabled
        _ = thermalState
        return .spotlight
    }

    static var currentMode: Mode {
        mode(
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: ProcessInfo.processInfo.thermalState
        )
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

/// Compatibility object retained for GuidedPanelReader. The old implementation
/// cached low-resolution Gaussian copies of pages; spotlight rendering no longer
/// needs those copies or background Core Image work.
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

private struct GuidedPanelInverseFocusMask: Shape {
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
            let gradientCenter = UnitPoint(
                x: min(max(focusRect.midX / viewportSize.width, 0), 1),
                y: min(max(focusRect.midY / viewportSize.height, 0), 1)
            )
            let startRadius = max(min(focusRect.width, focusRect.height) * 0.40, 1)
            let endRadius = max(viewportSize.width, viewportSize.height) * 0.90

            ZStack {
                Color.black.opacity(GuidedPanelFocusPolicy.dimOpacity)
                RadialGradient(
                    colors: [
                        .clear,
                        Color.black.opacity(GuidedPanelFocusPolicy.vignetteOpacity)
                    ],
                    center: gradientCenter,
                    startRadius: startRadius,
                    endRadius: endRadius
                )
            }
            .frame(width: viewportSize.width, height: viewportSize.height)
            .mask {
                GuidedPanelInverseFocusMask(focusRect: focusRect)
                    .fill(Color.white, style: FillStyle(eoFill: true))
            }
            .overlay {
                RoundedRectangle(
                    cornerRadius: GuidedPanelFocusPolicy.focusCornerRadius,
                    style: .continuous
                )
                .strokeBorder(
                    Color.white.opacity(GuidedPanelFocusPolicy.focusStrokeOpacity),
                    lineWidth: 0.8
                )
                .frame(width: max(focusRect.width, 0), height: max(focusRect.height, 0))
                .position(x: focusRect.midX, y: focusRect.midY)
                .shadow(color: .black.opacity(0.30), radius: 1.5)
            }
            .opacity(opacity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                // Stop any legacy blur render that may still belong to a live reader
                // instance from before the view was rebuilt.
                cancelPreviewWork()
                _ = store
                _ = pageURL
                _ = requestPreview
            }
        }
    }
}
