import XCTest
@testable import mreader

@MainActor
final class ReaderUITestFixtureTests: XCTestCase {
    func testFixtureLoadsThroughTheProductionLocalPagePath() {
        guard let comic = ReaderUITestFixture.makeComic(force: true) else {
            return XCTFail("fixture should be constructible")
        }

        let result = ComicManager.loadPages(bookmarkData: comic.bookmarkData)
        XCTAssertEqual(result?.pages.count, 2)
        XCTAssertEqual(
            result?.pages.map(\.url.lastPathComponent),
            ["01.png", "02.png", "03.png", "04.png", "05.png"]
        )
    }
}
