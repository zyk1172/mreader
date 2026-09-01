import CoreGraphics

nonisolated enum ReaderPanIntent: Equatable {
    case undecided
    case zoomPanning
    case dismissing
    case pageTurning
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

    static func isVerticalPageTurn(
        _ translation: CGSize,
        minimumDistance: CGFloat = 0
    ) -> Bool {
        abs(translation.height) >= max(minimumDistance, 0)
            && abs(translation.height) > abs(translation.width) * 1.25
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
        intent: ReaderPanIntent,
        translationY: CGFloat,
        viewportHeight: CGFloat,
        wasCancelled: Bool
    ) -> Bool {
        intent == .dismissing
            && !wasCancelled
            && translationY >= ReaderDismissGestureMetrics.commitDistance(viewportHeight: viewportHeight)
    }
}

/// The modes that already own a page drag. Dismissal is selected by that same
/// drag, so no second recognizer needs to arbitrate with page navigation.
nonisolated enum ReaderPageDragMode: Equatable {
    case horizontalPage
    case verticalPage(isFirstPage: Bool)
    case dismissOnly
}

/// Classifies a page drag without making an early, irreversible decision while
/// the direction is still ambiguous. A downward dismiss is only selected once
/// the same drag reaches the explicit activation distance.
nonisolated struct ReaderPageDragStateMachine {
    private(set) var intent: ReaderPanIntent = .undecided
    private(set) var peakTranslationY: CGFloat = 0
    private(set) var wasDismissCancelled = false

    mutating func receiveMove(
        translation: CGSize,
        mode: ReaderPageDragMode,
        isDismissEnabled: Bool
    ) -> ReaderPanIntent {
        switch intent {
        case .undecided:
            let movement = max(abs(translation.width), abs(translation.height))
            guard movement >= ReaderDismissGestureMetrics.directionLockDistance else {
                return intent
            }

            let canDismiss = isDismissEnabled
                && translation.height >= ReaderDismissGestureMetrics.activationDistance
                && ReaderDismissMath.isDownwardDirection(
                    translation,
                    minimumDistance: ReaderDismissGestureMetrics.directionLockDistance
                )

            switch mode {
            case .horizontalPage:
                if ReaderDismissMath.isHorizontalPageTurn(
                    translation,
                    minimumDistance: ReaderDismissGestureMetrics.directionLockDistance
                ) {
                    intent = .pageTurning
                } else if canDismiss {
                    beginDismiss(at: translation.height)
                }
            case .verticalPage(let isFirstPage):
                if isFirstPage, canDismiss {
                    beginDismiss(at: translation.height)
                } else if ReaderDismissMath.isVerticalPageTurn(
                    translation,
                    minimumDistance: ReaderDismissGestureMetrics.directionLockDistance
                ) {
                    intent = .pageTurning
                }
            case .dismissOnly:
                if canDismiss {
                    beginDismiss(at: translation.height)
                }
            }
            return intent

        case .dismissing:
            if ReaderDismissMath.shouldCancelForReverse(
                peakTranslationY: peakTranslationY,
                currentTranslationY: translation.height
            ) {
                intent = .cancelled
                wasDismissCancelled = true
            } else {
                peakTranslationY = max(peakTranslationY, translation.height)
            }
            return intent

        case .zoomPanning:
            return intent

        case .pageTurning, .cancelled:
            return intent
        }
    }

    mutating func reset() {
        intent = .undecided
        peakTranslationY = 0
        wasDismissCancelled = false
    }

    private mutating func beginDismiss(at translationY: CGFloat) {
        intent = .dismissing
        peakTranslationY = translationY
        wasDismissCancelled = false
    }
}

nonisolated enum ReaderContinuousDismissState: Equatable {
    case possible
    case dismissing
    case cancelled
}

/// Continuous reading delegates ownership to UIScrollView's existing pan.
/// The state machine only interprets the negative top overscroll reported by
/// that pan and never installs a competing recognizer.
nonisolated struct ReaderContinuousDismissStateMachine {
    private(set) var state: ReaderContinuousDismissState = .possible
    private(set) var peakOverscroll: CGFloat = 0

    mutating func beginPan() {
        state = .possible
        peakOverscroll = 0
    }

    mutating func receiveOverscroll(
        _ overscroll: CGFloat,
        isDismissEnabled: Bool
    ) -> ReaderContinuousDismissState {
        let currentOverscroll = max(overscroll, 0)
        switch state {
        case .possible:
            guard isDismissEnabled,
                  currentOverscroll >= ReaderDismissGestureMetrics.activationDistance else {
                return state
            }
            peakOverscroll = currentOverscroll
            state = .dismissing
        case .dismissing:
            if ReaderDismissMath.shouldCancelForReverse(
                peakTranslationY: peakOverscroll,
                currentTranslationY: currentOverscroll
            ) {
                state = .cancelled
            } else {
                peakOverscroll = max(peakOverscroll, currentOverscroll)
            }
        case .cancelled:
            break
        }
        return state
    }

    mutating func finish(
        overscroll: CGFloat,
        viewportHeight: CGFloat
    ) -> Bool {
        let shouldCommit = state == .dismissing
            && max(overscroll, 0) >= ReaderDismissGestureMetrics.commitDistance(viewportHeight: viewportHeight)
        reset()
        return shouldCommit
    }

    mutating func reset() {
        state = .possible
        peakOverscroll = 0
    }
}
