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

    func testProgressStripClampsAndMapsFractions() {
        XCTAssertEqual(ReaderProgressStripPolicy.clampedPageIndex(-5, totalPages: 201), 0)
        XCTAssertEqual(ReaderProgressStripPolicy.clampedPageIndex(999, totalPages: 201), 200)
        XCTAssertEqual(ReaderProgressStripPolicy.clampedPageIndex(5, totalPages: 0), 0)

        XCTAssertEqual(ReaderProgressStripPolicy.pageIndex(forFraction: 0, totalPages: 201), 0)
        XCTAssertEqual(ReaderProgressStripPolicy.pageIndex(forFraction: 0.5, totalPages: 201), 100)
        XCTAssertEqual(ReaderProgressStripPolicy.pageIndex(forFraction: 1, totalPages: 201), 200)
        XCTAssertEqual(ReaderProgressStripPolicy.pageIndex(forFraction: -1, totalPages: 201), 0)
        XCTAssertEqual(ReaderProgressStripPolicy.pageIndex(forFraction: 2, totalPages: 201), 200)
    }

    func testDismissGestureRequiresExactlyTwoTouches() {
        XCTAssertFalse(ReaderDismissGestureGate.hasRequiredTouches(1))
        XCTAssertTrue(ReaderDismissGestureGate.hasRequiredTouches(2))
        XCTAssertFalse(ReaderDismissGestureGate.hasRequiredTouches(3))

        XCTAssertFalse(
            ReaderDismissGestureGate.shouldBegin(
                touchCount: 1,
                velocity: CGPoint(x: 0, y: 900)
            )
        )
        XCTAssertTrue(
            ReaderDismissGestureGate.shouldBegin(
                touchCount: 2,
                velocity: CGPoint(x: 20, y: 900)
            )
        )
        XCTAssertFalse(
            ReaderDismissGestureGate.shouldBegin(
                touchCount: 2,
                velocity: CGPoint(x: 900, y: 20)
            )
        )
        XCTAssertFalse(
            ReaderDismissGestureGate.isMostlyDownward(
                translation: CGPoint(x: 80, y: 40)
            )
        )
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


final class ReadingProgressResetRegressionTests: XCTestCase {
    func testNewerResetCanReduceCurrentAndFurthestProgressToZero() {
        let older = Date(timeIntervalSince1970: 10)
        let newer = Date(timeIntervalSince1970: 20)
        let existing = ComicBook(
            title: "Existing",
            bookmarkData: Data(),
            totalPages: 100,
            currentPageIndex: 42,
            furthestPageIndex: 70,
            progressUpdatedAt: older,
            hasBeenOpened: true
        )
        let incoming = ComicBook(
            id: existing.id,
            title: existing.title,
            bookmarkData: existing.bookmarkData,
            totalPages: 100,
            currentPageIndex: 0,
            furthestPageIndex: 0,
            progressUpdatedAt: newer,
            hasBeenOpened: false
        )

        let resolved = ReadingProgressMergePolicy.resolve(existing: existing, incoming: incoming, totalPages: 100)
        XCTAssertTrue(resolved.usesIncomingLocation)
        XCTAssertEqual(resolved.currentPageIndex, 0)
        XCTAssertEqual(resolved.furthestPageIndex, 0)
        XCTAssertEqual(resolved.progressUpdatedAt, newer)
    }

    func testOlderProgressCannotResurrectNewerReset() {
        let resetAt = Date(timeIntervalSince1970: 30)
        let staleAt = Date(timeIntervalSince1970: 20)
        let reset = ComicBook(
            title: "Reset",
            bookmarkData: Data(),
            totalPages: 80,
            currentPageIndex: 0,
            furthestPageIndex: 0,
            progressUpdatedAt: resetAt,
            hasBeenOpened: false
        )
        let stale = ComicBook(
            id: reset.id,
            title: reset.title,
            bookmarkData: reset.bookmarkData,
            totalPages: 80,
            currentPageIndex: 35,
            furthestPageIndex: 60,
            progressUpdatedAt: staleAt,
            hasBeenOpened: true
        )

        let resolved = ReadingProgressMergePolicy.resolve(existing: reset, incoming: stale, totalPages: 80)
        XCTAssertFalse(resolved.usesIncomingLocation)
        XCTAssertEqual(resolved.currentPageIndex, 0)
        XCTAssertEqual(resolved.furthestPageIndex, 0)
        XCTAssertEqual(resolved.progressUpdatedAt, resetAt)
    }
}
