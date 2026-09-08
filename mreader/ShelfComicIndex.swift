import Foundation

/// A single-pass partition of the currently visible shelf comics.
///
/// Building this once per shelf render avoids scanning the entire comic array
/// again for every visible series. Order within each bucket is preserved so the
/// caller can apply the existing title sort exactly once per bucket.
nonisolated struct ShelfComicIndex: Sendable {
    let rootComics: [ComicBook]
    let comicsBySeriesID: [UUID: [ComicBook]]
    let visibleSeriesIDs: Set<UUID>

    init(comics: [ComicBook]) {
        var rootComics: [ComicBook] = []
        var comicsBySeriesID: [UUID: [ComicBook]] = [:]
        var visibleSeriesIDs: Set<UUID> = []

        rootComics.reserveCapacity(comics.count)

        for comic in comics {
            guard let seriesID = comic.seriesID else {
                rootComics.append(comic)
                continue
            }

            comicsBySeriesID[seriesID, default: []].append(comic)
            visibleSeriesIDs.insert(seriesID)
        }

        self.rootComics = rootComics
        self.comicsBySeriesID = comicsBySeriesID
        self.visibleSeriesIDs = visibleSeriesIDs
    }
}
