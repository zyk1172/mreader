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
    @Test func zoomPanIsEnabledOnlyWhenPageIsZoomedAndDismissDoesNotWaitForIt() {
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

        let dismissCoordinator = ReaderDismissGestureView.Coordinator(
            isEnabled: true,
            canBeginDismiss: { true },
            onProgress: { _ in },
            onCancel: {},
            onCommit: {}
        )
        #expect(dismissCoordinator.gestureRecognizer(
            dismissCoordinator.recognizer,
            shouldRequireFailureOf: zoomCoordinator.pinchRecognizer
        ))
        #expect(!dismissCoordinator.gestureRecognizer(
            dismissCoordinator.recognizer,
            shouldRequireFailureOf: zoomCoordinator.panRecognizer
        ))

        let scrollView = UIScrollView()
        #expect(dismissCoordinator.gestureRecognizer(
            dismissCoordinator.recognizer,
            shouldRecognizeSimultaneouslyWith: scrollView.panGestureRecognizer
        ))

        let disabledDismissCoordinator = ReaderDismissGestureView.Coordinator(
            isEnabled: false,
            canBeginDismiss: { true },
            onProgress: { _ in },
            onCancel: {},
            onCommit: {}
        )
        #expect(!disabledDismissCoordinator.recognizer.isEnabled)
    }

    @MainActor
    @Test func readerGestureWiringAttachesToThePageHost() {
        let windowScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        #expect(windowScene != nil)
        guard let windowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        let host = ReaderZoomGestureView.ReaderPageInteractionHostView(
            frame: window.bounds
        )
        window.addSubview(host)

        let zoomCoordinator = ReaderZoomGestureView.Coordinator(
            scale: 1,
            offset: .zero,
            viewportSize: window.bounds.size,
            contentSize: window.bounds.size,
            maximumScale: ReaderZoomMath.defaultMaximumScale,
            onTransformChanged: { _ in },
            onGestureEnded: {}
        )
        let dismissCoordinator = ReaderDismissGestureView.Coordinator(
            isEnabled: true,
            canBeginDismiss: { true },
            onProgress: { _ in },
            onCancel: {},
            onCommit: {}
        )

        dismissCoordinator.attach(to: window)
        zoomCoordinator.install(on: host)

        #expect(window.gestureRecognizers?.contains(where: { $0 === dismissCoordinator.recognizer }) == true)
        #expect(host.gestureRecognizers?.contains(where: { $0 === zoomCoordinator.pinchRecognizer }) == true)
        #expect(host.gestureRecognizers?.contains(where: { $0 === zoomCoordinator.panRecognizer }) == true)
        #expect(dismissCoordinator.gestureRecognizer(
            dismissCoordinator.recognizer,
            shouldRequireFailureOf: zoomCoordinator.pinchRecognizer
        ))
        #expect(!dismissCoordinator.gestureRecognizer(
            dismissCoordinator.recognizer,
            shouldRequireFailureOf: zoomCoordinator.panRecognizer
        ))

        zoomCoordinator.uninstall()
        dismissCoordinator.detach()
    }
}
