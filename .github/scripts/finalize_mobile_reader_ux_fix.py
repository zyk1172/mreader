from pathlib import Path


def read(path: str) -> str:
    return Path(path).read_text(encoding="utf-8")


def write(path: str, text: str) -> None:
    Path(path).write_text(text, encoding="utf-8")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


# The one-shot patch intentionally stops at the two identical legacy assertion
# pairs. Resolve them by function order, then continue the final checks.
path = "mreaderTests/TranslationReadabilityRegressionTests.swift"
text = read(path)
text = replace_once(
    text,
    "    func testTinyBubbleStopsAtReadableFloorAndRequiresExpansion() {",
    "    func testTinyBubbleShrinksBelowPreferredFloorWithoutExpansion() {",
    "horizontal readability test name",
)
old_assertions = '''        XCTAssertGreaterThanOrEqual(choice.layout.fontSize, floor)
        XCTAssertEqual(choice.layout.status, .needsExpansion)
'''
new_assertions = '''        XCTAssertLessThan(choice.layout.fontSize, floor)
        XCTAssertGreaterThanOrEqual(choice.layout.fontSize, 2)
        XCTAssertEqual(choice.layout.status, .fitted)
'''
if text.count(old_assertions) != 2:
    raise SystemExit(f"readability assertions: expected two legacy pairs, found {text.count(old_assertions)}")
text = text.replace(old_assertions, new_assertions, 1)
text = replace_once(
    text,
    "    func testVerticalTinyBubbleNeverFallsBackToMicroscopicText() {",
    "    func testVerticalTinyBubbleShrinksInPlaceWithoutExpansion() {",
    "vertical readability test name",
)
text = text.replace(old_assertions, new_assertions, 1)
write(path, text)


translations = {
    "en.lproj": (
        "Reset Reading Progress",
        "Reset reading progress for “%@”?",
        "This clears the current reading position and completion progress only. Reading history and statistics are kept.",
        "Reading progress was reset locally, but remote sync failed: %@",
    ),
    "zh-Hans.lproj": (
        "重置阅读进度",
        "将《%@》的阅读进度归零？",
        "只会清除当前阅读位置和完成进度，历史阅读记录与统计不会删除。",
        "阅读进度已在本机归零，但同步到远端失败：%@",
    ),
    "ja.lproj": (
        "読書進捗をリセット",
        "「%@」の読書進捗をリセットしますか？",
        "現在の読書位置と完了進捗のみをリセットします。読書履歴と統計は保持されます。",
        "読書進捗は端末上でリセットされましたが、リモート同期に失敗しました：%@",
    ),
    "ko.lproj": (
        "읽기 진행률 재설정",
        "“%@”의 읽기 진행률을 재설정할까요?",
        "현재 읽기 위치와 완료 진행률만 초기화합니다. 읽기 기록과 통계는 유지됩니다.",
        "읽기 진행률은 기기에서 재설정되었지만 원격 동기화에 실패했습니다: %@",
    ),
}
for locale, values in translations.items():
    loc_path = Path("mreader") / locale / "Localizable.strings"
    loc = loc_path.read_text(encoding="utf-8")
    if '"comic.resetProgress"' not in loc:
        title, confirm, description, failed = values
        loc += f'\n"comic.resetProgress" = "{title}";\n'
        loc += f'"comic.resetProgressConfirm" = "{confirm}";\n'
        loc += f'"comic.resetProgressDescription" = "{description}";\n'
        loc += f'"comic.resetProgressFailed" = "{failed}";\n'
        loc_path.write_text(loc, encoding="utf-8")


# Strong final guards: do not commit a partial source patch.
reader = read("mreader/ReaderView.swift")
engine = read("mreader/OCRBubbleLayoutEngine.swift")
content = read("mreader/ContentView.swift")
comic = read("mreader/ComicBook.swift")
state_tests = read("mreaderTests/ReaderStateMutationTests.swift")
readability_tests = read("mreaderTests/TranslationReadabilityRegressionTests.swift")

assert ".highPriorityGesture(gatedPanGesture)" in reader
assert "DragGesture(minimumDistance: 0)" in reader
assert "arrow.up.left.and.arrow.down.right" not in reader
assert "isExpansionPresented" not in reader
assert reader.count("comic.furthestPageIndex = remoteIndex") == 1
assert engine.count("inlineMinimumFontSize: CGFloat = 2") == 2
assert "status: .needsExpansion" not in engine[engine.find("static func anchoredTranslationLayout"):]
assert "resetProgressRequest = comic" in content
assert "performResetReadingProgress(for comic: ComicBook)" in content
assert "VStack(alignment: .center, spacing: 3)" in content
assert "let selectedFurthest = usesIncoming ? incoming.furthestPageIndex : existing.furthestPageIndex" in comic
assert "final class ReadingProgressResetRegressionTests" in state_tests
assert "testTinyBubbleShrinksBelowPreferredFloorWithoutExpansion" in readability_tests
assert "testVerticalTinyBubbleShrinksInPlaceWithoutExpansion" in readability_tests
assert ".needsExpansion" not in readability_tests
for locale in translations:
    assert '"comic.resetProgress"' in read(str(Path("mreader") / locale / "Localizable.strings"))

print("mobile reader UX patch finalized")
