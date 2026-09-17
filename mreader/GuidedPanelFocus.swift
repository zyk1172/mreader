import CoreGraphics
import CoreImage
import Foundation
import Observation
import SwiftUI
import UIKit

nonisolated enum GuidedPanelFocusPolicy {
    enum Mode: Equatable, Sendable {
        case gaussian
        // Source-compatibility for older callers/tests. New code always resolves to gaussian.
        case spotlight
    }

    static let panelExpansionRatio: CGFloat = 0.018
    static let dimOpacity: Double = 0.34
    static let featherWidth: CGFloat = 96
    static let gaussianPreviewRadius: CGFloat = 42
    static let previewMaxDimension: CGFloat = 960
    static let focusStrokeOpacity: Double = 0.12
    static let focusCornerRadius: CGFloat = 9

    static func mode(
        isLowPowerModeEnabled: Bool,
        thermalState: ProcessInfo.ThermalState
    ) -> Mode {
        // The Gaussian layer is rendered once into a bounded low-resolution preview,
        // not recomputed every animation frame. Keep the same treatment under power
        // and thermal pressure so Guided Panel does not visibly change style mid-read.
        _ = isLowPowerModeEnabled
        _ = thermalState
        return .gaussian
    }

    static var currentMode: Mode {
        mode(
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: ProcessInfo.processInfo.thermalState
        )
    }

    /// Linear alpha ramp used by the focus feather: the active panel is fully clear,
    /// then opacity grows continuously with distance until the configured feather edge.
    static func linearFeatherAlpha(
        distanceFromFocus: CGFloat,
        featherWidth: CGFloat = GuidedPanelFocusPolicy.featherWidth
    ) -> Double {
        guard featherWidth > 0 else { return distanceFromFocus > 0 ? 1 : 0 }
        return Double(min(max(distanceFromFocus / featherWidth, 0), 1))
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

/// Bounded Gaussian preview cache used by Guided Panel focus isolation.
///
/// The source reader image remains untouched. Each page produces at most one <= 960px
/// blurred copy off the main actor, which is then transformed with the same camera as the
/// live page. This keeps the effect stable without blurring the full-resolution page every frame.
@MainActor
@Observable
final class GuidedPanelFocusPreviewStore {
    private(set) var previews: [String: UIImage] = [:]
    private var pending: Set<String> = []
    private var generation = UUID()
    private let maximumCachedPreviews = 4

    func preview(for url: URL) -> UIImage? {
        previews[url.absoluteString]
    }

    func prewarm(
        url: URL,
        image: UIImage,
        modeOverride: GuidedPanelFocusPolicy.Mode? = nil
    ) {
        _ = modeOverride ?? GuidedPanelFocusPolicy.currentMode
        let key = url.absoluteString
        guard previews[key] == nil, !pending.contains(key) else { return }
        pending.insert(key)
        let expectedGeneration = generation

        Task { [weak self] in
            let preview = await Task.detached(priority: .utility) {
                Self.makeGaussianPreview(from: image)
            }.value
            guard let self, self.generation == expectedGeneration else { return }
            self.pending.remove(key)
            guard let preview else { return }
            self.previews[key] = preview
            self.trimCache(keeping: key)
        }
    }

    func cancelAll() {
        generation = UUID()
        pending.removeAll(keepingCapacity: true)
        previews.removeAll(keepingCapacity: true)
    }

    private func trimCache(keeping key: String) {
        while previews.count > maximumCachedPreviews,
              let victim = previews.keys.first(where: { $0 != key }) {
            previews.removeValue(forKey: victim)
        }
    }

    private nonisolated static func makeGaussianPreview(from image: UIImage) -> UIImage? {
        guard let input = CIImage(image: image) else { return nil }
        let sourceExtent = input.extent.standardized
        guard sourceExtent.width > 0, sourceExtent.height > 0 else { return nil }

        let longestSide = max(sourceExtent.width, sourceExtent.height)
        let scale = min(1, GuidedPanelFocusPolicy.previewMaxDimension / longestSide)
        let resized = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let extent = resized.extent.standardized.integral
        guard extent.width > 0, extent.height > 0 else { return nil }

        let blurred = resized
            .clampedToExtent()
            .applyingFilter(
                "CIGaussianBlur",
                parameters: [kCIInputRadiusKey: GuidedPanelFocusPolicy.gaussianPreviewRadius]
            )
            .cropped(to: extent)

        let context = CIContext(options: [CIContextOption.cacheIntermediates: false])
        guard let output = context.createCGImage(blurred, from: extent) else { return nil }
        return UIImage(cgImage: output)
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

/// Piecewise linear distance feather around the focused panel.
///
/// The four strips are exactly linear on each panel edge. Their overlap at corners remains
/// continuous, while the far field is filled by the inverse outer rectangle. This avoids the
/// old hard cut at the panel boundary and does not use a radial gradient centered on the panel.
private struct GuidedPanelLinearFeatherMask: View {
    let focusRect: CGRect
    let viewportSize: CGSize
    let featherWidth: CGFloat

    var body: some View {
        let feather = max(featherWidth, 1)
        let outerRect = focusRect.insetBy(dx: -feather, dy: -feather)

        ZStack {
            GuidedPanelInverseFocusMask(focusRect: outerRect)
                .fill(Color.white, style: FillStyle(eoFill: true))

            LinearGradient(
                colors: [.white, .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(width: max(outerRect.width, 1), height: feather)
            .position(x: focusRect.midX, y: focusRect.minY - feather / 2)

            LinearGradient(
                colors: [.clear, .white],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(width: max(outerRect.width, 1), height: feather)
            .position(x: focusRect.midX, y: focusRect.maxY + feather / 2)

            LinearGradient(
                colors: [.white, .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: feather, height: max(focusRect.height, 1))
            .position(x: focusRect.minX - feather / 2, y: focusRect.midY)

            LinearGradient(
                colors: [.clear, .white],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: feather, height: max(focusRect.height, 1))
            .position(x: focusRect.maxX + feather / 2, y: focusRect.midY)
        }
        .frame(width: viewportSize.width, height: viewportSize.height)
        .clipped()
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
                if let preview = store.preview(for: pageURL) {
                    Image(uiImage: preview)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: viewportSize.width, height: viewportSize.height)
                        .scaleEffect(cameraScale)
                        .offset(cameraOffset)
                }

                Color.black.opacity(GuidedPanelFocusPolicy.dimOpacity)
            }
            .frame(width: viewportSize.width, height: viewportSize.height)
            .mask {
                GuidedPanelLinearFeatherMask(
                    focusRect: focusRect,
                    viewportSize: viewportSize,
                    featherWidth: GuidedPanelFocusPolicy.featherWidth
                )
            }
            .overlay {
                RoundedRectangle(
                    cornerRadius: GuidedPanelFocusPolicy.focusCornerRadius,
                    style: .continuous
                )
                .strokeBorder(
                    Color.white.opacity(GuidedPanelFocusPolicy.focusStrokeOpacity),
                    lineWidth: 0.7
                )
                .frame(width: max(focusRect.width, 0), height: max(focusRect.height, 0))
                .position(x: focusRect.midX, y: focusRect.midY)
                .shadow(color: .black.opacity(0.24), radius: 1.5)
            }
            .opacity(opacity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                // The normal Guided Panel path prewarms during panel detection/prefetch.
                // This is a zero-I/O fallback when the decoded page is already cached.
                requestPreview()
                _ = cancelPreviewWork
            }
        }
    }
}
