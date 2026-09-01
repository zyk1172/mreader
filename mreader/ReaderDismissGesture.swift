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

final class ReaderDismissPanGestureRecognizer: UIPanGestureRecognizer {}

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

        let recognizer = ReaderDismissPanGestureRecognizer()

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

            recognizer.minimumNumberOfTouches = 1
            recognizer.maximumNumberOfTouches = 1
            recognizer.cancelsTouchesInView = true
            recognizer.delegate = self
            recognizer.addTarget(self, action: #selector(handlePan(_:)))
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
                  canBeginDismiss(),
                  let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let view = gestureRecognizer.view,
                  let window = view as? UIWindow,
                  !hasActiveZoom(in: window) else {
                return false
            }

            let translationPoint = pan.translation(in: view)
            let translation = CGSize(width: translationPoint.x, height: translationPoint.y)
            let velocity = pan.velocity(in: view)
            let directionVector = max(abs(translation.width), abs(translation.height)) >= 8
                ? translation
                : CGSize(width: velocity.x, height: velocity.y)
            return ReaderDismissMath.isDownwardDirection(
                directionVector,
                minimumDistance: 8
            )
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            guard gestureRecognizer === recognizer,
                  isEnabled,
                  !ReaderGestureTouchFilter.isInteractiveTouch(touch),
                  let window = gestureRecognizer.view as? UIWindow,
                  !hasActiveZoom(in: window) else {
                return false
            }
            return true
        }

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let translationPoint = recognizer.translation(in: view)
            let translation = CGSize(width: translationPoint.x, height: translationPoint.y)
            let viewportHeight = max(view.bounds.height, 1)

            switch recognizer.state {
            case .began:
                intent = .undecided
                peakTranslationY = 0
                dismissWasCancelled = false
                gestureIsActive = true
            case .changed:
                guard gestureIsActive, !dismissWasCancelled else { return }

                if intent == .undecided {
                    let movement = max(abs(translation.width), abs(translation.height))
                    guard movement >= ReaderDismissGestureMetrics.directionLockDistance else {
                        return
                    }
                    guard ReaderDismissMath.isDownwardDirection(
                        translation,
                        minimumDistance: ReaderDismissGestureMetrics.directionLockDistance
                    ) else {
                        // The page's own horizontal/vertical gesture owns this
                        // sequence once it is not a downward-dismiss intent.
                        intent = ReaderDismissMath.isHorizontalPageTurn(translation)
                            ? .pageTurning
                            : .cancelled
                        abandonDismissGesture(with: intent)
                        return
                    }
                    intent = .dismissing
                }

                guard intent == .dismissing else { return }
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
                guard gestureIsActive else { return }
                abandonDismissGesture(with: .cancelled)
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

        private func hasActiveZoom(in window: UIWindow) -> Bool {
            hasActiveZoom(in: window as UIView)
        }

        private func hasActiveZoom(in view: UIView) -> Bool {
            if view.gestureRecognizers?.contains(where: { recognizer in
                (recognizer as? ReaderZoomPanGestureRecognizer)?.isZoomActive == true
            }) == true {
                return true
            }
            return view.subviews.contains(where: hasActiveZoom(in:))
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
