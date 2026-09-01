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
}
