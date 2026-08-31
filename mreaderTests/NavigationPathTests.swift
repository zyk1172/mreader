import Foundation
import Testing
@testable import mreader

@Suite
struct NavigationPathTests {
    @Test func closingReaderReturnsToLibraryWhenOpenedDirectly() {
        let comicID = UUID()
        #expect(
            ShelfNavigationPathPolicy.removingReader(from: [.reader(comicID)]) == []
        )
    }

    @Test func closingReaderPreservesSeriesRoute() {
        let seriesID = UUID()
        let comicID = UUID()
        #expect(
            ShelfNavigationPathPolicy.removingReader(
                from: [.series(seriesID), .reader(comicID)]
            ) == [.series(seriesID)]
        )
    }

    @Test func closingSeriesOnlyPopsSeriesRoute() {
        let seriesID = UUID()
        #expect(
            ShelfNavigationPathPolicy.removingSeries(from: [.series(seriesID)]) == []
        )
        #expect(
            ShelfNavigationPathPolicy.removingSeries(from: []) == []
        )
    }
}
