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


# ReaderView: newer Komga snapshots own both location fields; zoomed panning wins
# parent page-turn gestures; expansion translations become passive text only.
path = "mreader/ReaderView.swift"
text = read(path)

text = replace_once(
    text,
    '''                    if comic.sourceType == .komga,
                       let remoteProgress = try? await KomgaProvider.remoteReadingProgressSnapshot(for: comic) {
                        let maxIndex = max(0, result.pages.count - 1)
                        comic.furthestPageIndex = min(
                            max(comic.furthestPageIndex, remoteProgress.pageIndex),
                            maxIndex
                        )
                        if remoteProgress.updatedAt > comic.progressUpdatedAt {
                            comic.currentPageIndex = min(remoteProgress.pageIndex, maxIndex)
                            comic.progressUpdatedAt = remoteProgress.updatedAt
                            comic.scrollProgress = 0
                            comic.scrollPageProgress = 0
                        }
                        onComicUpdate(comic)
                    }
''',
    '''                    if comic.sourceType == .komga,
                       let remoteProgress = try? await KomgaProvider.remoteReadingProgressSnapshot(for: comic),
                       remoteProgress.updatedAt > comic.progressUpdatedAt {
                        // Progress is a timestamped state, not a monotonic maximum. A newer
                        // explicit reset to page 0 must not be resurrected by an older local
                        // furthest-page value.
                        let remoteIndex = min(max(remoteProgress.pageIndex, 0), max(0, result.pages.count - 1))
                        comic.currentPageIndex = remoteIndex
                        comic.furthestPageIndex = remoteIndex
                        comic.progressUpdatedAt = remoteProgress.updatedAt
                        comic.scrollProgress = 0
                        comic.scrollPageProgress = 0
                        onComicUpdate(comic)
                    }
''',
    "ReaderContainer remote progress",
)

text = replace_once(
    text,
    '''                    .gesture(zoomGesture)
                    .gesture(gatedPanGesture)''',
    '''                    .gesture(zoomGesture)
                    // 放大后页内平移优先于外层翻页拖拽，避免拖动被父级手势反复截断。
                    .highPriorityGesture(gatedPanGesture)''',
    "zoom pan gesture priority",
)

text = replace_once(
    text,
    '''        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard ReaderGestureGate.isZoomed(scale: scale) else { return }''',
    '''        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard ReaderGestureGate.isZoomed(scale: scale) else { return }''',
    "zoom pan minimum distance",
)

old_renderer = '''    var body: some View {
        Group {
            if layoutStatus == .needsExpansion {
                Button {
                    isExpansionPresented = true
                } label: {
                    ZStack(alignment: .bottomTrailing) {
                        // Keep a real translation preview visible at the readable
                        // floor. The preview may clip, but it must never degrade
                        // into an icon-only card.
                        CoreTextTranslationView(
                            text: fullText,
                            fontSize: fontSize,
                            color: displayMode == .inPlace ? UIColor.label : style.coreTextColor,
                            textOrientation: textOrientation,
                            lineSpacing: 2
                        )
                        .allowsHitTesting(false)

                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(style.coreTextColor.swiftUIColor)
                            .padding(3)
                            .background(.ultraThinMaterial, in: Circle())
                            .padding(2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("ocr.translationNeedsExpansion".localized)
                .accessibilityValue(fullText)
            } else {
                CoreTextTranslationView(
                    text: fullText,
                    fontSize: fontSize,
                    color: displayMode == .inPlace ? UIColor.label : style.coreTextColor,
                    textOrientation: textOrientation,
                    lineSpacing: 2
                )
            }
        }
        .padding(layoutStatus == .needsExpansion ? min(contentPadding, 3) : contentPadding)
        .frame(width: layoutSize.width, height: layoutSize.height)
        .clipped()
        .sheet(isPresented: $isExpansionPresented) {
            NavigationStack {
                ScrollView {
                    Text(fullText)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                        .textSelection(.enabled)
                }
                .navigationTitle("ocr.aiTranslation.navigationTitle".localized)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("nav.done".localized) {
                            isExpansionPresented = false
                        }
                    }
                }
            }
        }
    }
'''
new_renderer = '''    var body: some View {
        // 译文覆盖层始终只是被动绘制。即使极小区域触发 needsExpansion，
        // 也不再生成 Button / Sheet，避免阅读时误触“放大查看”。
        CoreTextTranslationView(
            text: fullText,
            fontSize: fontSize,
            color: displayMode == .inPlace ? UIColor.label : style.coreTextColor,
            textOrientation: textOrientation,
            lineSpacing: 2
        )
        .padding(layoutStatus == .needsExpansion ? min(contentPadding, 3) : contentPadding)
        .frame(width: layoutSize.width, height: layoutSize.height)
        .clipped()
        .allowsHitTesting(false)
    }
'''
text = replace_once(text, old_renderer, new_renderer, "passive translation renderer")
text = text.replace("    @State private var isExpansionPresented = false\n", "", 1)
write(path, text)


