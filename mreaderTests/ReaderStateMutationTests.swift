import XCTest
import UIKit
@testable import mreader

@MainActor
final class ReaderStateMutationTests: XCTestCase {
    func testSinglePageGateOnlyAllowsPageTurnAtUnitScale() {
        XCTAssertTrue(ReaderGestureGate.allowsSinglePageTurn(isZoomed: false))
        XCTAssertFalse(ReaderGestureGate.allowsSinglePageTurn(isZoomed: true))

        XCTAssertFalse(ReaderGestureGate.isZoomed(scale: 1.05))
        XCTAssertTrue(ReaderGestureGate.isZoomed(scale: 1.051))
    }

    func testContinuousScrollDoesNotInstallSingleFingerPanGesture() {
        XCTAssertFalse(ReaderGestureGate.allowsSingleFingerPan(readingMode: .continuousScroll))
        XCTAssertFalse(ReaderGestureGate.allowsSingleFingerPan(readingMode: .infiniteScroll))
        XCTAssertTrue(ReaderGestureGate.allowsSingleFingerPan(readingMode: .horizontalPage))
        XCTAssertTrue(ReaderGestureGate.allowsSingleFingerPan(readingMode: .verticalPage))
        XCTAssertTrue(ReaderGestureGate.allowsSingleFingerPan(readingMode: .doublePage))
        XCTAssertTrue(ReaderGestureGate.allowsSingleFingerPan(readingMode: .guidedPanel))
    }

    func testContinuousScrollPageProgressUsesStablePageStartOffset() {
        XCTAssertEqual(
            ReaderContinuousScrollPolicy.pageProgress(
                contentOffsetY: 10_500,
                pageStartOffsetY: 10_000,
                pageHeight: 2_000
            ),
            0.25,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ReaderContinuousScrollPolicy.pageProgress(
                contentOffsetY: 9_000,
                pageStartOffsetY: 10_000,
                pageHeight: 2_000
            ),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ReaderContinuousScrollPolicy.pageProgress(
                contentOffsetY: 13_000,
                pageStartOffsetY: 10_000,
                pageHeight: 2_000
            ),
            1,
            accuracy: 0.001
        )
    }

    func testContinuousScrollRestoreUsesPageTopAndHeightOnly() {
        XCTAssertEqual(
            ReaderContinuousScrollPolicy.restoredContentOffsetY(
                pageTopOffsetY: 10_000,
                pageHeight: 2_000,
                pageProgress: 0.25,
                minimumOffsetY: 0,
                maximumOffsetY: 20_000
            ),
            10_500,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ReaderContinuousScrollPolicy.restoredContentOffsetY(
                pageTopOffsetY: 19_900,
                pageHeight: 2_000,
                pageProgress: 1,
                minimumOffsetY: 0,
                maximumOffsetY: 20_000
            ),
            20_000,
            accuracy: 0.001
        )
    }

    func testContinuousScrollEstimatesPageStartAcrossDirectionChanges() {
        XCTAssertEqual(
            ReaderContinuousScrollPolicy.estimatedPageStartOffsetY(
                currentOffsetY: 10_000,
                newPageHeight: 2_000,
                movingBackward: false
            ),
            10_000,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ReaderContinuousScrollPolicy.estimatedPageStartOffsetY(
                currentOffsetY: 10_000,
                newPageHeight: 2_000,
                movingBackward: true
            ),
            8_000,
            accuracy: 0.001
        )
    }

    func testContinuousScrollVelocityLimiterCapsTrackingDeltaPerFrame() {
        let limited = ReaderScrollVelocityPolicy.clampedOffsetY(
            previousOffsetY: 1_000,
            proposedOffsetY: 1_500,
            viewportHeight: 800,
            frameDuration: 1.0 / 60.0,
            scrollSpeed: .standard,
            isTracking: true,
            minimumOffsetY: 0,
            maximumOffsetY: 20_000
        )
        XCTAssertEqual(limited, 1_032, accuracy: 0.001)
    }

    func testContinuousScrollVelocityLimiterIsStricterDuringDeceleration() {
        let tracking = ReaderScrollVelocityPolicy.maximumDelta(
            viewportHeight: 800,
            frameDuration: 1.0 / 60.0,
            scrollSpeed: .standard,
            isTracking: true
        )
        let decelerating = ReaderScrollVelocityPolicy.maximumDelta(
            viewportHeight: 800,
            frameDuration: 1.0 / 60.0,
            scrollSpeed: .standard,
            isTracking: false
        )
        XCTAssertGreaterThan(tracking, decelerating)
        XCTAssertEqual(tracking, 32, accuracy: 0.001)
        XCTAssertEqual(decelerating, 19.3333333, accuracy: 0.001)
        XCTAssertLessThan(
            ReaderScrollVelocityPolicy.screensPerSecond(for: .slow, isTracking: false),
            ReaderScrollVelocityPolicy.screensPerSecond(for: .standard, isTracking: false)
        )
        XCTAssertLessThan(
            ReaderScrollVelocityPolicy.screensPerSecond(for: .standard, isTracking: false),
            ReaderScrollVelocityPolicy.screensPerSecond(for: .fast, isTracking: false)
        )
    }

    func testContinuousScrollVelocityLimiterPreservesNormalSlowMotion() {
        let proposed: CGFloat = 1_018
        let limited = ReaderScrollVelocityPolicy.clampedOffsetY(
            previousOffsetY: 1_000,
            proposedOffsetY: proposed,
            viewportHeight: 800,
            frameDuration: 1.0 / 60.0,
            scrollSpeed: .standard,
            isTracking: false,
            minimumOffsetY: 0,
            maximumOffsetY: 20_000
        )
        XCTAssertEqual(limited, proposed, accuracy: 0.001)
    }

    func testFitWidthDecodePolicyUsesSmallestSufficientTier() {
        XCTAssertEqual(
            ReaderFitWidthDecodePolicy.maxPixelSize(
                sourceSize: CGSize(width: 1_200, height: 1_800),
                viewportWidthPoints: 390,
                displayScale: 3
            ),
            4_096
        )
        XCTAssertEqual(
            ReaderFitWidthDecodePolicy.maxPixelSize(
                sourceSize: CGSize(width: 1_200, height: 6_000),
                viewportWidthPoints: 390,
                displayScale: 3
            ),
            6_144
        )
        XCTAssertEqual(
            ReaderFitWidthDecodePolicy.maxPixelSize(
                sourceSize: CGSize(width: 1_200, height: 12_000),
                viewportWidthPoints: 390,
                displayScale: 3
            ),
            8_192
        )
        XCTAssertEqual(
            ReaderFitWidthDecodePolicy.maxPixelSize(
                sourceSize: nil,
                viewportWidthPoints: 390,
                displayScale: 3
            ),
            8_192
        )
    }

    func testRemotePageGeometryReadsPixelSizeWithoutFullDecode() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: 10, height: 20),
            format: format
        )
        let image = renderer.image { context in
            context.cgContext.setFillColor(UIColor.black.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 10, height: 20))
        }
        let data = try XCTUnwrap(image.pngData())
        let size = try XCTUnwrap(RemotePageGeometry.pixelSize(from: data))
        XCTAssertEqual(size.width, 10, accuracy: 0.001)
        XCTAssertEqual(size.height, 20, accuracy: 0.001)
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


@MainActor
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
