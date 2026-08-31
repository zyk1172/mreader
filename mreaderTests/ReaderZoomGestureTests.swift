import CoreGraphics
import Testing
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

    @Test func settlingNearOneXResetsScaleAndOffset() {
        let result = ReaderZoomMath.settledTransform(
            ReaderZoomTransform(scale: 1.015, offset: CGSize(width: 20, height: -20)),
            viewportSize: CGSize(width: 400, height: 800),
            contentSize: CGSize(width: 400, height: 800)
        )

        #expect(result == ReaderZoomTransform(scale: 1, offset: .zero))
    }
}
