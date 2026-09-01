import CoreGraphics
import Testing
@testable import mreader

@Suite
struct ReaderDismissGestureTests {
    @Test func deadZoneKeepsReaderStill() {
        let progress = ReaderDismissMath.progress(for: 27, viewportHeight: 800)
        let visualState = ReaderDismissMath.visualState(for: progress)

        #expect(progress == 0)
        #expect(visualState == ReaderDismissVisualState(
            progress: 0,
            offsetY: 0,
            scale: 1,
            opacity: 1
        ))
    }

    @Test func progressUsesActivationAndHardCommitDistances() {
        let viewportHeight: CGFloat = 800
        let commitDistance = ReaderDismissGestureMetrics.commitDistance(
            viewportHeight: viewportHeight
        )

        #expect(commitDistance == 144)
        #expect(ReaderDismissMath.progress(for: 28, viewportHeight: viewportHeight) == 0)
        #expect(abs(ReaderDismissMath.progress(for: 86, viewportHeight: viewportHeight) - 0.5) < 0.001)
        #expect(ReaderDismissMath.progress(for: 144, viewportHeight: viewportHeight) == 1)
        #expect(ReaderDismissMath.progress(for: 300, viewportHeight: viewportHeight) == 1)
    }

    @Test func commitVisualStateUsesBoundedTransform() {
        let visualState = ReaderDismissMath.visualState(for: 1)

        #expect(visualState.offsetY == 190)
        #expect(visualState.scale == 0.88)
        #expect(visualState.opacity == 0.75)
    }

    @Test func directionLockSeparatesDismissFromPageTurn() {
        #expect(ReaderDismissMath.isDownwardDirection(CGSize(width: 40, height: 100)))
        #expect(!ReaderDismissMath.isDownwardDirection(CGSize(width: 70, height: 100)))
        #expect(!ReaderDismissMath.isDownwardDirection(CGSize(width: 40, height: -100)))
        #expect(ReaderDismissMath.isHorizontalPageTurn(CGSize(width: 100, height: 40)))
        #expect(!ReaderDismissMath.isHorizontalPageTurn(CGSize(width: 100, height: 80)))
    }

    @Test func reverseMovementCancelsAfterSixteenPoints() {
        #expect(!ReaderDismissMath.shouldCancelForReverse(
            peakTranslationY: 100,
            currentTranslationY: 85
        ))
        #expect(ReaderDismissMath.shouldCancelForReverse(
            peakTranslationY: 100,
            currentTranslationY: 84
        ))
    }

    @Test func commitRequiresDistanceAndNeverVelocity() {
        #expect(!ReaderDismissMath.shouldCommit(
            intent: .dismissing,
            translationY: 50,
            viewportHeight: 800,
            wasCancelled: false
        ))
        #expect(ReaderDismissMath.shouldCommit(
            intent: .dismissing,
            translationY: 144,
            viewportHeight: 800,
            wasCancelled: false
        ))
        #expect(!ReaderDismissMath.shouldCommit(
            intent: .dismissing,
            translationY: 200,
            viewportHeight: 800,
            wasCancelled: true
        ))
        #expect(!ReaderDismissMath.shouldCommit(
            intent: .pageTurning,
            translationY: 200,
            viewportHeight: 800,
            wasCancelled: false
        ))
    }

    @Test func firstFingerMovesBeforeSecondFingerStillAllowsPinch() {
        var dismiss = ReaderDismissTouchStateMachine()

        #expect(dismiss.receiveTouchBegan(activeTouchCount: 1) == .possible)
        #expect(dismiss.receiveMove(
            translation: CGSize(width: 0, height: 10),
            activeTouchCount: 1
        ) == .possible)
        #expect(dismiss.receiveTouchBegan(activeTouchCount: 2) == .failed)
        #expect(dismiss.state == .failed)
    }

    @Test func secondFingerBeforeDismissActivationCancelsDismissCandidate() {
        var dismiss = ReaderDismissTouchStateMachine()

        _ = dismiss.receiveTouchBegan(activeTouchCount: 1)
        _ = dismiss.receiveMove(
            translation: CGSize(width: 4, height: 20),
            activeTouchCount: 1
        )

        #expect(dismiss.state == .possible)
        #expect(dismiss.receiveTouchBegan(activeTouchCount: 2) == .failed)
    }

    @Test func singleFingerBeyondActivationLocksDismissAgainstLaterSecondFinger() {
        var dismiss = ReaderDismissTouchStateMachine()

        _ = dismiss.receiveTouchBegan(activeTouchCount: 1)
        #expect(dismiss.receiveMove(
            translation: CGSize(width: 0, height: 28),
            activeTouchCount: 1
        ) == .began)

        #expect(dismiss.receiveTouchBegan(activeTouchCount: 2) == .began)
        #expect(dismiss.receiveMove(
            translation: CGSize(width: 0, height: 40),
            activeTouchCount: 2
        ) == .began)
    }
}
