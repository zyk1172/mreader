import Foundation

/// Precomputes the shelf's series membership from an already title-sorted comic list.
///
/// The shelf renders both series and root-level comics. Building this index in one
/// pass avoids filtering the complete comic list once for every visible series.
struct ShelfLibraryIndex {
    let sortedComics: [ComicBook]
    let rootComics: [ComicBook]
    let comicsBySeriesID: [UUID: [ComicBook]]
    let visibleSeriesIDs: Set<UUID>

    init(sortedComics: [ComicBook]) {
        self.sortedComics = sortedComics

        var rootComics: [ComicBook] = []
        rootComics.reserveCapacity(sortedComics.count)

        var comicsBySeriesID: [UUID: [ComicBook]] = [:]
        comicsBySeriesID.reserveCapacity(min(sortedComics.count, 64))

        for comic in sortedComics {
            if let seriesID = comic.seriesID {
                comicsBySeriesID[seriesID, default: []].append(comic)
            } else {
                rootComics.append(comic)
            }
        }

        self.rootComics = rootComics
        self.comicsBySeriesID = comicsBySeriesID
        self.visibleSeriesIDs = Set(comicsBySeriesID.keys)
    }

    func comics(for seriesID: UUID) -> [ComicBook] {
        comicsBySeriesID[seriesID] ?? []
    }
}
