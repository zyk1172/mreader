from pathlib import Path

path = Path("mreader/ContentView.swift")
text = path.read_text()

replacements = {
    "            let sortedComicsBySeriesID = comicIndex.comicsBySeriesID.mapValues { sortedComicsByTitle($0) }\n": "",
    "seriesGridItem(series, comics: sortedComicsBySeriesID[series.id] ?? [], cardWidth: cardWidth)": "seriesGridItem(series, comics: sortedComicsByTitle(comicIndex.comicsBySeriesID[series.id] ?? []), cardWidth: cardWidth)",
    "seriesListItem(series, comics: sortedComicsBySeriesID[series.id] ?? [])": "seriesListItem(series, comics: sortedComicsByTitle(comicIndex.comicsBySeriesID[series.id] ?? []))",
}

for old, new in replacements.items():
    if old not in text:
        raise SystemExit(f"Expected text not found: {old!r}")
    text = text.replace(old, new, 1)

path.write_text(text)
Path(".github/workflows/refine-shelf-series-sorting.yml").unlink(missing_ok=True)
Path("scripts/refine_shelf_series_sorting.py").unlink(missing_ok=True)
