import Foundation

/// A single-pass partition of the currently visible shelf comics.
///
/// Building this once per shelf render avoids scanning the entire comic array
/// again for every visible series. Buckets intentionally remain unsorted so the
/// LazyVGrid/LazyVStack caller can preserve the existing on-demand title sorting.
nonisolated struct ShelfComicIndex: Sendable {
    let rootComics: [ComicBook]
    let comicsBySeriesID: [UUID: [ComicBook]]
    let visibleSeriesIDs: Set<UUID>

    init(comics: [ComicBook]) {
        var rootComics: [ComicBook] = []
        var comicsBySeriesID: [UUID: [ComicBook]] = [:]

        for comic in comics {
            guard let seriesID = comic.seriesID else {
                rootComics.append(comic)
                continue
            }

            comicsBySeriesID[seriesID, default: []].append(comic)
        }

        self.rootComics = rootComics
        self.comicsBySeriesID = comicsBySeriesID
        self.visibleSeriesIDs = Set(comicsBySeriesID.keys)
    }
}
