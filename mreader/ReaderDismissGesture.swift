import SwiftUI
import UIKit

nonisolated enum ReaderDragIntent: Equatable {
    case undecided
    case dismissing
    case pageTurning
    case panning
    case cancelled
}

nonisolated enum ReaderDismissGestureMetrics {
    static let directionLockDistance: CGFloat = 14
    static let activationDistance: CGFloat = 28
    static let reverseCancelDistance: CGFloat = 16
    static let minimumCommitDistance: CGFloat = 140
    static let commitHeightFraction: CGFloat = 0.18
    static let maximumOffset: CGFloat = 190
    static let minimumScale: CGFloat = 0.88
    static let minimumOpacity: CGFloat = 0.75
    static let verticalDominanceRatio: CGFloat = 0.60

    static func commitDistance(viewportHeight: CGFloat) -> CGFloat {
        max(minimumCommitDistance, max(viewportHeight, 0) * commitHeightFraction)
    }
}

nonisolated struct ReaderDismissVisualState: Equatable {
    let progress: CGFloat
    let offsetY: CGFloat
    let scale: CGFloat
    let opacity: CGFloat
}

nonisolated enum ReaderDismissMath {
    static func isDownwardDirection(
        _ translation: CGSize,
        minimumDistance: CGFloat = 0
    ) -> Bool {
        translation.height >= max(minimumDistance, 0)
            && translation.height > 0
            && abs(translation.width) <= translation.height * ReaderDismissGestureMetrics.verticalDominanceRatio
    }

    static func isHorizontalPageTurn(
        _ translation: CGSize,
        minimumDistance: CGFloat = 0
    ) -> Bool {
        abs(translation.width) >= max(minimumDistance, 0)
            && abs(translation.width) > abs(translation.height) * 1.25
    }

    static func progress(
        for translationY: CGFloat,
        viewportHeight: CGFloat
    ) -> CGFloat {
        let activation = ReaderDismissGestureMetrics.activationDistance
        let commit = max(
            activation + 1,
            ReaderDismissGestureMetrics.commitDistance(viewportHeight: viewportHeight)
        )
        guard translationY > activation else { return 0 }
        return min(max((translationY - activation) / (commit - activation), 0), 1)
    }

    static func visualState(
        for progress: CGFloat
    ) -> ReaderDismissVisualState {
        let clampedProgress = min(max(progress, 0), 1)
        return ReaderDismissVisualState(
            progress: clampedProgress,
            offsetY: clampedProgress * ReaderDismissGestureMetrics.maximumOffset,
            scale: 1 - clampedProgress * (1 - ReaderDismissGestureMetrics.minimumScale),
            opacity: 1 - clampedProgress * (1 - ReaderDismissGestureMetrics.minimumOpacity)
        )
    }

    static func shouldCancelForReverse(
        peakTranslationY: CGFloat,
        currentTranslationY: CGFloat
    ) -> Bool {
        peakTranslationY - currentTranslationY >= ReaderDismissGestureMetrics.reverseCancelDistance
    }

    static func shouldCommit(
        intent: ReaderDragIntent,
        translationY: CGFloat,
        viewportHeight: CGFloat,
        wasCancelled: Bool
    ) -> Bool {
        intent == .dismissing
            && !wasCancelled
            && translationY >= ReaderDismissGestureMetrics.commitDistance(viewportHeight: viewportHeight)
    }
}

nonisolated enum ReaderDismissTouchState: Equatable {
    case possible
    case began
    case changed
    case failed
    case cancelled
    case ended
}

/// The touch-level arbitration contract is kept independent from UIKit so it
/// can be regression-tested with the same transitions used by the recognizer.
nonisolated struct ReaderDismissTouchStateMachine {
    private(set) var state: ReaderDismissTouchState = .possible
    private var peakTranslationY: CGFloat = 0

    mutating func receiveTouchBegan(activeTouchCount: Int) -> ReaderDismissTouchState {
        guard state == .possible else { return state }
        guard activeTouchCount == 1 else {
            state = .failed
            return state
        }
        return state
    }

    mutating func receiveMove(
        translation: CGSize,
        activeTouchCount: Int
    ) -> ReaderDismissTouchState {
        switch state {
        case .possible:
            guard activeTouchCount == 1 else {
                state = .failed
                return state
            }

            let movement = max(abs(translation.width), abs(translation.height))
            guard movement >= ReaderDismissGestureMetrics.directionLockDistance else {
                return state
            }
            guard ReaderDismissMath.isDownwardDirection(
                translation,
                minimumDistance: ReaderDismissGestureMetrics.directionLockDistance
            ) else {
                state = .failed
                return state
            }
            guard translation.height >= ReaderDismissGestureMetrics.activationDistance else {
                return state
            }
            peakTranslationY = translation.height
            state = .began
            return state
        case .began, .changed:
            // Once dismissal has activated, a later finger cannot turn the
            // already-owned sequence into a pinch.
            guard activeTouchCount == 1 else { return state }
            if ReaderDismissMath.shouldCancelForReverse(
                peakTranslationY: peakTranslationY,
                currentTranslationY: translation.height
            ) {
                state = .cancelled
                return state
            }
            peakTranslationY = max(peakTranslationY, translation.height)
            state = .changed
            return state
        default:
            return state
        }
    }

    mutating func receiveTouchEnded() -> ReaderDismissTouchState {
        switch state {
        case .possible:
            state = .failed
        case .began, .changed:
            state = .ended
        default:
            break
        }
        return state
    }

    mutating func receiveTouchCancelled() -> ReaderDismissTouchState {
        switch state {
        case .possible:
            state = .failed
        case .began, .changed:
            state = .cancelled
        default:
            break
        }
        return state
    }

    mutating func reset() {
        state = .possible
        peakTranslationY = 0
    }
}

