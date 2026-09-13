import CoreGraphics
import XCTest
@testable import mreader

/// 审查 #4：平移边界必须基于「缩放后的图片是否超出 viewport」。
/// 直接用 `imageRect * (scale - 1) / 2` 只在图片恰好铺满容器时成立，
/// letterbox（fitScreen / fitHeight）与 original 都会算错并允许拖出空白。
final class ZoomPanGeometryTests: XCTestCase {

    private let container = CGSize(width: 1_000, height: 1_000)

    private func imageRect(
        page: CGSize,
        fitMode: OCRImageFitMode
    ) -> CGRect {
        OCRCoordinateMapper.displayTransform(
            sourcePixelSize: page,
            containerSize: container,
            fitMode: fitMode
        ).imageRect
    }

    func testFitScreenLetterboxedPageOnlyPansVerticallyUntilItFills() {
        // 1:2 竖版页面在正方形容器里：fitScreen 会在左右留白（imageRect = 500x1000）。
        let rect = imageRect(page: CGSize(width: 1_000, height: 2_000), fitMode: .fitScreen)
        XCTAssertEqual(rect.width, 500, accuracy: 0.0001)
        XCTAssertEqual(rect.height, 1_000, accuracy: 0.0001)

        // 1.5x：宽度 750 仍窄于容器 → 横向不允许平移。
        let atFifteen = ZoomPanGeometry.panLimits(imageRect: rect, containerSize: container, scale: 1.5)
        XCTAssertEqual(atFifteen.width, 0, accuracy: 0.0001)
        XCTAssertEqual(atFifteen.height, 250, accuracy: 0.0001)

        // 2x：宽度 1000 刚好铺满 → 横向仍然不允许平移（没有可看的额外内容）。
        let atTwo = ZoomPanGeometry.panLimits(imageRect: rect, containerSize: container, scale: 2)
        XCTAssertEqual(atTwo.width, 0, accuracy: 0.0001)
        XCTAssertEqual(atTwo.height, 500, accuracy: 0.0001)

        // 3x：宽度 1500 超出容器 → 横向才允许平移。
        let atThree = ZoomPanGeometry.panLimits(imageRect: rect, containerSize: container, scale: 3)
        XCTAssertEqual(atThree.width, 250, accuracy: 0.0001)
        XCTAssertEqual(atThree.height, 1_000, accuracy: 0.0001)
    }

    func testFitHeightWidePagePansBothAxes() {
        // 2:1 横版页面 + fitHeight：imageRect = 2000x1000，本身已横向溢出。
        let rect = imageRect(page: CGSize(width: 2_000, height: 1_000), fitMode: .fitHeight)
        XCTAssertEqual(rect.width, 2_000, accuracy: 0.0001)
        XCTAssertEqual(rect.height, 1_000, accuracy: 0.0001)

        let limits = ZoomPanGeometry.panLimits(imageRect: rect, containerSize: container, scale: 2)
        XCTAssertEqual(limits.width, 1_500, accuracy: 0.0001)
        XCTAssertEqual(limits.height, 500, accuracy: 0.0001)
    }

    func testOriginalModeSmallImageCannotPanUntilItExceedsTheViewport() {
        // 400x300 的小图在 .original 下按 1:1 显示，四周都是留白。
        let rect = imageRect(page: CGSize(width: 400, height: 300), fitMode: .original)
        XCTAssertEqual(rect.width, 400, accuracy: 0.0001)
        XCTAssertEqual(rect.height, 300, accuracy: 0.0001)

        // 2x：800x600 仍然小于容器 → 两轴都不允许平移。
        let atTwo = ZoomPanGeometry.panLimits(imageRect: rect, containerSize: container, scale: 2)
        XCTAssertEqual(atTwo.width, 0, accuracy: 0.0001)
        XCTAssertEqual(atTwo.height, 0, accuracy: 0.0001)

        // 3x：1200x900 → 横向超出 200，纵向仍未铺满 → 只允许横向平移。
        let atThree = ZoomPanGeometry.panLimits(imageRect: rect, containerSize: container, scale: 3)
        XCTAssertEqual(atThree.width, 100, accuracy: 0.0001)
        XCTAssertEqual(atThree.height, 0, accuracy: 0.0001)

        // 4x：1600x1200 → 两轴都超出。
        let atFour = ZoomPanGeometry.panLimits(imageRect: rect, containerSize: container, scale: 4)
        XCTAssertEqual(atFour.width, 300, accuracy: 0.0001)
        XCTAssertEqual(atFour.height, 100, accuracy: 0.0001)
    }

    func testFitWidthPagesPanBothAxes() {
        let rect = imageRect(page: CGSize(width: 1_000, height: 2_000), fitMode: .fitWidth)
        XCTAssertEqual(rect.width, 1_000, accuracy: 0.0001)
        XCTAssertEqual(rect.height, 2_000, accuracy: 0.0001)

        let limits = ZoomPanGeometry.panLimits(imageRect: rect, containerSize: container, scale: 2)
        XCTAssertEqual(limits.width, 500, accuracy: 0.0001)
        XCTAssertEqual(limits.height, 1_500, accuracy: 0.0001)
    }

    func testNoPanAtOrBelowUnitScale() {
        let rect = imageRect(page: CGSize(width: 1_000, height: 2_000), fitMode: .fitWidth)
        XCTAssertEqual(
            ZoomPanGeometry.panLimits(imageRect: rect, containerSize: container, scale: 1),
            .zero
        )
        XCTAssertEqual(
            ZoomPanGeometry.panLimits(imageRect: rect, containerSize: container, scale: 0.5),
            .zero
        )
    }

    func testClampedOffsetRespectsBothSignsAndZeroLimits() {
        let limits = CGSize(width: 120, height: 40)
        XCTAssertEqual(
            ZoomPanGeometry.clampedOffset(CGSize(width: 500, height: -500), limits: limits),
            CGSize(width: 120, height: -40)
        )
        XCTAssertEqual(
            ZoomPanGeometry.clampedOffset(CGSize(width: -30, height: 10), limits: limits),
            CGSize(width: -30, height: 10)
        )
        XCTAssertEqual(
            ZoomPanGeometry.clampedOffset(CGSize(width: 500, height: 500), limits: .zero),
            .zero,
            "letterbox 轴不允许任何平移"
        )
    }

    func testDegenerateInputsProduceNoLimits() {
        XCTAssertEqual(
            ZoomPanGeometry.panLimits(imageRect: .zero, containerSize: container, scale: 3),
            .zero
        )
        XCTAssertEqual(
            ZoomPanGeometry.panLimits(
                imageRect: CGRect(x: 0, y: 0, width: 100, height: 100),
                containerSize: .zero,
                scale: 3
            ),
            .zero
        )
    }
}