# OCR layout: the configured readable size remains the preferred floor. If the
# region is still too small, keep shrinking in place instead of requesting an
# expansion UI. 2pt is the final display floor for pathological bubbles.
path = "mreader/OCRBubbleLayoutEngine.swift"
text = read(path)

old_horizontal_fallback = '''        guard enforcesReadableFloor else {
            let p = effectivePadding(0.1)
            return TranslationLayout(
                rect: safeBounds,
                contentRect: safeBounds.insetBy(dx: p, dy: p),
                fontSize: 0.1,
                contentPadding: p
            )
        }

        // Never continue below the user-selected readability floor. The full
        // canonical translation remains available through the expansion UI.
        let p = effectivePadding(readableFloor)
        return TranslationLayout(
            rect: safeBounds,
            contentRect: safeBounds.insetBy(dx: p, dy: p),
            fontSize: readableFloor,
            contentPadding: p,
            status: .needsExpansion
        )
'''
new_horizontal_fallback = '''        guard enforcesReadableFloor else {
            let p = effectivePadding(0.1)
            return TranslationLayout(
                rect: safeBounds,
                contentRect: safeBounds.insetBy(dx: p, dy: p),
                fontSize: 0.1,
                contentPadding: p
            )
        }

        // The configured readable size is a preference, not a trigger for an
        // interactive magnifier. If it cannot fit, continue shrinking in place.
        let inlineMinimumFontSize: CGFloat = 2
        if let inlineFloor = fittedLayout(fontSize: inlineMinimumFontSize) {
            var lower = inlineMinimumFontSize
            var upper = readableFloor
            for _ in 0..<14 {
                let candidate = (lower + upper) / 2
                if fittedLayout(fontSize: candidate) != nil {
                    lower = candidate
                } else {
                    upper = candidate
                }
            }
            return fittedLayout(fontSize: lower) ?? inlineFloor
        }

        let p = effectivePadding(inlineMinimumFontSize)
        return TranslationLayout(
            rect: safeBounds,
            contentRect: safeBounds.insetBy(dx: p, dy: p),
            fontSize: inlineMinimumFontSize,
            contentPadding: p
        )
'''
text = replace_once(text, old_horizontal_fallback, new_horizontal_fallback, "horizontal translation fallback")

