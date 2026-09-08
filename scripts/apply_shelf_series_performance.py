from pathlib import Path

content_view = Path("mreader/ContentView.swift")
text = content_view.read_text()

old = '''            let displayComics = visibleComics
            let visibleSeriesIDs = Set(displayComics.compactMap(\\.seriesID))
            let seriesItems = shelfFilter == .all
                ? library.series
                : library.series.filter { visibleSeriesIDs.contains($0.id) }
            let sortedSeriesItems = sortedSeriesByTitle(seriesItems)
            let rootComics = sortedComicsByTitle(displayComics.filter { $0.seriesID == nil })

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if shelfDisplayMode == .grid {
                        LazyVGrid(columns: gridLayout.columns, spacing: 24) {
                            ForEach(sortedSeriesItems) { series in
                                seriesGridItem(series, comics: sortedComicsByTitle(displayComics.filter { $0.seriesID == series.id }), cardWidth: cardWidth)
                            }
                            ForEach(rootComics) { comic in
                                comicGridItem(comic, cardWidth: cardWidth)
                            }
                        }
                        .padding(.horizontal, ShelfCardMetrics.horizontalPadding)
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(sortedSeriesItems) { series in
                                seriesListItem(series, comics: sortedComicsByTitle(displayComics.filter { $0.seriesID == series.id }))
                            }
                            ForEach(rootComics) { comic in
                                comicListItem(comic)
                            }
                        }
'''

new = '''            let displayComics = visibleComics
            let comicIndex = ShelfComicIndex(comics: displayComics)
            let seriesItems = shelfFilter == .all
                ? library.series
                : library.series.filter { comicIndex.visibleSeriesIDs.contains($0.id) }
            let sortedSeriesItems = sortedSeriesByTitle(seriesItems)
            let rootComics = sortedComicsByTitle(comicIndex.rootComics)
            let sortedComicsBySeriesID = comicIndex.comicsBySeriesID.mapValues { sortedComicsByTitle($0) }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if shelfDisplayMode == .grid {
                        LazyVGrid(columns: gridLayout.columns, spacing: 24) {
                            ForEach(sortedSeriesItems) { series in
                                seriesGridItem(series, comics: sortedComicsBySeriesID[series.id] ?? [], cardWidth: cardWidth)
                            }
                            ForEach(rootComics) { comic in
                                comicGridItem(comic, cardWidth: cardWidth)
                            }
                        }
                        .padding(.horizontal, ShelfCardMetrics.horizontalPadding)
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(sortedSeriesItems) { series in
                                seriesListItem(series, comics: sortedComicsBySeriesID[series.id] ?? [])
                            }
                            ForEach(rootComics) { comic in
                                comicListItem(comic)
                            }
                        }
'''

if old not in text:
    if "let comicIndex = ShelfComicIndex(comics: displayComics)" not in text:
        raise SystemExit("Expected libraryPage block was not found; refusing a partial edit")
else:
    content_view.write_text(text.replace(old, new, 1))

Path(".github/workflows/apply-shelf-series-performance.yml").unlink(missing_ok=True)
Path("scripts/apply_shelf_series_performance.py").unlink(missing_ok=True)
