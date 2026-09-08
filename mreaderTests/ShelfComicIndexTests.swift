import Foundation
import Testing
@testable import mreader

struct ShelfComicIndexTests {
    @Test func partitionsVisibleComicsInOnePassAndPreservesBucketOrder() {
        let seriesA = UUID()
        let seriesB = UUID()

        let root = ComicBook(title: "Root", bookmarkData: Data(), totalPages: 1)
        let a1 = ComicBook(title: "A1", bookmarkData: Data(), totalPages: 1, seriesID: seriesA)
        let b1 = ComicBook(title: "B1", bookmarkData: Data(), totalPages: 1, seriesID: seriesB)
        let a2 = ComicBook(title: "A2", bookmarkData: Data(), totalPages: 1, seriesID: seriesA)

        let index = ShelfComicIndex(comics: [root, a1, b1, a2])

        #expect(index.rootComics.map(\.id) == [root.id])
        #expect(index.comicsBySeriesID[seriesA]?.map(\.id) == [a1.id, a2.id])
        #expect(index.comicsBySeriesID[seriesB]?.map(\.id) == [b1.id])
        #expect(index.visibleSeriesIDs == Set([seriesA, seriesB]))
    }

    @Test func emptyShelfProducesEmptyIndex() {
        let index = ShelfComicIndex(comics: [])

        #expect(index.rootComics.isEmpty)
        #expect(index.comicsBySeriesID.isEmpty)
        #expect(index.visibleSeriesIDs.isEmpty)
    }
}
