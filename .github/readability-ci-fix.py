from pathlib import Path

path = Path("mreader/ReaderView.swift")
text = path.read_text()
old = "minimumReadableFontSize: CGFloat(comic.minimumReadableTranslationFontSize)"
new = "minimumReadableFontSize: CGFloat(comic?.minimumReadableTranslationFontSize ?? ComicBook.defaultMinimumReadableTranslationFontSize)"
count = text.count(old)
if count != 1:
    raise SystemExit(f"expected one optional-comic match, found {count}")
path.write_text(text.replace(old, new, 1))
