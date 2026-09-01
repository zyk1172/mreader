import SwiftUI
import UIKit

nonisolated struct ReaderPinchTouchGate {
    private(set) var hasFailedForSingleTouch = false
    private var primaryTouchStart: CGPoint?

    mutating func receiveTouchBegan(
        activeTouchCount: Int,
        primaryLocation: CGPoint?
    ) {
        guard !hasFailedForSingleTouch else { return }
        if activeTouchCount >= 2 {
            primaryTouchStart = nil
        } else if activeTouchCount == 1 {
            primaryTouchStart = primaryLocation
        }
    }

    mutating func receiveMove(
        activeTouchCount: Int,
        primaryLocation: CGPoint
    ) -> Bool {
        guard !hasFailedForSingleTouch,
              activeTouchCount == 1,
              let primaryTouchStart else {
            return false
        }
        let movement = hypot(
            primaryLocation.x - primaryTouchStart.x,
            primaryLocation.y - primaryTouchStart.y
        )
        guard movement >= ReaderDismissGestureMetrics.activationDistance else {
            return false
        }
        hasFailedForSingleTouch = true
        self.primaryTouchStart = nil
        return true
    }

    mutating func reset() {
        hasFailedForSingleTouch = false
        primaryTouchStart = nil
    }
}

/// Keeps a one-finger touch available for the page pan until the pinch has had
/// a chance to receive a second finger. Once that distance is reached, the
/// touch is already a committed one-finger gesture and pinch must fail for
/// this sequence.
final class ReaderZoomPinchGestureRecognizer: UIPinchGestureRecognizer {
    private var touchGate = ReaderPinchTouchGate()

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .possible {
            let activeTouchCount = activeTouchCount(from: event, fallback: touches.count)
            let primaryLocation = activeTouchCount == 1
                ? touches.first.flatMap { touch in
                    view.map { touch.location(in: $0) }
                }
                : nil
            touchGate.receiveTouchBegan(
                activeTouchCount: activeTouchCount,
                primaryLocation: primaryLocation
            )
        }
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .possible,
           let touch = touches.first,
           let view {
            let currentLocation = touch.location(in: view)
            if touchGate.receiveMove(
                activeTouchCount: activeTouchCount(from: event, fallback: touches.count),
                primaryLocation: currentLocation
            ) {
                state = .failed
                return
            }
        }
        super.touchesMoved(touches, with: event)
    }

    override func reset() {
        touchGate.reset()
        super.reset()
    }

    private func activeTouchCount(from event: UIEvent?, fallback: Int) -> Int {
        event?.allTouches?.filter { touch in
            touch.phase != .ended && touch.phase != .cancelled
        }.count ?? fallback
    }
}

/// The one-finger recognizer that owns both zoom panning and page-level
/// navigation. Keeping it on the same UIKit host as pinch avoids a
/// SwiftUI/UIKit recognizer race at the activation distance.
nonisolated struct ReaderPagePanTouchGate {
    private(set) var hasRejectedMultipleTouch = false

    mutating func receiveTouch(activeTouchCount: Int) -> Bool {
        guard !hasRejectedMultipleTouch else { return true }
        guard activeTouchCount <= 1 else {
            hasRejectedMultipleTouch = true
            return true
        }
        return false
    }

    mutating func reset() {
        hasRejectedMultipleTouch = false
    }
}

final class ReaderPagePanGestureRecognizer: UIPanGestureRecognizer {
    private var touchGate = ReaderPagePanTouchGate()

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard !touchGate.receiveTouch(
            activeTouchCount: activeTouchCount(from: event, fallback: touches.count)
        ) else {
            state = state == .possible ? .failed : .cancelled
            return
        }
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard !touchGate.receiveTouch(
            activeTouchCount: activeTouchCount(from: event, fallback: touches.count)
        ) else {
            state = state == .possible ? .failed : .cancelled
            return
        }
        super.touchesMoved(touches, with: event)
    }

    override func reset() {
        touchGate.reset()
        super.reset()
    }

    private func activeTouchCount(from event: UIEvent, fallback: Int) -> Int {
        event.allTouches?.filter { touch in
            touch.phase != .ended && touch.phase != .cancelled
        }.count ?? fallback
    }
}