/// A one-finger recognizer that does not begin until dismissal is actually
/// eligible. Keeping the recognizer in `.possible` below the activation
/// distance is important: UIKit only cancels the underlying page touches once
/// this recognizer reaches `.began`.
final class ReaderDismissGestureRecognizer: UIGestureRecognizer {
    private var trackedTouch: UITouch?
    private var startLocation: CGPoint = .zero
    private var touchStateMachine = ReaderDismissTouchStateMachine()

    func translation(in view: UIView?) -> CGPoint {
        guard let gestureView = self.view,
              let trackedTouch else {
            return .zero
        }
        let destinationView = view ?? gestureView
        let currentLocation = trackedTouch.location(in: destinationView)
        let initialLocation = gestureView.convert(startLocation, to: destinationView)
        return CGPoint(
            x: currentLocation.x - initialLocation.x,
            y: currentLocation.y - initialLocation.y
        )
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard state == .possible else { return }
        guard trackedTouch == nil else {
            // UIKit normally supplies an event containing both touches. Keep
            // the identity check as a defensive fallback so a second touch
            // cannot replace the first when the event is incomplete.
            state = .failed
            return
        }
        let activeTouchCount = activeTouchCount(from: event, fallback: touches.count)
        let touchState = touchStateMachine.receiveTouchBegan(
            activeTouchCount: activeTouchCount
        )
        guard touchState == .possible,
              touches.count == 1,
              activeTouchCount == 1,
              let touch = touches.first,
              let view else {
            state = .failed
            return
        }
        trackedTouch = touch
        startLocation = touch.location(in: view)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let view, let trackedTouch else { return }

        let activeTouchCount = activeTouchCount(from: event, fallback: touches.count)
        guard touches.contains(trackedTouch) || state == .began || state == .changed else {
            return
        }

        let location = trackedTouch.location(in: view)
        let translation = CGSize(
            width: location.x - startLocation.x,
            height: location.y - startLocation.y
        )

        apply(touchStateMachine.receiveMove(
            translation: translation,
            activeTouchCount: activeTouchCount
        ))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let trackedTouch, touches.contains(trackedTouch) else { return }
        apply(touchStateMachine.receiveTouchEnded())
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let trackedTouch, touches.contains(trackedTouch) else { return }
        apply(touchStateMachine.receiveTouchCancelled())
    }

    override func reset() {
        trackedTouch = nil
        startLocation = .zero
        touchStateMachine.reset()
        super.reset()
    }

    private func apply(_ touchState: ReaderDismissTouchState) {
        switch touchState {
        case .possible:
            break
        case .began:
            state = .began
        case .changed:
            state = .changed
        case .failed:
            state = .failed
        case .cancelled:
            state = .cancelled
        case .ended:
            state = .ended
        }
    }

    private func activeTouchCount(from event: UIEvent?, fallback: Int) -> Int {
        event?.allTouches?.filter { touch in
            touch.phase != .ended && touch.phase != .cancelled
        }.count ?? fallback
    }
}

