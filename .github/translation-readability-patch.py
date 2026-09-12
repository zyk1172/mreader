from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    file = Path(path)
    text = file.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one match, found {count}")
    file.write_text(text.replace(old, new, 1))


replace_once(
    "mreader/OCRBubbleLayoutEngine.swift",
    'let glyphCount = max(text.filter { !$0.isWhitespace && $0 != "\n" }.count, 1)',
    'let glyphCount = max(text.filter { !$0.isWhitespace && $0 != "\\n" }.count, 1)',
)
replace_once(
    "mreader/ReaderView.swift",
    'segments.joined(separator: "\n\n")',
    'segments.joined(separator: "\\n\\n")',
)

print("translation readability escaping fixed")