old_vertical_fallback = '''        let p = effectivePadding(readableFloor)
        return TranslationLayout(
            rect: safeBounds,
            contentRect: safeBounds.insetBy(dx: p, dy: p),
            fontSize: readableFloor,
            contentPadding: p,
            status: .needsExpansion
        )
'''
new_vertical_fallback = '''        let inlineMinimumFontSize: CGFloat = 2
        if let inlineFloor = fittedLayout(fontSize: inlineMinimumFontSize) {
            var lower = inlineMinimumFontSize
            var upper = readableFloor
            for _ in 0..<16 {
                let candidate = (lower + upper) / 2
                if fittedLayout(fontSize: candidate) != nil {
                    lower = candidate
                } else {
                    upper = candidate
                }
            }
            return fittedLayout(fontSize: lower) ?? inlineFloor
        }

        let p = effectivePadding(inlineMinimumFontSize)
        return TranslationLayout(
            rect: safeBounds,
            contentRect: safeBounds.insetBy(dx: p, dy: p),
            fontSize: inlineMinimumFontSize,
            contentPadding: p
        )
'''
# There are two needsExpansion fallbacks in the file; at this point the horizontal
# one was already replaced, so the remaining exact block is the vertical path.
text = replace_once(text, old_vertical_fallback, new_vertical_fallback, "vertical translation fallback")
write(path, text)


# ContentView: center today's three metrics and add per-comic reset with Komga sync.
path = "mreader/ContentView.swift"
text = read(path)
text = replace_once(
    text,
    '''    @State private var deleteRequest: DeleteRequest?
    @State private var hideKomgaRequest: ComicBook?
''',
    '''    @State private var deleteRequest: DeleteRequest?
    @State private var hideKomgaRequest: ComicBook?
    @State private var resetProgressRequest: ComicBook?
''',
    "reset progress state",
)

text = replace_once(
    text,
    '''            .modifier(alertModifiers)
            .task(id: library.libraryLoadIssues) {
''',
    '''            .modifier(alertModifiers)
            .confirmationDialog(
                resetProgressRequest.map { "comic.resetProgressConfirm".localizedFormat($0.title) }
                    ?? "comic.resetProgress".localized,
                isPresented: Binding(
                    get: { resetProgressRequest != nil },
                    set: { if !$0 { resetProgressRequest = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("comic.resetProgress".localized, role: .destructive) {
                    if let comic = resetProgressRequest {
                        resetProgressRequest = nil
                        performResetReadingProgress(for: comic)
                    }
                }
                Button("nav.cancel".localized, role: .cancel) {
                    resetProgressRequest = nil
                }
            } message: {
                Text("comic.resetProgressDescription".localized)
            }
            .task(id: library.libraryLoadIssues) {
''',
    "reset progress confirmation",
)

text = replace_once(
    text,
    '''        if !ComicReadingProgress.isFinished(comic) {
            Button {
                HapticManager.shared.play(.medium)
                library.markAsRead(id: comic.id)
            } label: {
                Label("comic.markAsRead".localized, systemImage: "checkmark.circle")
            }
        }

        Button {
            HapticManager.shared.play(.medium)
            library.rebuildThumbnail(for: comic.id)
''',
    '''        if !ComicReadingProgress.isFinished(comic) {
            Button {
                HapticManager.shared.play(.medium)
                library.markAsRead(id: comic.id)
            } label: {
                Label("comic.markAsRead".localized, systemImage: "checkmark.circle")
            }
        }

        Button(role: .destructive) {
            HapticManager.shared.play(.medium)
            resetProgressRequest = comic
        } label: {
            Label("comic.resetProgress".localized, systemImage: "arrow.counterclockwise")
        }
        .disabled(!comic.hasBeenOpened
                  && comic.currentPageIndex == 0
                  && comic.furthestPageIndex == 0
                  && comic.scrollProgress == 0
                  && comic.scrollPageProgress == 0)

        Button {
            HapticManager.shared.play(.medium)
            library.rebuildThumbnail(for: comic.id)
''',
    "reset progress menu item",
)

