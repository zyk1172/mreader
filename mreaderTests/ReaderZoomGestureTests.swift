import CoreGraphics
import Testing
import UIKit
@testable import mreader

@Suite
struct ReaderZoomGestureTests {
    @Test func pinchKeepsTheFocalPointStationary() {
        let viewport = CGSize(width: 400, height: 800)
        let base = ReaderZoomTransform(scale: 1, offset: .zero)
        let focalPoint = CGPoint(x: 100, y: 200)

        let result = ReaderZoomMath.pinchTransform(
            from: base,
            magnification: 2,
            focalPoint: focalPoint,
            viewportSize: viewport,
            contentSize: viewport
        )

        #expect(result.scale == 2)
        #expect(result.offset == CGSize(width: 100, height: 200))

        let center = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        let transformedFocalPoint = CGPoint(
            x: center.x + (focalPoint.x - center.x) * result.scale + result.offset.width,
            y: center.y + (focalPoint.y - center.y) * result.scale + result.offset.height
        )
        #expect(abs(transformedFocalPoint.x - focalPoint.x) < 0.001)
        #expect(abs(transformedFocalPoint.y - focalPoint.y) < 0.001)
    }

    @Test func panIsClampedToTheVisibleContentBounds() {
        let result = ReaderZoomMath.pannedTransform(
            from: ReaderZoomTransform(scale: 2, offset: .zero),
            translation: CGSize(width: 900, height: 900),
            viewportSize: CGSize(width: 400, height: 400),
            contentSize: CGSize(width: 400, height: 800)
        )

        #expect(result.offset == CGSize(width: 200, height: 600))
    }

    @Test func zoomedPanUsesViewportCoordinates() {
        let result = ReaderZoomMath.pannedTransform(
            from: ReaderZoomTransform(scale: 3, offset: .zero),
            translation: CGSize(width: 100, height: 100),
            viewportSize: CGSize(width: 400, height: 400),
            contentSize: CGSize(width: 400, height: 800)
        )

        #expect(result.offset == CGSize(width: 100, height: 100))
    }

    @Test func settlingNearOneXResetsScaleAndOffset() {
        let result = ReaderZoomMath.settledTransform(
            ReaderZoomTransform(scale: 1.015, offset: CGSize(width: 20, height: -20)),
            viewportSize: CGSize(width: 400, height: 800),
            contentSize: CGSize(width: 400, height: 800)
        )

        #expect(result == ReaderZoomTransform(scale: 1, offset: .zero))
    }

    @Test func pinchGateKeepsOneFingerPossibleUntilSecondFingerArrives() {
        var gate = ReaderPinchTouchGate()

        gate.receiveTouchBegan(activeTouchCount: 1, primaryLocation: .zero)
        let smallMove = gate.receiveMove(
            activeTouchCount: 1,
            primaryLocation: CGPoint(x: 0, y: 10)
        )
        #expect(!smallMove)

        gate.receiveTouchBegan(activeTouchCount: 2, primaryLocation: nil)

        #expect(!gate.hasFailedForSingleTouch)
    }

    @Test func pinchGateFailsOnlyAfterSingleFingerActivationDistance() {
        var gate = ReaderPinchTouchGate()

        gate.receiveTouchBegan(activeTouchCount: 1, primaryLocation: .zero)
        let beforeActivation = gate.receiveMove(
            activeTouchCount: 1,
            primaryLocation: CGPoint(x: 0, y: 27)
        )
        #expect(!beforeActivation)
        let atActivation = gate.receiveMove(
            activeTouchCount: 1,
            primaryLocation: CGPoint(x: 0, y: 28)
        )
        #expect(atActivation)
        #expect(gate.hasFailedForSingleTouch)
    }

