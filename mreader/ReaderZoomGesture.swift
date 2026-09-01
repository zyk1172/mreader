import SwiftUI
import UIKit

final class ReaderZoomPinchGestureRecognizer: UIPinchGestureRecognizer {}

final class ReaderZoomPanGestureRecognizer: UIPanGestureRecognizer {
    /// Exposed to the reader-dismiss coordinator so a one-finger downward
    /// drag can never steal a touch from an already zoomed page.
    var isZoomActive = false
}

nonisolated struct ReaderZoomTransform: Equatable {
    let scale: CGFloat
    let offset: CGSize
}

/// Pure zoom math keeps the touch coordinator small and makes the focal-point
/// and pan-boundary contracts testable without requiring a device gesture.
nonisolated enum ReaderZoomMath {
    static let minimumScale: CGFloat = 1
    static let settleThreshold: CGFloat = 1.02
    static let defaultMaximumScale: CGFloat = 5

    static func pinchTransform(
        from base: ReaderZoomTransform,
        magnification: CGFloat,
        focalPoint: CGPoint,
        viewportSize: CGSize,
        contentSize: CGSize,
        maximumScale: CGFloat = defaultMaximumScale
    ) -> ReaderZoomTransform {
        let oldScale = max(base.scale, minimumScale)
        let nextScale = min(
            max(oldScale * max(magnification, 0.01), minimumScale),
            max(maximumScale, minimumScale)
        )
        let ratio = nextScale / oldScale
        let center = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        let focalVector = CGPoint(
            x: focalPoint.x - center.x,
            y: focalPoint.y - center.y
        )
        let nextOffset = CGSize(
            width: base.offset.width + (1 - ratio) * (focalVector.x - base.offset.width),
            height: base.offset.height + (1 - ratio) * (focalVector.y - base.offset.height)
        )
        return ReaderZoomTransform(
            scale: nextScale,
            offset: clampedOffset(
                nextOffset,
                scale: nextScale,
                viewportSize: viewportSize,
                contentSize: contentSize
            )
        )
    }

    static func pannedTransform(
        from base: ReaderZoomTransform,
        translation: CGSize,
        viewportSize: CGSize,
        contentSize: CGSize
    ) -> ReaderZoomTransform {
        let proposedOffset = CGSize(
            width: base.offset.width + translation.width,
            height: base.offset.height + translation.height
        )
        return ReaderZoomTransform(
            scale: max(base.scale, minimumScale),
            offset: clampedOffset(
                proposedOffset,
                scale: max(base.scale, minimumScale),
                viewportSize: viewportSize,
                contentSize: contentSize
            )
        )
    }

    static func settledTransform(
        _ transform: ReaderZoomTransform,
        viewportSize: CGSize,
        contentSize: CGSize,
        maximumScale: CGFloat = defaultMaximumScale
    ) -> ReaderZoomTransform {
        let scale = min(
            max(transform.scale, minimumScale),
            max(maximumScale, minimumScale)
        )
        guard scale > settleThreshold else {
            return ReaderZoomTransform(scale: minimumScale, offset: .zero)
        }
        return ReaderZoomTransform(
            scale: scale,
            offset: clampedOffset(
                transform.offset,
                scale: scale,
                viewportSize: viewportSize,
                contentSize: contentSize
            )
        )
    }

    static func clampedOffset(
        _ offset: CGSize,
        scale: CGFloat,
        viewportSize: CGSize,
        contentSize: CGSize
    ) -> CGSize {
        let safeScale = max(scale, minimumScale)
        let scaledContentSize = CGSize(
            width: max(contentSize.width, 0) * safeScale,
            height: max(contentSize.height, 0) * safeScale
        )
        let maximumX = max((scaledContentSize.width - max(viewportSize.width, 0)) / 2, 0)
        let maximumY = max((scaledContentSize.height - max(viewportSize.height, 0)) / 2, 0)
        return CGSize(
            width: min(max(offset.width, -maximumX), maximumX),
            height: min(max(offset.height, -maximumY), maximumY)
        )
    }
}