nonisolated enum ReaderPageTurnDirection: Equatable {
    case previous
    case next
}

/// Configuration for the page host's single-finger pan. The callbacks are
/// deliberately result-oriented: SwiftUI renders the current page offset or
/// dismissal transform, while UIKit owns touch recognition and arbitration.
struct ReaderPagePanConfiguration {
    let mode: ReaderPageDragMode
    let isDismissEnabled: Bool
    let pageExtent: CGFloat
    let viewportHeight: CGFloat
    let isRTL: Bool
    let onPageDragChanged: (CGFloat) -> Void
    let onPageTurn: (ReaderPageTurnDirection) -> Void
    let onDismissProgress: (CGFloat) -> Void
    let onDismissCancel: () -> Void
    let onDismissCommit: () -> Void

    func pageTranslation(for translation: CGSize) -> CGFloat {
        switch mode {
        case .verticalPage:
            return translation.height
        case .horizontalPage, .dismissOnly:
            return translation.width
        }
    }

    func logicalPageDelta(for translation: CGSize) -> CGFloat {
        let rawDelta = pageTranslation(for: translation)
        switch mode {
        case .verticalPage, .dismissOnly:
            return rawDelta
        case .horizontalPage:
            return isRTL ? rawDelta : -rawDelta
        }
    }

