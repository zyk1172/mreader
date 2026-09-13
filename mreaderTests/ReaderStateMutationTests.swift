import XCTest
@testable import mreader

final class ReaderStateMutationTests: XCTestCase {
    func testSinglePageGateOnlyAllowsPageTurnAtUnitScale() {
        XCTAssertTrue(ReaderGestureGate.allowsSinglePageTurn(isZoomed: false))
        XCTAssertFalse(ReaderGestureGate.allowsSinglePageTurn(isZoomed: true))

        XCTAssertFalse(ReaderGestureGate.isZoomed(scale: 1.05))
        XCTAssertTrue(ReaderGestureGate.isZoomed(scale: 1.051))
    }

    func testDoublePageGateRequiresEveryPageToLeaveZoom() {
        var zoomedPages = Set<Int>()
        XCTAssertTrue(ReaderGestureGate.allowsDoublePageTurn(zoomedPageIndexes: zoomedPages))

        zoomedPages.insert(0)
        XCTAssertFalse(ReaderGestureGate.allowsDoublePageTurn(zoomedPageIndexes: zoomedPages))

        zoomedPages.insert(1)
        XCTAssertFalse(ReaderGestureGate.allowsDoublePageTurn(zoomedPageIndexes: zoomedPages))

        // 左页回到 1x 不能清掉仍处于放大态的右页。
        zoomedPages.remove(0)
        XCTAssertFalse(ReaderGestureGate.allowsDoublePageTurn(zoomedPageIndexes: zoomedPages))

        zoomedPages.remove(1)
        XCTAssertTrue(ReaderGestureGate.allowsDoublePageTurn(zoomedPageIndexes: zoomedPages))
    }

    func testComicMutationProducesTheValueThatPersistenceReceives() {
        let original = ComicBook(
            title: "Reader state test",
            bookmarkData: Data(),
            totalPages: 8,
            currentPageIndex: 1,
            isOCREnabled: true,
            isAITranslationEnabled: true
        )
        let mutationDate = Date(timeIntervalSince1970: 123)

        let persistedValue = ReaderComicMutation.applying(
            { comic in
                comic.currentPageIndex = 4
                comic.furthestPageIndex = 4
                comic.readingModeRaw = ReadingMode.doublePage.rawValue
                comic.imageFitModeRaw = ImageFitMode.fitWidth.rawValue
                comic.readingDirectionRaw = ReadingDirection.rightToLeft.rawValue
                comic.isOCREnabled = false
                comic.isAITranslationEnabled = false
                comic.isAutoTranslationEnabled = true
                comic.ocrTextScale = 0.8
            },
            to: original,
            now: mutationDate
        )

        XCTAssertEqual(persistedValue.currentPageIndex, 4)
        XCTAssertEqual(persistedValue.furthestPageIndex, 4)
        XCTAssertEqual(persistedValue.readingModeRaw, ReadingMode.doublePage.rawValue)
        XCTAssertEqual(persistedValue.imageFitModeRaw, ImageFitMode.fitWidth.rawValue)
        XCTAssertEqual(persistedValue.readingDirectionRaw, ReadingDirection.rightToLeft.rawValue)
        XCTAssertFalse(persistedValue.isOCREnabled)
        XCTAssertFalse(persistedValue.isAITranslationEnabled)
        XCTAssertFalse(persistedValue.isAutoTranslationEnabled)
        XCTAssertEqual(persistedValue.ocrTextScale, 0.8, accuracy: 0.0001)
        XCTAssertEqual(persistedValue.metadataUpdatedAt, mutationDate)
        XCTAssertEqual(original.currentPageIndex, 1, "the source value remains an independent input")
    }
}
