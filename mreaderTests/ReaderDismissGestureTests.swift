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

    @Test func directionMathSeparatesPageAxes() {
        #expect(ReaderDismissMath.isDownwardDirection(CGSize(width: 40, height: 100)))
        #expect(!ReaderDismissMath.isDownwardDirection(CGSize(width: 70, height: 100)))
        #expect(!ReaderDismissMath.isDownwardDirection(CGSize(width: 40, height: -100)))
        #expect(ReaderDismissMath.isHorizontalPageTurn(CGSize(width: 100, height: 40)))
        #expect(ReaderDismissMath.isVerticalPageTurn(CGSize(width: 40, height: 100)))
    }

    @Test func horizontalPageDownwardDragUsesThePageDragForDismissal() {
        var drag = ReaderPageDragStateMachine()

        #expect(drag.receiveMove(
            translation: CGSize(width: 0, height: 27),
            mode: .horizontalPage,
            isDismissEnabled: true
        ) == .undecided)
        #expect(drag.receiveMove(
            translation: CGSize(width: 0, height: 28),
            mode: .horizontalPage,
            isDismissEnabled: true
        ) == .dismissing)
        #expect(drag.intent == .dismissing)
        #expect(ReaderDismissMath.progress(for: 60, viewportHeight: 800) > 0)
    }

    @Test func horizontalPageDragUsesPageTurnIntentWithoutDismissal() {
        var drag = ReaderPageDragStateMachine()

        #expect(drag.receiveMove(
            translation: CGSize(width: -120, height: 8),
            mode: .horizontalPage,
            isDismissEnabled: true
        ) == .pageTurning)
        #expect(drag.intent != .dismissing)
    }

    @Test func verticalFirstPageDownwardDragDismisses() {
        var drag = ReaderPageDragStateMachine()

        #expect(drag.receiveMove(
            translation: CGSize(width: 4, height: 28),
            mode: .verticalPage(isFirstPage: true),
            isDismissEnabled: true
        ) == .dismissing)
    }

    @Test func verticalFirstPageUpwardDragTurnsPage() {
        var drag = ReaderPageDragStateMachine()

        #expect(drag.receiveMove(
            translation: CGSize(width: 4, height: -40),
            mode: .verticalPage(isFirstPage: true),
            isDismissEnabled: true
        ) == .pageTurning)
    }

    @Test func verticalNonFirstPageDownwardDragTurnsPageInsteadOfDismissing() {
        var drag = ReaderPageDragStateMachine()

        #expect(drag.receiveMove(
            translation: CGSize(width: 4, height: 40),
            mode: .verticalPage(isFirstPage: false),
            isDismissEnabled: true
        ) == .pageTurning)
    }

    @Test func ambiguousDirectionCanBecomeDismissalLater() {
        var drag = ReaderPageDragStateMachine()

        #expect(drag.receiveMove(
            translation: CGSize(width: 14, height: 12),
            mode: .horizontalPage,
            isDismissEnabled: true
        ) == .undecided)
        #expect(drag.receiveMove(
            translation: CGSize(width: 11, height: 150),
            mode: .horizontalPage,
            isDismissEnabled: true
        ) == .dismissing)
    }

    @Test func reverseMovementCancelsPageDismissalAndCannotReenter() {
        var drag = ReaderPageDragStateMachine()

        _ = drag.receiveMove(
            translation: CGSize(width: 0, height: 80),
            mode: .horizontalPage,
            isDismissEnabled: true
        )
        #expect(drag.receiveMove(
            translation: CGSize(width: 0, height: 63),
            mode: .horizontalPage,
            isDismissEnabled: true
        ) == .cancelled)
        #expect(drag.wasDismissCancelled)
        #expect(drag.receiveMove(
            translation: CGSize(width: 0, height: 180),
            mode: .horizontalPage,
            isDismissEnabled: true
        ) == .cancelled)
    }

    @Test func continuousOverscrollStartsOnlyAfterActivation() {
        var dismiss = ReaderContinuousDismissStateMachine()

        #expect(dismiss.receiveOverscroll(27, isDismissEnabled: true) == .possible)
        #expect(dismiss.receiveOverscroll(28, isDismissEnabled: true) == .dismissing)
        #expect(ReaderDismissMath.progress(for: 60, viewportHeight: 800) > 0)
    }

    @Test func continuousOverscrollCommitsOnlyAtCommitDistance() {
        var dismiss = ReaderContinuousDismissStateMachine()

        _ = dismiss.receiveOverscroll(144, isDismissEnabled: true)
        let belowCommit = dismiss.finish(overscroll: 143, viewportHeight: 800)
        #expect(!belowCommit)

        _ = dismiss.receiveOverscroll(144, isDismissEnabled: true)
        let atCommit = dismiss.finish(overscroll: 144, viewportHeight: 800)
        #expect(atCommit)
    }

    @Test func continuousReverseMovementCancelsAndCannotReenter() {
        var dismiss = ReaderContinuousDismissStateMachine()

        _ = dismiss.receiveOverscroll(80, isDismissEnabled: true)
        #expect(dismiss.receiveOverscroll(63, isDismissEnabled: true) == .cancelled)
        #expect(dismiss.receiveOverscroll(180, isDismissEnabled: true) == .cancelled)
        let didCommit = dismiss.finish(overscroll: 180, viewportHeight: 800)
        #expect(!didCommit)
    }
}