text = replace_once(
    text,
    '''    private func performConfirmedDelete() {
''',
    '''    private func performResetReadingProgress(for comic: ComicBook) {
        var updated = comic
        updated.currentPageIndex = 0
        updated.furthestPageIndex = 0
        updated.scrollProgress = 0
        updated.scrollPageProgress = 0
        updated.progressUpdatedAt = Date()
        updated.hasBeenOpened = false
        updated.lastReadAt = .distantPast

        if uiTestingFixtureComic?.id == updated.id {
            uiTestingFixtureComic = updated
        } else {
            library.update(updated)
        }
        HapticManager.shared.play(.success)

        // Komga has a second copy of reading progress. Reset it too. A failed
        // network write does not undo the local reset; the new local timestamp
        // prevents stale remote progress from winning the next merge.
        guard updated.sourceType == .komga else { return }
        Task {
            do {
                try await KomgaProvider.updateReadProgress(for: updated)
            } catch {
                HapticManager.shared.play(.error)
                importError = "comic.resetProgressFailed".localizedFormat(error.localizedDescription)
            }
        }
    }

    private func performConfirmedDelete() {
''',
    "reset progress implementation",
)

text = replace_once(
    text,
    '''        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .monospacedDigit()
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(FitnessPalette.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
''',
    '''        VStack(alignment: .center, spacing: 3) {
            Text(value)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .monospacedDigit()
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(FitnessPalette.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, alignment: .center)
''',
    "today metrics centering",
)
write(path, text)


# Sync merge: the newest progress snapshot owns both current and furthest page.
# A monotonic max would make an intentional reset impossible to synchronize.
path = "mreader/ComicBook.swift"
text = read(path)
text = replace_once(
    text,
    '''        let pageLimit = max(0, totalPages - 1)
        let usesIncoming = incoming.progressUpdatedAt > existing.progressUpdatedAt
        let selectedPage = usesIncoming ? incoming.currentPageIndex : existing.currentPageIndex
        return Resolution(
            currentPageIndex: min(max(selectedPage, 0), pageLimit),
            furthestPageIndex: min(
                max(
                    max(existing.furthestPageIndex, incoming.furthestPageIndex),
                    max(existing.currentPageIndex, incoming.currentPageIndex)
                ),
                pageLimit
            ),
            progressUpdatedAt: max(existing.progressUpdatedAt, incoming.progressUpdatedAt),
            usesIncomingLocation: usesIncoming
        )
''',
    '''        let pageLimit = max(0, totalPages - 1)
        let usesIncoming = incoming.progressUpdatedAt > existing.progressUpdatedAt
        let selectedPage = usesIncoming ? incoming.currentPageIndex : existing.currentPageIndex
        let selectedFurthest = usesIncoming ? incoming.furthestPageIndex : existing.furthestPageIndex
        return Resolution(
            currentPageIndex: min(max(selectedPage, 0), pageLimit),
            furthestPageIndex: min(max(selectedFurthest, selectedPage, 0), pageLimit),
            progressUpdatedAt: max(existing.progressUpdatedAt, incoming.progressUpdatedAt),
            usesIncomingLocation: usesIncoming
        )
''',
    "reading progress merge policy",
)
write(path, text)