/// Installs the one-finger reader-dismiss recognizer on the window while the
/// SwiftUI view itself remains hit-test transparent. Pinch and image panning
/// stay owned by the page-local zoom coordinator.
struct ReaderDismissGestureView: UIViewRepresentable {
    let isEnabled: Bool
    let canBeginDismiss: () -> Bool
    let onProgress: (CGFloat) -> Void
    let onCancel: () -> Void
    let onCommit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isEnabled: isEnabled,
            canBeginDismiss: canBeginDismiss,
            onProgress: onProgress,
            onCancel: onCancel,
            onCommit: onCommit
        )
    }

    func makeUIView(context: Context) -> InstallView {
        let view = InstallView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: InstallView, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.recognizer.isEnabled = isEnabled
        context.coordinator.canBeginDismiss = canBeginDismiss
        context.coordinator.onProgress = onProgress
        context.coordinator.onCancel = onCancel
        context.coordinator.onCommit = onCommit
        uiView.coordinator = context.coordinator
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var isEnabled: Bool
        var canBeginDismiss: () -> Bool
        var onProgress: (CGFloat) -> Void
        var onCancel: () -> Void
        var onCommit: () -> Void

        let recognizer = ReaderDismissGestureRecognizer()

        private weak var hostWindow: UIWindow?
        private var intent: ReaderDragIntent = .undecided
        private var peakTranslationY: CGFloat = 0
        private var dismissWasCancelled = false
        private var gestureIsActive = false

        init(
            isEnabled: Bool,
            canBeginDismiss: @escaping () -> Bool,
            onProgress: @escaping (CGFloat) -> Void,
            onCancel: @escaping () -> Void,
            onCommit: @escaping () -> Void
        ) {
            self.isEnabled = isEnabled
            self.canBeginDismiss = canBeginDismiss
            self.onProgress = onProgress
            self.onCancel = onCancel
            self.onCommit = onCommit
            super.init()

            recognizer.cancelsTouchesInView = true
            recognizer.isEnabled = isEnabled
            recognizer.delegate = self
            recognizer.addTarget(self, action: #selector(handleDismiss(_:)))
        }

        func attach(to window: UIWindow?) {
            if hostWindow === window { return }
            detach()
            guard let window else { return }
            window.addGestureRecognizer(recognizer)
            hostWindow = window
        }

        func detach() {
            hostWindow?.removeGestureRecognizer(recognizer)
            hostWindow = nil
        }

        deinit {
            MainActor.assumeIsolated {
                detach()
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === recognizer,
                  isEnabled,
                  canBeginDismiss() else {
                return false
            }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            guard gestureRecognizer === recognizer,
                  isEnabled,
                  !ReaderGestureTouchFilter.isInteractiveTouch(touch) else {
                return false
            }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            guard gestureRecognizer === recognizer,
                  let scrollView = otherGestureRecognizer.view as? UIScrollView else {
                return false
            }
            // In continuous reading, UIScrollView's pan begins before the
            // window-level dismiss recognizer reaches its 28pt activation
            // distance. Let both recognizers observe the same touch sequence;
            // the dismiss state machine still only takes ownership at the
            // explicit downward activation threshold.
            return otherGestureRecognizer === scrollView.panGestureRecognizer
        }

        @objc private func handleDismiss(_ recognizer: UIGestureRecognizer) {
            guard let view = recognizer.view else { return }
            guard let dismissRecognizer = recognizer as? ReaderDismissGestureRecognizer else { return }
            let translationPoint = dismissRecognizer.translation(in: view)
            let translation = CGSize(width: translationPoint.x, height: translationPoint.y)
            let viewportHeight = max(view.bounds.height, 1)

            switch recognizer.state {
            case .began:
                intent = .dismissing
                peakTranslationY = translation.height
                dismissWasCancelled = false
                gestureIsActive = true
                onProgress(
                    ReaderDismissMath.progress(
                        for: translation.height,
                        viewportHeight: viewportHeight
                    )
                )
            case .changed:
                guard gestureIsActive, !dismissWasCancelled, intent == .dismissing else { return }
                if ReaderDismissMath.shouldCancelForReverse(
                    peakTranslationY: peakTranslationY,
                    currentTranslationY: translation.height
                ) {
                    abandonDismissGesture(with: .cancelled)
                    return
                }

                peakTranslationY = max(peakTranslationY, translation.height)
                let progress = ReaderDismissMath.progress(
                    for: translation.height,
                    viewportHeight: viewportHeight
                )
                onProgress(progress)
            case .ended:
                guard gestureIsActive else { return }
                if ReaderDismissMath.shouldCommit(
                    intent: intent,
                    translationY: translation.height,
                    viewportHeight: viewportHeight,
                    wasCancelled: dismissWasCancelled
                ) {
                    onCommit()
                } else if intent == .dismissing {
                    onCancel()
                }
                resetGesture()
            case .cancelled, .failed:
                if gestureIsActive {
                    abandonDismissGesture(with: .cancelled)
                }
                resetGesture()
            default:
                break
            }
        }

        private func resetGesture() {
            gestureIsActive = false
            intent = .undecided
            peakTranslationY = 0
            dismissWasCancelled = false
        }

        private func abandonDismissGesture(with intent: ReaderDragIntent) {
            self.intent = intent
            dismissWasCancelled = true
            onCancel()
        }

    }

    final class InstallView: UIView {
        weak var coordinator: Coordinator? {
            didSet {
                coordinator?.attach(to: window)
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.attach(to: window)
        }

        deinit {
            MainActor.assumeIsolated {
                coordinator?.detach()
            }
        }
    }
}
