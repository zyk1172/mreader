import Testing
import Foundation
@testable import mreader

struct ShelfLibraryIndexTests {
    @Test func groupsSortedComicsInOneIndexWithoutChangingOrder() {
        let seriesA = UUID()
        let seriesB = UUID()
        let missingSeries = UUID()
        let sortedComics = [
            comic("Alpha", seriesID: seriesA),
            comic("Beta", seriesID: seriesB),
            comic("Gamma", seriesID: seriesA),
            comic("Root A"),
            comic("Root Z")
        ]

        let index = ShelfLibraryIndex(sortedComics: sortedComics)

        #expect(index.comics(for: seriesA).map(\.title) == ["Alpha", "Gamma"])
        #expect(index.comics(for: seriesB).map(\.title) == ["Beta"])
        #expect(index.rootComics.map(\.title) == ["Root A", "Root Z"])
        #expect(index.visibleSeriesIDs == Set([seriesA, seriesB]))
        #expect(index.comics(for: missingSeries).isEmpty)
    }

    @Test func emptyShelfProducesEmptyIndex() {
        let index = ShelfLibraryIndex(sortedComics: [])

        #expect(index.rootComics.isEmpty)
        #expect(index.comicsBySeriesID.isEmpty)
        #expect(index.visibleSeriesIDs.isEmpty)
    }

    private func comic(_ title: String, seriesID: UUID? = nil) -> ComicBook {
        ComicBook(
            title: title,
            bookmarkData: Data(),
            totalPages: 1,
            seriesID: seriesID
        )
    }
}