struct ReaderZoomGestureView: UIViewRepresentable {
    let scale: CGFloat
    let offset: CGSize
    let viewportSize: CGSize
    let contentSize: CGSize
    let maximumScale: CGFloat
    let onTransformChanged: (ReaderZoomTransform) -> Void
    let onGestureEnded: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            scale: scale,
            offset: offset,
            viewportSize: viewportSize,
            contentSize: contentSize,
            maximumScale: maximumScale,
            onTransformChanged: onTransformChanged,
            onGestureEnded: onGestureEnded
        )
    }

    func makeUIView(context: Context) -> InstallView {
        let view = InstallView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: InstallView, context: Context) {
        context.coordinator.update(
            scale: scale,
            offset: offset,
            viewportSize: viewportSize,
            contentSize: contentSize,
            maximumScale: maximumScale,
            onTransformChanged: onTransformChanged,
            onGestureEnded: onGestureEnded
        )
        uiView.coordinator = context.coordinator
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let pinchRecognizer = ReaderZoomPinchGestureRecognizer()
        let panRecognizer = ReaderZoomPanGestureRecognizer()

        private(set) var currentScale: CGFloat
        private(set) var currentOffset: CGSize
        private(set) var viewportSize: CGSize
        private(set) var contentSize: CGSize
        private(set) var maximumScale: CGFloat
        private weak var installedView: UIView?
        private var pinchBase: ReaderZoomTransform?
        private var panBase: ReaderZoomTransform?
        private var isPanEnding = false

        var onTransformChanged: (ReaderZoomTransform) -> Void
        var onGestureEnded: () -> Void

        init(
            scale: CGFloat,
            offset: CGSize,
            viewportSize: CGSize,
            contentSize: CGSize,
            maximumScale: CGFloat,
            onTransformChanged: @escaping (ReaderZoomTransform) -> Void,
            onGestureEnded: @escaping () -> Void
        ) {
            self.currentScale = scale
            self.currentOffset = offset
            self.viewportSize = viewportSize
            self.contentSize = contentSize
            self.maximumScale = maximumScale
            self.onTransformChanged = onTransformChanged
            self.onGestureEnded = onGestureEnded
            panRecognizer.isZoomActive = scale > ReaderZoomMath.settleThreshold
            super.init()

            pinchRecognizer.delegate = self
            pinchRecognizer.cancelsTouchesInView = true
            pinchRecognizer.addTarget(self, action: #selector(handlePinch(_:)))

            panRecognizer.minimumNumberOfTouches = 1
            panRecognizer.maximumNumberOfTouches = 1
            panRecognizer.delegate = self
            panRecognizer.cancelsTouchesInView = true
            panRecognizer.addTarget(self, action: #selector(handlePan(_:)))
        }

        func update(
            scale: CGFloat,
            offset: CGSize,
            viewportSize: CGSize,
            contentSize: CGSize,
            maximumScale: CGFloat,
            onTransformChanged: @escaping (ReaderZoomTransform) -> Void,
            onGestureEnded: @escaping () -> Void
        ) {
            currentScale = scale
            currentOffset = offset
            self.viewportSize = viewportSize
            self.contentSize = contentSize
            self.maximumScale = maximumScale
            self.onTransformChanged = onTransformChanged
            self.onGestureEnded = onGestureEnded
            panRecognizer.isZoomActive = scale > ReaderZoomMath.settleThreshold
        }

        func install(on view: UIView) {
            guard installedView !== view else { return }
            uninstall()
            view.addGestureRecognizer(pinchRecognizer)
            view.addGestureRecognizer(panRecognizer)
            installedView = view
        }

        func uninstall() {
            installedView?.removeGestureRecognizer(pinchRecognizer)
            installedView?.removeGestureRecognizer(panRecognizer)
            installedView = nil
        }

        deinit {
            MainActor.assumeIsolated {
                uninstall()
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === pinchRecognizer {
                return true
            }
            guard gestureRecognizer === panRecognizer,
                  currentScale > ReaderZoomMath.settleThreshold,
                  let pan = gestureRecognizer as? UIPanGestureRecognizer else {
                return false
            }
            let velocity = pan.velocity(in: pan.view)
            return hypot(velocity.x, velocity.y) > 4
        }

        @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let viewport = effectiveViewportSize(for: view)
            switch recognizer.state {
            case .began:
                pinchBase = ReaderZoomTransform(scale: currentScale, offset: currentOffset)
            case .changed:
                guard let pinchBase else { return }
                let focalPoint = recognizer.location(in: view)
                let transform = ReaderZoomMath.pinchTransform(
                    from: pinchBase,
                    magnification: recognizer.scale,
                    focalPoint: focalPoint,
                    viewportSize: viewport,
                    contentSize: contentSize,
                    maximumScale: maximumScale
                )
                currentScale = transform.scale
                currentOffset = transform.offset
                onTransformChanged(transform)
            case .ended:
                finishPinch()
            case .cancelled, .failed:
                finishPinch()
            default:
                break
            }
        }

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let viewport = effectiveViewportSize(for: view)
            switch recognizer.state {
            case .began:
                guard currentScale > ReaderZoomMath.settleThreshold else { return }
                panBase = ReaderZoomTransform(scale: currentScale, offset: currentOffset)
                isPanEnding = false
            case .changed:
                guard let panBase, pinchRecognizer.state != .began, pinchRecognizer.state != .changed else {
                    return
                }
                let translationPoint = recognizer.translation(in: view)
                let translation = CGSize(
                    width: translationPoint.x,
                    height: translationPoint.y
                )
                let transform = ReaderZoomMath.pannedTransform(
                    from: panBase,
                    translation: translation,
                    viewportSize: viewport,
                    contentSize: contentSize
                )
                currentOffset = transform.offset
                onTransformChanged(transform)
            case .ended:
                finishPan(notify: true)
            case .cancelled, .failed:
                finishPan(notify: true)
            default:
                break
            }
        }

        private func finishPinch() {
            guard pinchBase != nil else { return }
            onGestureEnded()
            pinchBase = nil
        }

        private func finishPan(notify: Bool) {
            guard !isPanEnding else { return }
            isPanEnding = true
            if notify, panBase != nil {
                onGestureEnded()
            }
            panBase = nil
        }

        private func effectiveViewportSize(for view: UIView) -> CGSize {
            if viewportSize.width > 0, viewportSize.height > 0 {
                return viewportSize
            }
            return view.bounds.size
        }

    }

    final class InstallView: UIView {
        weak var coordinator: Coordinator? {
            didSet {
                installRecognizerIfNeeded()
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            installRecognizerIfNeeded()
        }

        private func installRecognizerIfNeeded() {
            guard let coordinator, let superview else { return }
            coordinator.install(on: superview)
        }

    }
}