    @Test func pagePanTouchGateRejectsASecondFingerAndCannotReenter() {
        var gate = ReaderPagePanTouchGate()

        let firstTouchAccepted = gate.receiveTouch(activeTouchCount: 1)
        let firstTouchMoveAccepted = gate.receiveTouch(activeTouchCount: 1)
        let secondTouchRejected = gate.receiveTouch(activeTouchCount: 2)
        #expect(!firstTouchAccepted)
        #expect(!firstTouchMoveAccepted)
        #expect(secondTouchRejected)
        #expect(gate.hasRejectedMultipleTouch)
        let laterMoveRejected = gate.receiveTouch(activeTouchCount: 1)
        #expect(laterMoveRejected)
    }

    @MainActor
    @Test func pageInteractionHostOwnsPinchAndPanRecognizers() {
        let coordinator = ReaderZoomGestureView.Coordinator(
            scale: 1,
            offset: .zero,
            viewportSize: CGSize(width: 400, height: 800),
            contentSize: CGSize(width: 400, height: 800),
            maximumScale: ReaderZoomMath.defaultMaximumScale,
            onTransformChanged: { _ in },
            onGestureEnded: {}
        )
        let host = ReaderZoomGestureView.ReaderPageInteractionHostView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 800)
        )

        coordinator.install(on: host)

        #expect(host.isUserInteractionEnabled)
        #expect(host.isMultipleTouchEnabled)
        #expect(host.gestureRecognizers?.contains(where: { $0 === coordinator.pinchRecognizer }) == true)
        #expect(host.gestureRecognizers?.contains(where: { $0 === coordinator.panRecognizer }) == true)
    }

    @MainActor
    @Test func zoomPanIsEnabledOnlyWhenPageIsZoomed() {
        let zoomCoordinator = ReaderZoomGestureView.Coordinator(
            scale: 1,
            offset: .zero,
            viewportSize: CGSize(width: 400, height: 800),
            contentSize: CGSize(width: 400, height: 800),
            maximumScale: ReaderZoomMath.defaultMaximumScale,
            onTransformChanged: { _ in },
            onGestureEnded: {}
        )
        #expect(!zoomCoordinator.panRecognizer.isEnabled)

        zoomCoordinator.update(
            scale: 3,
            offset: .zero,
            viewportSize: CGSize(width: 400, height: 800),
            contentSize: CGSize(width: 400, height: 800),
            maximumScale: ReaderZoomMath.defaultMaximumScale,
            onTransformChanged: { _ in },
            onGestureEnded: {}
        )
        #expect(zoomCoordinator.panRecognizer.isEnabled)

        zoomCoordinator.update(
            scale: 1,
            offset: .zero,
            viewportSize: CGSize(width: 400, height: 800),
            contentSize: CGSize(width: 400, height: 800),
            maximumScale: ReaderZoomMath.defaultMaximumScale,
            onTransformChanged: { _ in },
            onGestureEnded: {}
        )
        #expect(!zoomCoordinator.panRecognizer.isEnabled)
    }

    @MainActor
    @Test func readerGestureWiringAttachesToThePageHost() {
        let host = ReaderZoomGestureView.ReaderPageInteractionHostView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 800)
        )

        let zoomCoordinator = ReaderZoomGestureView.Coordinator(
            scale: 1,
            offset: .zero,
            viewportSize: host.bounds.size,
            contentSize: host.bounds.size,
            maximumScale: ReaderZoomMath.defaultMaximumScale,
            onTransformChanged: { _ in },
            onGestureEnded: {}
        )
        zoomCoordinator.install(on: host)

        #expect(host.gestureRecognizers?.contains(where: { $0 === zoomCoordinator.pinchRecognizer }) == true)
        #expect(host.gestureRecognizers?.contains(where: { $0 === zoomCoordinator.panRecognizer }) == true)
        zoomCoordinator.uninstall()
    }

    @MainActor
    @Test func pagedHostEnablesItsSingleFingerPanAtOneX() {
        let coordinator = makeCoordinator(
            scale: 1,
            pagePanConfiguration: makePagePanConfiguration()
        )
        let host = makeHost()

        coordinator.install(on: host)

        #expect(coordinator.panRecognizer.isEnabled)
        #expect(coordinator.panRecognizer.minimumNumberOfTouches == 1)
        #expect(coordinator.panRecognizer.maximumNumberOfTouches == 1)
        #expect(coordinator.gestureRecognizer(
            coordinator.pinchRecognizer,
            shouldRecognizeSimultaneouslyWith: coordinator.panRecognizer
        ))
        #expect(coordinator.gestureRecognizer(
            coordinator.panRecognizer,
            shouldRecognizeSimultaneouslyWith: coordinator.pinchRecognizer
        ))
    }

    @MainActor
    @Test func hostRoutesOneFingerHorizontalDragToPageTurn() {
        var pageDragValues: [CGFloat] = []
        var pageTurns: [ReaderPageTurnDirection] = []
        var dismissProgress: [CGFloat] = []

        let coordinator = makeCoordinator(
            scale: 1,
            pagePanConfiguration: ReaderPagePanConfiguration(
                mode: .horizontalPage,
                isDismissEnabled: true,
                pageExtent: 400,
                viewportHeight: 800,
                isRTL: false,
                onPageDragChanged: { pageDragValues.append($0) },
                onPageTurn: { pageTurns.append($0) },
                onDismissProgress: { dismissProgress.append($0) },
                onDismissCancel: {},
                onDismissCommit: {}
            )
        )
        let host = makeHost()
        coordinator.install(on: host)

        coordinator.receivePanEventForTesting(state: .began, translation: .zero)
        coordinator.receivePanEventForTesting(
            state: .changed,
            translation: CGSize(width: -120, height: 8)
        )

        #expect(coordinator.panIntent == .pageTurning)
        #expect(pageDragValues.last == -120)
        #expect(dismissProgress.isEmpty)
        #expect(coordinator.pinchRecognizer.state == .possible)

        coordinator.receivePanEventForTesting(
            state: .ended,
            translation: CGSize(width: -120, height: 8)
        )

        #expect(pageTurns == [.next])
        #expect(pageDragValues.last == 0)
    }

    @MainActor
    @Test func hostRoutesOneFingerDownwardDragToDismissal() {
        var dismissProgress: [CGFloat] = []
        var cancelCount = 0
        var commitCount = 0

        let coordinator = makeCoordinator(
            scale: 1,
            pagePanConfiguration: ReaderPagePanConfiguration(
                mode: .horizontalPage,
                isDismissEnabled: true,
                pageExtent: 400,
                viewportHeight: 800,
                isRTL: false,
                onPageDragChanged: { _ in },
                onPageTurn: { _ in },
                onDismissProgress: { dismissProgress.append($0) },
                onDismissCancel: { cancelCount += 1 },
                onDismissCommit: { commitCount += 1 }
            )
        )
        let host = makeHost()
        coordinator.install(on: host)

        coordinator.receivePanEventForTesting(state: .began, translation: .zero)
        coordinator.receivePanEventForTesting(
            state: .changed,
            translation: CGSize(width: 0, height: 80)
        )

        #expect(coordinator.panIntent == .dismissing)
        #expect(dismissProgress.last ?? 0 > 0)

        coordinator.receivePanEventForTesting(
            state: .ended,
            translation: CGSize(width: 0, height: 80)
        )

        #expect(cancelCount == 1)
        #expect(commitCount == 0)
    }

    @MainActor
    @Test func hostCommitsDismissalAtTheHardCommitDistance() {
        var cancelCount = 0
        var commitCount = 0

        let coordinator = makeCoordinator(
            scale: 1,
            pagePanConfiguration: ReaderPagePanConfiguration(
                mode: .horizontalPage,
                isDismissEnabled: true,
                pageExtent: 400,
                viewportHeight: 800,
                isRTL: false,
                onPageDragChanged: { _ in },
                onPageTurn: { _ in },
                onDismissProgress: { _ in },
                onDismissCancel: { cancelCount += 1 },
                onDismissCommit: { commitCount += 1 }
            )
        )
        let host = makeHost()
        coordinator.install(on: host)

        coordinator.receivePanEventForTesting(state: .began, translation: .zero)
        coordinator.receivePanEventForTesting(
            state: .changed,
            translation: CGSize(width: 0, height: 180)
        )
        coordinator.receivePanEventForTesting(
            state: .ended,
            translation: CGSize(width: 0, height: 180)
        )

        #expect(cancelCount == 0)
        #expect(commitCount == 1)
    }

    @MainActor
    @Test func hostCancelsDismissalAfterSixteenPointReverseAndCannotReenter() {
        var dismissProgress: [CGFloat] = []
        var cancelCount = 0
        var commitCount = 0

        let coordinator = makeCoordinator(
            scale: 1,
            pagePanConfiguration: ReaderPagePanConfiguration(
                mode: .horizontalPage,
                isDismissEnabled: true,
                pageExtent: 400,
                viewportHeight: 800,
                isRTL: false,
                onPageDragChanged: { _ in },
                onPageTurn: { _ in },
                onDismissProgress: { dismissProgress.append($0) },
                onDismissCancel: { cancelCount += 1 },
                onDismissCommit: { commitCount += 1 }
            )
        )
        let host = makeHost()
        coordinator.install(on: host)

        coordinator.receivePanEventForTesting(state: .began, translation: .zero)
        coordinator.receivePanEventForTesting(
            state: .changed,
            translation: CGSize(width: 0, height: 80)
        )
        coordinator.receivePanEventForTesting(
            state: .changed,
            translation: CGSize(width: 0, height: 63)
        )
        coordinator.receivePanEventForTesting(
            state: .changed,
            translation: CGSize(width: 0, height: 180)
        )
        coordinator.receivePanEventForTesting(
            state: .ended,
            translation: CGSize(width: 0, height: 180)
        )

        #expect(cancelCount == 1)
        #expect(commitCount == 0)
        #expect(dismissProgress.count == 1)
    }

    @MainActor
    @Test func hostUsesTheSamePanForZoomedImageWithoutPageCallbacks() {
        var transformChanges: [ReaderZoomTransform] = []
        var pageTurns: [ReaderPageTurnDirection] = []
        var dismissProgress: [CGFloat] = []
        var gestureEndCount = 0

        let coordinator = ReaderZoomGestureView.Coordinator(
            scale: 3,
            offset: .zero,
            viewportSize: CGSize(width: 400, height: 800),
            contentSize: CGSize(width: 400, height: 800),
            maximumScale: ReaderZoomMath.defaultMaximumScale,
            onTransformChanged: { transformChanges.append($0) },
            onGestureEnded: { gestureEndCount += 1 },
            pagePanConfiguration: ReaderPagePanConfiguration(
                mode: .horizontalPage,
                isDismissEnabled: true,
                pageExtent: 400,
                viewportHeight: 800,
                isRTL: false,
                onPageDragChanged: { _ in },
                onPageTurn: { pageTurns.append($0) },
                onDismissProgress: { dismissProgress.append($0) },
                onDismissCancel: {},
                onDismissCommit: {}
            )
        )
        let host = makeHost()
        coordinator.install(on: host)

        coordinator.receivePanEventForTesting(state: .began, translation: .zero)
        coordinator.receivePanEventForTesting(
            state: .changed,
            translation: CGSize(width: -120, height: 20)
        )

        #expect(coordinator.panIntent == .zoomPanning)
        #expect(transformChanges.last?.offset == CGSize(width: -120, height: 20))
        #expect(pageTurns.isEmpty)
        #expect(dismissProgress.isEmpty)

        coordinator.receivePanEventForTesting(
            state: .ended,
            translation: CGSize(width: -120, height: 20)
        )
        #expect(gestureEndCount == 1)
    }

    @MainActor
    @Test func hostKeepsVerticalFirstPageUpwardDragOnPagePath() {
        var pageDragValues: [CGFloat] = []
        var pageTurns: [ReaderPageTurnDirection] = []
        var dismissProgress: [CGFloat] = []

        let coordinator = makeCoordinator(
            scale: 1,
            pagePanConfiguration: ReaderPagePanConfiguration(
                mode: .verticalPage(isFirstPage: true),
                isDismissEnabled: true,
                pageExtent: 800,
                viewportHeight: 800,
                isRTL: false,
                onPageDragChanged: { pageDragValues.append($0) },
                onPageTurn: { pageTurns.append($0) },
                onDismissProgress: { dismissProgress.append($0) },
                onDismissCancel: {},
                onDismissCommit: {}
            )
        )
        let host = makeHost()
        coordinator.install(on: host)

        coordinator.receivePanEventForTesting(state: .began, translation: .zero)
        coordinator.receivePanEventForTesting(
            state: .changed,
            translation: CGSize(width: 4, height: -40)
        )

        #expect(coordinator.panIntent == .pageTurning)
        #expect(pageDragValues.last == -40)
        #expect(dismissProgress.isEmpty)

        coordinator.receivePanEventForTesting(
            state: .ended,
            translation: CGSize(width: 4, height: -200)
        )
        #expect(pageTurns == [.previous])
    }

    @MainActor
    @Test func hostDoesNotDismissDownwardDragOnNonFirstVerticalPage() {
        var pageDragValues: [CGFloat] = []
        var dismissProgress: [CGFloat] = []

        let coordinator = makeCoordinator(
            scale: 1,
            pagePanConfiguration: ReaderPagePanConfiguration(
                mode: .verticalPage(isFirstPage: false),
                isDismissEnabled: true,
                pageExtent: 800,
                viewportHeight: 800,
                isRTL: false,
                onPageDragChanged: { pageDragValues.append($0) },
                onPageTurn: { _ in },
                onDismissProgress: { dismissProgress.append($0) },
                onDismissCancel: {},
                onDismissCommit: {}
            )
        )
        let host = makeHost()
        coordinator.install(on: host)

        coordinator.receivePanEventForTesting(state: .began, translation: .zero)
        coordinator.receivePanEventForTesting(
            state: .changed,
            translation: CGSize(width: 4, height: 40)
        )

        #expect(coordinator.panIntent == .pageTurning)
        #expect(pageDragValues.last == 40)
        #expect(dismissProgress.isEmpty)
    }

    @MainActor
    private func makeHost() -> ReaderZoomGestureView.ReaderPageInteractionHostView {
        ReaderZoomGestureView.ReaderPageInteractionHostView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 800)
        )
    }

    @MainActor
    private func makeCoordinator(
        scale: CGFloat,
        pagePanConfiguration: ReaderPagePanConfiguration?
    ) -> ReaderZoomGestureView.Coordinator {
        ReaderZoomGestureView.Coordinator(
            scale: scale,
            offset: .zero,
            viewportSize: CGSize(width: 400, height: 800),
            contentSize: CGSize(width: 400, height: 800),
            maximumScale: ReaderZoomMath.defaultMaximumScale,
            onTransformChanged: { _ in },
            onGestureEnded: {},
            pagePanConfiguration: pagePanConfiguration
        )
    }

    private func makePagePanConfiguration() -> ReaderPagePanConfiguration {
        ReaderPagePanConfiguration(
            mode: .horizontalPage,
            isDismissEnabled: true,
            pageExtent: 400,
            viewportHeight: 800,
            isRTL: false,
            onPageDragChanged: { _ in },
            onPageTurn: { _ in },
            onDismissProgress: { _ in },
            onDismissCancel: {},
            onDismissCommit: {}
        )
    }
}
