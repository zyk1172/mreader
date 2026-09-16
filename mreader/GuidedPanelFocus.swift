import Combine
import CoreGraphics
import CoreImage
import Observation
import SwiftUI
import UIKit

nonisolated enum GuidedPanelFocusPolicy {
    enum Mode: Equatable, Sendable {
        case blurred
        case dimOnly
    }

    static let previewMaxPixelSize: CGFloat = 768
    static let previewBlurRadius: CGFloat = 6
    static let panelExpansionRatio: CGFloat = 0.02
    static let featherRadius: CGFloat = 14
    static let dimOpacity: Double = 0.12
    static let maximumCachedPages = 4

    static func mode(
        isLowPowerModeEnabled: Bool,
        thermalState: ProcessInfo.ThermalState
    ) -> Mode {
        guard !isLowPowerModeEnabled else { return .dimOnly }
        switch thermalState {
        case .serious, .critical:
            return .dimOnly
        case .nominal, .fair:
            return .blurred
        @unknown default:
            return .dimOnly
        }
    }

    static var currentMode: Mode {
        mode(
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: ProcessInfo.processInfo.thermalState
        )
    }

    static func shouldDisplayBlur(previewAvailable: Bool, mode: Mode) -> Bool {
        mode == .blurred && previewAvailable
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

/// Immutable Core Graphics images are safe to hand to the serial preview actor. The wrapper
/// makes that ownership explicit without making UIImage itself cross an isolation boundary.
private struct GuidedPanelFocusCGImage: @unchecked Sendable {
    let value: CGImage
}

private actor GuidedPanelFocusPreviewRenderer {
    static let shared = GuidedPanelFocusPreviewRenderer()

    private let context = CIContext()

    func render(_ source: GuidedPanelFocusCGImage) -> GuidedPanelFocusCGImage? {
        let cgImage = source.value
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let longestSide = max(width, height)
        guard longestSide > 0 else { return nil }

        let resizeScale = min(1, GuidedPanelFocusPolicy.previewMaxPixelSize / longestSide)
        let input = CIImage(cgImage: cgImage)
        let resized = input.transformed(
            by: CGAffineTransform(scaleX: resizeScale, y: resizeScale)
        )
        let targetExtent = resized.extent.integral
        guard !targetExtent.isEmpty else { return nil }

        let blurred = resized
            .clampedToExtent()
            .applyingFilter(
                "CIGaussianBlur",
                parameters: [kCIInputRadiusKey: GuidedPanelFocusPolicy.previewBlurRadius]
            )
            .cropped(to: targetExtent)

        guard let output = context.createCGImage(blurred, from: targetExtent) else { return nil }
        return GuidedPanelFocusCGImage(value: output)
    }
}

@MainActor
@Observable
final class GuidedPanelFocusPreviewStore {
    private(set) var previews: [String: UIImage] = [:]
    private var recency: [String] = []
    private var inFlight: Set<String> = []
    private var tasks: [String: Task<Void, Never>] = [:]
    private var requestIDs: [String: UUID] = [:]

    func preview(for url: URL) -> UIImage? {
        previews[url.absoluteString]
    }

    /// Reuses only an already-decoded ReaderImageCache entry. This is safe to call when a
    /// cached panel layout is restored or when system power/thermal pressure recovers.
    func prewarmCached(url: URL) {
        let key = url.absoluteString
        guard previews[key] == nil, !inFlight.contains(key) else { return }
        guard let image = ReaderImageCache.shared.cachedImage(
            for: url,
            maxPixelSize: ReaderImageCache.fitScreenMaxPixelSize
        ) else { return }
        prewarm(url: url, image: image)
    }

    func handleSystemModeChange(_ mode: GuidedPanelFocusPolicy.Mode, activeURL: URL) {
        switch mode {
        case .blurred:
            prewarmCached(url: activeURL)
        case .dimOnly:
            // Stop queued work immediately. Cached previews are retained but hidden so returning
            // to normal power/thermal state is instant and does not require another blur pass.
            cancelAll()
        }
    }

    /// Starts only from an image that Guided Panel already decoded for layout/prefetch work.
    /// It never loads from disk/network and never blocks panel navigation waiting for the result.
    func prewarm(url: URL, image: UIImage) {
        guard GuidedPanelFocusPolicy.currentMode == .blurred else { return }
        let key = url.absoluteString
        guard previews[key] == nil, !inFlight.contains(key), let cgImage = image.cgImage else { return }

        let requestID = UUID()
        inFlight.insert(key)
        requestIDs[key] = requestID
        let immutableSource = GuidedPanelFocusCGImage(value: cgImage)
        tasks[key] = Task { @MainActor [weak self] in
            let rendered = await GuidedPanelFocusPreviewRenderer.shared.render(immutableSource)
            guard let self, self.requestIDs[key] == requestID else { return }
            self.inFlight.remove(key)
            self.tasks[key] = nil
            self.requestIDs[key] = nil
            guard !Task.isCancelled, let rendered else { return }

            self.previews[key] = UIImage(cgImage: rendered.value, scale: 1, orientation: image.imageOrientation)
            self.touch(key)
            self.trimIfNeeded()
        }
    }

    func cancelAll() {
        for task in tasks.values {
            task.cancel()
        }
        tasks.removeAll()
        inFlight.removeAll()
        requestIDs.removeAll()
    }

    private func touch(_ key: String) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private func trimIfNeeded() {
        while recency.count > GuidedPanelFocusPolicy.maximumCachedPages {
            let victim = recency.removeFirst()
            previews[victim] = nil
        }
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
                cornerSize: CGSize(width: 8, height: 8)
            )
        }
        return path
    }
}

struct GuidedPanelFocusOverlay: View {
    @State private var mode = GuidedPanelFocusPolicy.currentMode

    let store: GuidedPanelFocusPreviewStore
    let pageURL: URL
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

            let preview = store.preview(for: pageURL)

            ZStack {
                if GuidedPanelFocusPolicy.shouldDisplayBlur(
                    previewAvailable: preview != nil,
                    mode: mode
                ), let preview {
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
                GuidedPanelInverseFocusMask(focusRect: focusRect)
                    .fill(Color.white, style: FillStyle(eoFill: true))
                    .blur(radius: GuidedPanelFocusPolicy.featherRadius)
            }
            .opacity(opacity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: pageURL.absoluteString) {
                if mode == .blurred {
                    store.prewarmCached(url: pageURL)
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(for: ProcessInfo.powerStateDidChangeNotification)
            ) { _ in
                refreshSystemMode()
            }
            .onReceive(
                NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            ) { _ in
                refreshSystemMode()
            }
        }
    }

    private func refreshSystemMode() {
        let nextMode = GuidedPanelFocusPolicy.currentMode
        guard nextMode != mode else { return }
        mode = nextMode
        store.handleSystemModeChange(nextMode, activeURL: pageURL)
    }
}