    var pageTurnThreshold: CGFloat {
        max(pageExtent * 0.2, 72)
    }
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
    var pagePanConfiguration: ReaderPagePanConfiguration? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(
            scale: scale,
            offset: offset,
            viewportSize: viewportSize,
            contentSize: contentSize,
            maximumScale: maximumScale,
            onTransformChanged: onTransformChanged,
            onGestureEnded: onGestureEnded,
            pagePanConfiguration: pagePanConfiguration
        )
    }

    func makeUIView(context: Context) -> ReaderPageInteractionHostView {
        let view = ReaderPageInteractionHostView(frame: .zero)
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: ReaderPageInteractionHostView, context: Context) {
        context.coordinator.update(
            scale: scale,
            offset: offset,
            viewportSize: viewportSize,
            contentSize: contentSize,
            maximumScale: maximumScale,
            onTransformChanged: onTransformChanged,
            onGestureEnded: onGestureEnded,
            pagePanConfiguration: pagePanConfiguration
        )
        uiView.coordinator = context.coordinator
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let pinchRecognizer = ReaderZoomPinchGestureRecognizer()
        let panRecognizer = ReaderPagePanGestureRecognizer()

        private(set) var currentScale: CGFloat
        private(set) var currentOffset: CGSize
        private(set) var viewportSize: CGSize
        private(set) var contentSize: CGSize
        private(set) var maximumScale: CGFloat
        private weak var installedView: ReaderPageInteractionHostView?
        private var pinchBase: ReaderZoomTransform?
        private var panBase: ReaderZoomTransform?
        private var isPanEnding = false
        private var pagePanConfiguration: ReaderPagePanConfiguration?
        private var pageDragState = ReaderPageDragStateMachine()
        private(set) var panIntent: ReaderPanIntent = .undecided

        var onTransformChanged: (ReaderZoomTransform) -> Void
        var onGestureEnded: () -> Void

        init(
            scale: CGFloat,
            offset: CGSize,
            viewportSize: CGSize,
            contentSize: CGSize,
            maximumScale: CGFloat,
            onTransformChanged: @escaping (ReaderZoomTransform) -> Void,
            onGestureEnded: @escaping () -> Void,
            pagePanConfiguration: ReaderPagePanConfiguration? = nil
        ) {
            self.currentScale = scale
            self.currentOffset = offset
            self.viewportSize = viewportSize
            self.contentSize = contentSize
            self.maximumScale = maximumScale
            self.onTransformChanged = onTransformChanged
            self.onGestureEnded = onGestureEnded
            self.pagePanConfiguration = pagePanConfiguration
            super.init()

            pinchRecognizer.delegate = self
            pinchRecognizer.cancelsTouchesInView = true
            pinchRecognizer.addTarget(self, action: #selector(handlePinch(_:)))

            panRecognizer.minimumNumberOfTouches = 1
            panRecognizer.maximumNumberOfTouches = 1
            panRecognizer.delegate = self
            panRecognizer.cancelsTouchesInView = true
            panRecognizer.isEnabled = pagePanConfiguration != nil
                || currentScale > ReaderZoomMath.settleThreshold
            panRecognizer.addTarget(self, action: #selector(handlePan(_:)))
        }

        func update(
            scale: CGFloat,
            offset: CGSize,
            viewportSize: CGSize,
            contentSize: CGSize,
            maximumScale: CGFloat,
            onTransformChanged: @escaping (ReaderZoomTransform) -> Void,
            onGestureEnded: @escaping () -> Void,
            pagePanConfiguration: ReaderPagePanConfiguration? = nil
        ) {
            currentScale = scale
            currentOffset = offset
            self.viewportSize = viewportSize
            self.contentSize = contentSize
            self.maximumScale = maximumScale
            self.onTransformChanged = onTransformChanged
            self.onGestureEnded = onGestureEnded
            self.pagePanConfiguration = pagePanConfiguration
            panRecognizer.isEnabled = pagePanConfiguration != nil
                || currentScale > ReaderZoomMath.settleThreshold
        }

        func install(on view: ReaderPageInteractionHostView) {
            guard installedView !== view else {
                return
            }
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
                  let pan = gestureRecognizer as? UIPanGestureRecognizer else {
                return false
            }
            guard pagePanConfiguration != nil
                || currentScale > ReaderZoomMath.settleThreshold else {
                return false
            }
            let velocity = pan.velocity(in: pan.view)
            return hypot(velocity.x, velocity.y) > 4
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            (gestureRecognizer === pinchRecognizer && otherGestureRecognizer === panRecognizer)
                || (gestureRecognizer === panRecognizer && otherGestureRecognizer === pinchRecognizer)
        }

        @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let viewport = effectiveViewportSize(for: view)
            switch recognizer.state {
            case .began:
                cancelPagePanForPinch()
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
                updatePanAvailability()
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
            let translationPoint = recognizer.translation(in: view.window ?? view)
            processPan(
                state: recognizer.state,
                translation: CGSize(width: translationPoint.x, height: translationPoint.y),
                viewport: effectiveViewportSize(for: view)
            )
        }

        /// Drives the same routing path as the UIKit recognizer action. It is
        /// internal so host-level tests can exercise callback ownership without
        /// fabricating private UIKit touch events.
        func receivePanEventForTesting(
            state: UIGestureRecognizer.State,
            translation: CGSize
        ) {
            processPan(state: state, translation: translation, viewport: viewportSize)
        }

        private func processPan(
            state: UIGestureRecognizer.State,
            translation: CGSize,
            viewport: CGSize
        ) {
            switch state {
            case .began:
                beginPan()
            case .changed:
                updatePan(translation: translation, viewport: viewport)
            case .ended:
                if panIntent != .zoomPanning {
                    updatePan(translation: translation, viewport: viewport)
                }
                finishPan(translation: translation, viewport: viewport)
            case .cancelled, .failed:
                cancelPan()
            default:
                break
            }
        }

        private func beginPan() {
            isPanEnding = false
            panBase = nil
            pageDragState.reset()

            guard pinchRecognizer.state != .began,
                  pinchRecognizer.state != .changed else {
                panIntent = .cancelled
                isPanEnding = true
                return
            }

            if currentScale > ReaderZoomMath.settleThreshold {
                panIntent = .zoomPanning
                panBase = ReaderZoomTransform(scale: currentScale, offset: currentOffset)
            } else if pagePanConfiguration != nil {
                panIntent = .undecided
            } else {
                panIntent = .cancelled
                isPanEnding = true
            }
        }

        private func updatePan(translation: CGSize, viewport: CGSize) {
            guard !isPanEnding else { return }

            if pinchRecognizer.state == .began || pinchRecognizer.state == .changed {
                cancelPagePanForPinch()
                return
            }

            switch panIntent {
            case .zoomPanning:
                guard let panBase else { return }
                let transform = ReaderZoomMath.pannedTransform(
                    from: panBase,
                    translation: translation,
                    viewportSize: viewport,
                    contentSize: contentSize
                )
                currentOffset = transform.offset
                onTransformChanged(transform)
            case .undecided, .pageTurning, .dismissing:
                updatePagePan(translation: translation, viewport: viewport)
            case .cancelled:
                break
            }
        }

        private func updatePagePan(translation: CGSize, viewport: CGSize) {
            guard let configuration = pagePanConfiguration else { return }
            let previousIntent = pageDragState.intent
            let intent = pageDragState.receiveMove(
                translation: translation,
                mode: configuration.mode,
                isDismissEnabled: configuration.isDismissEnabled
            )

            switch intent {
            case .zoomPanning:
                break
            case .undecided:
                panIntent = .undecided
            case .pageTurning:
                panIntent = .pageTurning
                configuration.onPageDragChanged(
                    configuration.pageTranslation(for: translation)
                )
            case .dismissing:
                panIntent = .dismissing
                configuration.onDismissProgress(
                    ReaderDismissMath.progress(
                        for: translation.height,
                        viewportHeight: max(viewport.height, configuration.viewportHeight)
                    )
                )
            case .cancelled:
                panIntent = .cancelled
                if previousIntent == .dismissing {
                    configuration.onDismissCancel()
                }
                configuration.onPageDragChanged(0)
            }
        }

        private func finishPinch() {
            guard pinchBase != nil else { return }
            onGestureEnded()
            pinchBase = nil
        }

        private func finishPan(translation: CGSize, viewport: CGSize) {
            guard !isPanEnding else { return }
            isPanEnding = true

            let finalIntent = panIntent
            let wasDismissCancelled = pageDragState.wasDismissCancelled
            let configuration = pagePanConfiguration
            panBase = nil
            pageDragState.reset()
            panIntent = .undecided

            switch finalIntent {
            case .zoomPanning:
                onGestureEnded()
            case .pageTurning:
                guard let configuration else { return }
                configuration.onPageDragChanged(0)
                let logicalDelta = configuration.logicalPageDelta(for: translation)
                if logicalDelta > configuration.pageTurnThreshold {
                    configuration.onPageTurn(.next)
                } else if logicalDelta < -configuration.pageTurnThreshold {
                    configuration.onPageTurn(.previous)
                }
            case .dismissing:
                guard let configuration else { return }
                if ReaderDismissMath.shouldCommit(
                    intent: .dismissing,
                    translationY: translation.height,
                    viewportHeight: max(viewport.height, configuration.viewportHeight),
                    wasCancelled: wasDismissCancelled
                ) {
                    configuration.onDismissCommit()
                } else {
                    configuration.onDismissCancel()
                }
            case .undecided, .cancelled:
                break
            }
        }

        private func cancelPan() {
            guard !isPanEnding else { return }
            isPanEnding = true

            let finalIntent = panIntent
            let configuration = pagePanConfiguration
            panBase = nil
            pageDragState.reset()
            panIntent = .undecided

            switch finalIntent {
            case .zoomPanning:
                onGestureEnded()
            case .pageTurning:
                configuration?.onPageDragChanged(0)
            case .dismissing:
                configuration?.onDismissCancel()
            case .undecided, .cancelled:
                break
            }
        }

        private func cancelPagePanForPinch() {
            guard !isPanEnding else { return }

            let configuration = pagePanConfiguration
            switch panIntent {
            case .pageTurning:
                configuration?.onPageDragChanged(0)
            case .dismissing:
                configuration?.onDismissCancel()
            case .zoomPanning, .undecided, .cancelled:
                break
            }
            panBase = nil
            pageDragState.reset()
            panIntent = .cancelled
            isPanEnding = true
        }

        private func effectiveViewportSize(for view: UIView) -> CGSize {
            if viewportSize.width > 0, viewportSize.height > 0 {
                return viewportSize
            }
            return view.bounds.size
        }

        private func updatePanAvailability() {
            panRecognizer.isEnabled = pagePanConfiguration != nil
                || currentScale > ReaderZoomMath.settleThreshold
        }

    }

    final class ReaderPageInteractionHostView: UIView {
        override init(frame: CGRect) {
            super.init(frame: frame)
            configureInteractionHost()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            configureInteractionHost()
        }

        weak var coordinator: Coordinator? {
            didSet {
                coordinator?.install(on: self)
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.install(on: self)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            coordinator?.install(on: self)
        }

        private func configureInteractionHost() {
            backgroundColor = .clear
            isOpaque = false
            isMultipleTouchEnabled = true
            isUserInteractionEnabled = true
        }

    }
}