# Regression tests for reset freshness.
path = "mreaderTests/ReaderStateMutationTests.swift"
text = read(path)
if "final class ReadingProgressResetRegressionTests" not in text:
    text += '''\n\nfinal class ReadingProgressResetRegressionTests: XCTestCase {
    func testNewerResetCanReduceCurrentAndFurthestProgressToZero() {
        let older = Date(timeIntervalSince1970: 10)
        let newer = Date(timeIntervalSince1970: 20)
        let existing = ComicBook(
            title: "Existing",
            bookmarkData: Data(),
            totalPages: 100,
            currentPageIndex: 42,
            furthestPageIndex: 70,
            progressUpdatedAt: older,
            hasBeenOpened: true
        )
        let incoming = ComicBook(
            id: existing.id,
            title: existing.title,
            bookmarkData: existing.bookmarkData,
            totalPages: 100,
            currentPageIndex: 0,
            furthestPageIndex: 0,
            progressUpdatedAt: newer,
            hasBeenOpened: false
        )

        let resolved = ReadingProgressMergePolicy.resolve(existing: existing, incoming: incoming, totalPages: 100)
        XCTAssertTrue(resolved.usesIncomingLocation)
        XCTAssertEqual(resolved.currentPageIndex, 0)
        XCTAssertEqual(resolved.furthestPageIndex, 0)
        XCTAssertEqual(resolved.progressUpdatedAt, newer)
    }

    func testOlderProgressCannotResurrectNewerReset() {
        let resetAt = Date(timeIntervalSince1970: 30)
        let staleAt = Date(timeIntervalSince1970: 20)
        let reset = ComicBook(
            title: "Reset",
            bookmarkData: Data(),
            totalPages: 80,
            currentPageIndex: 0,
            furthestPageIndex: 0,
            progressUpdatedAt: resetAt,
            hasBeenOpened: false
        )
        let stale = ComicBook(
            id: reset.id,
            title: reset.title,
            bookmarkData: reset.bookmarkData,
            totalPages: 80,
            currentPageIndex: 35,
            furthestPageIndex: 60,
            progressUpdatedAt: staleAt,
            hasBeenOpened: true
        )

        let resolved = ReadingProgressMergePolicy.resolve(existing: reset, incoming: stale, totalPages: 80)
        XCTAssertFalse(resolved.usesIncomingLocation)
        XCTAssertEqual(resolved.currentPageIndex, 0)
        XCTAssertEqual(resolved.furthestPageIndex, 0)
        XCTAssertEqual(resolved.progressUpdatedAt, resetAt)
    }
}
'''
write(path, text)


# Existing readability tests should now verify in-place shrinking rather than
# the removed expansion behavior.
path = "mreaderTests/TranslationReadabilityRegressionTests.swift"
text = read(path)
text = replace_once(
    text,
    "    func testTinyBubbleStopsAtReadableFloorAndRequiresExpansion() {",
    "    func testTinyBubbleShrinksBelowPreferredFloorWithoutExpansion() {",
    "horizontal readability test name",
)
text = replace_once(
    text,
    '''        XCTAssertGreaterThanOrEqual(choice.layout.fontSize, floor)
        XCTAssertEqual(choice.layout.status, .needsExpansion)
''',
    '''        XCTAssertLessThan(choice.layout.fontSize, floor)
        XCTAssertGreaterThanOrEqual(choice.layout.fontSize, 2)
        XCTAssertEqual(choice.layout.status, .fitted)
''',
    "horizontal readability assertions",
)
text = replace_once(
    text,
    "    func testVerticalTinyBubbleNeverFallsBackToMicroscopicText() {",
    "    func testVerticalTinyBubbleShrinksInPlaceWithoutExpansion() {",
    "vertical readability test name",
)
text = replace_once(
    text,
    '''        XCTAssertGreaterThanOrEqual(choice.layout.fontSize, floor)
        XCTAssertEqual(choice.layout.status, .needsExpansion)
''',
    '''        XCTAssertLessThan(choice.layout.fontSize, floor)
        XCTAssertGreaterThanOrEqual(choice.layout.fontSize, 2)
        XCTAssertEqual(choice.layout.status, .fitted)
''',
    "vertical readability assertions",
)
write(path, text)


# Localizations for the per-comic reset action.
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


# Guard against partial application before the workflow commits anything.
reader = read("mreader/ReaderView.swift")
engine = read("mreader/OCRBubbleLayoutEngine.swift")
content = read("mreader/ContentView.swift")
comic = read("mreader/ComicBook.swift")
assert ".highPriorityGesture(gatedPanGesture)" in reader
assert "DragGesture(minimumDistance: 0)" in reader
assert "arrow.up.left.and.arrow.down.right" not in reader
assert "isExpansionPresented" not in reader
assert "inlineMinimumFontSize: CGFloat = 2" in engine
assert "resetProgressRequest = comic" in content
assert "VStack(alignment: .center, spacing: 3)" in content
assert "let selectedFurthest = usesIncoming ? incoming.furthestPageIndex : existing.furthestPageIndex" in comic
print("mobile reader UX patch applied")
