from pathlib import Path


def read(path: str) -> str:
    return Path(path).read_text(encoding="utf-8")


def write(path: str, text: str) -> None:
    Path(path).write_text(text, encoding="utf-8")


def replace_exact(path: str, old: str, new: str, label: str, count: int = 1) -> None:
    text = read(path)
    actual = text.count(old)
    if actual != count:
        raise SystemExit(f"{label}: expected {count} matches, found {actual}")
    write(path, text.replace(old, new))


# 1) Keep reader navigation scoped to the series that opened it.
path = "mreader/ContentView.swift"
replace_exact(
    path,
    "    @State private var selectedReaderComic: ComicBook?\n",
    "    @State private var selectedReaderComic: ComicBook?\n    @State private var selectedSeriesReaderComic: ComicBook?\n",
    "series reader state",
)

# 4) Move each large title onto the selected tab's own content instead of the TabView wrapper.
replace_exact(
    path,
    "            shelfRootContent\n            .navigationTitle(navigationTitle)\n            .navigationDestination(item: $selectedReaderComic) { comic in\n",
    "            shelfRootContent\n            .navigationDestination(item: $selectedReaderComic) { comic in\n",
    "remove shared tab title",
)

old_tabs = '''        TabView(selection: $selectedPage) {
            shelfPageContent(for: .continueReading)
                .tabItem {
                    Label("tab.continueReading".localized, systemImage: "book")
                        .accessibilityIdentifier("mreader.tab.continueReading")
                }
                .tag(MainShelfPage.continueReading)

            shelfPageContent(for: .library)
                .tabItem {
                    Label("tab.library".localized, systemImage: "books.vertical")
                        .accessibilityIdentifier("mreader.tab.library")
                }
                .tag(MainShelfPage.library)

            shelfPageContent(for: .statistics)
                .tabItem {
                    Label("tab.statistics".localized, systemImage: "chart.bar.doc.horizontal")
                        .accessibilityIdentifier("mreader.tab.statistics")
                }
                .tag(MainShelfPage.statistics)
        }
'''
new_tabs = '''        TabView(selection: $selectedPage) {
            shelfPageContent(for: .continueReading)
                .navigationTitle("tab.continueReading".localized)
                .navigationBarTitleDisplayMode(.large)
                .tabItem {
                    Label("tab.continueReading".localized, systemImage: "book")
                        .accessibilityIdentifier("mreader.tab.continueReading")
                }
                .tag(MainShelfPage.continueReading)

            shelfPageContent(for: .library)
                .navigationTitle("shelf.title".localized)
                .navigationBarTitleDisplayMode(.large)
                .tabItem {
                    Label("tab.library".localized, systemImage: "books.vertical")
                        .accessibilityIdentifier("mreader.tab.library")
                }
                .tag(MainShelfPage.library)

            shelfPageContent(for: .statistics)
                .navigationTitle("tab.statistics".localized)
                .navigationBarTitleDisplayMode(.large)
                .tabItem {
                    Label("tab.statistics".localized, systemImage: "chart.bar.doc.horizontal")
                        .accessibilityIdentifier("mreader.tab.statistics")
                }
                .tag(MainShelfPage.statistics)
        }
'''
replace_exact(path, old_tabs, new_tabs, "per-tab navigation titles")

old_nav_title = '''    private var navigationTitle: String {
        switch selectedPage {
        case .continueReading:
            return "tab.continueReading".localized
        case .library:
            return "shelf.title".localized
        case .statistics:
            return "tab.statistics".localized
        }
    }

'''
replace_exact(path, old_nav_title, "", "remove dynamic navigation title")

replace_exact(
    path,
    '''                    } onOpen: { comic in
                        openReader(comic)
                    } managementMenu: { comic in
''',
    '''                    } onOpen: { comic in
                        openSeriesReader(comic)
                    } managementMenu: { comic in
''',
    "series open routing",
    count=2,
)

replace_exact(
    path,
    '''                    }
                    .navigationTransition(.zoom(sourceID: series.id, in: seriesAnimationNamespace))
''',
    '''                    }
                    .navigationDestination(item: $selectedSeriesReaderComic) { comic in
                        readerDestination(for: comic)
                            .transaction { transaction in
                                transaction.animation = nil
                                transaction.disablesAnimations = true
                            }
                    }
                    .navigationTransition(.zoom(sourceID: series.id, in: seriesAnimationNamespace))
''',
    "series scoped reader destination",
    count=2,
)

replace_exact(
    path,
    '''    private func openReader(_ comic: ComicBook) {
        if comic.isLocked {
            authenticateLockedComic(comic) {
                openAuthorizedReader(comic)
            }
            return
        }
        openAuthorizedReader(comic)
    }

    private func openAuthorizedReader(_ comic: ComicBook) {
        RemotePagePrefetcher.shared.cancelPreviewForNonOpened(comicID: comic.id)
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            selectedReaderComic = comic
        }
    }
''',
    '''    private func openReader(_ comic: ComicBook) {
        if comic.isLocked {
            authenticateLockedComic(comic) {
                openAuthorizedReader(comic)
            }
            return
        }
        openAuthorizedReader(comic)
    }

    private func openSeriesReader(_ comic: ComicBook) {
        if comic.isLocked {
            authenticateLockedComic(comic) {
                openAuthorizedSeriesReader(comic)
            }
            return
        }
        openAuthorizedSeriesReader(comic)
    }

    private func openAuthorizedReader(_ comic: ComicBook) {
        RemotePagePrefetcher.shared.cancelPreviewForNonOpened(comicID: comic.id)
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            selectedReaderComic = comic
        }
    }

    private func openAuthorizedSeriesReader(_ comic: ComicBook) {
        RemotePagePrefetcher.shared.cancelPreviewForNonOpened(comicID: comic.id)
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            selectedSeriesReaderComic = comic
        }
    }
''',
    "series reader open helpers",
)

# 3) The library store must honor timestamped resets instead of re-maxing furthest progress.
path = "mreader/ComicLibraryStore.swift"
old_update = '''    func update(_ comic: ComicBook) {
        guard let index = comics.firstIndex(where: { $0.id == comic.id }) else { return }
        let existing = comics[index]
        var merged = comic
        merged.currentPageIndex = min(max(comic.currentPageIndex, 0), max(0, comic.totalPages - 1))
        merged.furthestPageIndex = min(
            max(existing.furthestPageIndex, max(comic.furthestPageIndex, merged.currentPageIndex)),
            max(0, comic.totalPages - 1)
        )
        merged.progressUpdatedAt = max(existing.progressUpdatedAt, comic.progressUpdatedAt)
        merged.metadataUpdatedAt = max(existing.metadataUpdatedAt, comic.metadataUpdatedAt)
        if Self.syncMetadataChanged(existing: existing, incoming: comic),
           comic.metadataUpdatedAt <= existing.metadataUpdatedAt {
            merged.metadataUpdatedAt = Date()
        }
        merged.hasBeenOpened = existing.hasBeenOpened || comic.hasBeenOpened
        comics[index] = merged
        sortAndSave()
        if merged.sourceType == .komga {
            scheduleKomgaProgressSync(for: merged)
        }
    }
'''
new_update = '''    func update(_ comic: ComicBook) {
        guard let index = comics.firstIndex(where: { $0.id == comic.id }) else { return }
        let existing = comics[index]
        var merged = comic
        let progressResolution = ReadingProgressMergePolicy.resolve(
            existing: existing,
            incoming: comic,
            totalPages: comic.totalPages
        )
        merged.currentPageIndex = progressResolution.currentPageIndex
        merged.furthestPageIndex = progressResolution.furthestPageIndex
        merged.progressUpdatedAt = progressResolution.progressUpdatedAt
        if progressResolution.usesIncomingLocation {
            // A newer explicit reset is a real state transition. Do not OR/max
            // the old opened/furthest state back into the new zero-progress state.
            merged.hasBeenOpened = comic.hasBeenOpened
            merged.scrollProgress = comic.scrollProgress
            merged.scrollPageProgress = comic.scrollPageProgress
            merged.lastReadAt = comic.lastReadAt
        } else {
            merged.hasBeenOpened = existing.hasBeenOpened
            merged.scrollProgress = existing.scrollProgress
            merged.scrollPageProgress = existing.scrollPageProgress
            merged.lastReadAt = existing.lastReadAt
        }
        merged.metadataUpdatedAt = max(existing.metadataUpdatedAt, comic.metadataUpdatedAt)
        if Self.syncMetadataChanged(existing: existing, incoming: comic),
           comic.metadataUpdatedAt <= existing.metadataUpdatedAt {
            merged.metadataUpdatedAt = Date()
        }
        comics[index] = merged
        sortAndSave()
        if merged.sourceType == .komga {
            scheduleKomgaProgressSync(for: merged)
        }
    }
'''
replace_exact(path, old_update, new_update, "timestamp-aware library update")

replace_exact(
    path,
    '''    private func syncKomgaProgressNow(for comic: ComicBook) async {
        do {
            try await KomgaProvider.updateReadProgress(for: comic)
        } catch {
''',
    '''    private func syncKomgaProgressNow(for comic: ComicBook) async {
        do {
            if !comic.hasBeenOpened,
               comic.currentPageIndex == 0,
               comic.furthestPageIndex == 0,
               comic.scrollProgress == 0,
               comic.scrollPageProgress == 0 {
                // A reset must stay incomplete even for a one-page Komga book.
                try await KomgaProvider.resetReadProgress(for: comic)
            } else {
                try await KomgaProvider.updateReadProgress(for: comic)
            }
        } catch {
''',
    "Komga reset-safe delayed sync",
)

# 2 + 5) Remove obsolete compact expansion previews and harden two-finger dismiss.
path = "mreader/ReaderView.swift"
replace_exact(
    path,
    '''nonisolated enum ReaderGestureGate {
    static let zoomedScaleThreshold: CGFloat = 1.05

    static func isZoomed(scale: CGFloat) -> Bool {
        scale > zoomedScaleThreshold
    }

    static func allowsSinglePageTurn(isZoomed: Bool) -> Bool {
        !isZoomed
    }

    static func allowsDoublePageTurn(zoomedPageIndexes: Set<Int>) -> Bool {
        zoomedPageIndexes.isEmpty
    }
}
''',
    '''nonisolated enum ReaderGestureGate {
    static let zoomedScaleThreshold: CGFloat = 1.05

    static func isZoomed(scale: CGFloat) -> Bool {
        scale > zoomedScaleThreshold
    }

    static func allowsSinglePageTurn(isZoomed: Bool) -> Bool {
        !isZoomed
    }

    static func allowsDoublePageTurn(zoomedPageIndexes: Set<Int>) -> Bool {
        zoomedPageIndexes.isEmpty
    }
}

/// Downward reader dismissal is deliberately a two-finger-only gesture. The
/// UIKit recognizer can remain in a recognized state after one finger of a
/// two-finger gesture lifts, so every active update must revalidate touch count.
nonisolated enum ReaderDismissGestureGate {
    static let requiredTouchCount = 2

    static func hasRequiredTouches(_ touchCount: Int) -> Bool {
        touchCount == requiredTouchCount
    }

    static func isMostlyDownward(translation: CGPoint) -> Bool {
        translation.y > 0 && abs(translation.x) < max(translation.y * 0.8, 40)
    }

    static func shouldBegin(touchCount: Int, velocity: CGPoint) -> Bool {
        hasRequiredTouches(touchCount)
            && velocity.y > 0
            && abs(velocity.y) > abs(velocity.x)
    }
}
''',
    "dismiss gesture gate",
)

old_coordinator_fields = '''        let recognizer = UIPanGestureRecognizer()
        private var hasTriggered = false
'''
new_coordinator_fields = '''        let recognizer = UIPanGestureRecognizer()
        private var hasTriggered = false
        private var maintainedExactlyTwoTouches = false
'''
replace_exact(path, old_coordinator_fields, new_coordinator_fields, "dismiss recognizer state")

old_handle = '''        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let translation = recognizer.translation(in: view)
            let velocity = recognizer.velocity(in: view)
            switch recognizer.state {
            case .began:
                hasTriggered = false
            case .changed:
                let isMostlyVertical = translation.y > 0 && abs(translation.x) < max(translation.y * 0.8, 40)
                onProgress(isMostlyVertical ? min(max(translation.y / 320, 0), 1) : 0)
                guard !hasTriggered else { return }
                let isDownward = translation.y > 110 && velocity.y > 220
                if isDownward && isMostlyVertical {
                    hasTriggered = true
                    onSwipe()
                }
            case .ended:
                guard !hasTriggered else { return }
                let isMostlyVertical = translation.y > 0 && abs(translation.x) < max(translation.y * 0.8, 40)
                let shouldDismiss = isMostlyVertical && (translation.y > 160 || velocity.y > 720)
                if shouldDismiss {
                    hasTriggered = true
                    onSwipe()
                } else {
                    onCancel()
                }
            case .cancelled, .failed:
                hasTriggered = false
                onCancel()
            default:
                break
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
'''
new_handle = '''        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let translation = recognizer.translation(in: view)
            let velocity = recognizer.velocity(in: view)
            switch recognizer.state {
            case .began:
                hasTriggered = false
                maintainedExactlyTwoTouches = ReaderDismissGestureGate.hasRequiredTouches(recognizer.numberOfTouches)
                guard maintainedExactlyTwoTouches else {
                    onCancel()
                    return
                }
            case .changed:
                guard maintainedExactlyTwoTouches,
                      ReaderDismissGestureGate.hasRequiredTouches(recognizer.numberOfTouches) else {
                    maintainedExactlyTwoTouches = false
                    hasTriggered = false
                    onCancel()
                    return
                }
                let isMostlyVertical = ReaderDismissGestureGate.isMostlyDownward(translation: translation)
                onProgress(isMostlyVertical ? min(max(translation.y / 320, 0), 1) : 0)
                guard !hasTriggered else { return }
                let isDownward = translation.y > 110 && velocity.y > 220
                if isDownward && isMostlyVertical {
                    hasTriggered = true
                    onSwipe()
                }
            case .ended:
                guard !hasTriggered else { return }
                // A recognizer whose touch count fell from two to one can end
                // while that remaining finger is still moving. Never treat that
                // transition as a two-finger dismissal.
                guard maintainedExactlyTwoTouches, recognizer.numberOfTouches == 0 else {
                    maintainedExactlyTwoTouches = false
                    onCancel()
                    return
                }
                let isMostlyVertical = ReaderDismissGestureGate.isMostlyDownward(translation: translation)
                let shouldDismiss = isMostlyVertical && (translation.y > 160 || velocity.y > 720)
                maintainedExactlyTwoTouches = false
                if shouldDismiss {
                    hasTriggered = true
                    onSwipe()
                } else {
                    onCancel()
                }
            case .cancelled, .failed:
                hasTriggered = false
                maintainedExactlyTwoTouches = false
                onCancel()
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === recognizer, let view = recognizer.view else { return true }
            return ReaderDismissGestureGate.shouldBegin(
                touchCount: recognizer.numberOfTouches,
                velocity: recognizer.velocity(in: view)
            )
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
'''
replace_exact(path, old_handle, new_handle, "strict two-finger dismiss lifecycle")

old_layout_collision = '''            let collisionRemains = occupiedRects.contains { $0.intersects(rect) }
            let escapedBubble = item.surfaceStyle == .detectedBubble
                && !movementBounds.insetBy(dx: -0.5, dy: -0.5).contains(rect)
            let layoutStatus: OCRBubbleLayoutEngine.TranslationLayoutStatus =
                item.layoutStatus == .needsExpansion || collisionRemains || escapedBubble
                    ? .needsExpansion
                    : .fitted

            let presentationRect: CGRect
            if layoutStatus == .needsExpansion {
                let compactPreview = TranslationOverflowPresentationPolicy.compactPreviewRect(
                    sourceRect: mappedSourceRect,
                    allowedBounds: movementBounds,
                    orientation: item.textOrientation
                )
                presentationRect = OCRBubbleLayoutEngine.nonOverlappingRect(
                    compactPreview,
                    anchor: CGPoint(x: mappedSourceRect.midX, y: mappedSourceRect.midY),
                    occupiedRects: occupiedRects,
                    bounds: movementBounds,
                    margin: 0
                )
            } else {
                presentationRect = rect
            }

            occupiedRects.append(presentationRect.insetBy(dx: -4, dy: -4))
'''
new_layout_collision = '''            // The expansion UI was removed. Collision handling must therefore
            // never collapse a fitted translation into the old compact preview:
            // that preview becomes an opaque material card with clipped/no text.
            let presentationRect = rect
            let layoutStatus = item.layoutStatus == .needsExpansion
                ? OCRBubbleLayoutEngine.TranslationLayoutStatus.fitted
                : item.layoutStatus

            occupiedRects.append(presentationRect.insetBy(dx: -4, dy: -4))
'''
replace_exact(path, old_layout_collision, new_layout_collision, "remove obsolete compact translation preview")

replace_exact(
    path,
    "    static let layoutRevision = 1\n",
    "    static let layoutRevision = 2\n",
    "translation layout cache revision",
)

old_surface = '''    @ViewBuilder
    var body: some View {
        if layoutStatus == .needsExpansion {
            // Overflow is a compact, low-obstruction preview. The full text is
            // opened only after the user taps this specific region.
            RoundedRectangle(cornerRadius: min(max(surfaceStyle.cornerRadius * 0.6, 4), 8), style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: min(max(surfaceStyle.cornerRadius * 0.6, 4), 8), style: .continuous)
                        .fill(Color.white.opacity(0.18))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: min(max(surfaceStyle.cornerRadius * 0.6, 4), 8), style: .continuous)
                        .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.6)
                }
                .frame(width: layoutSize.width, height: layoutSize.height)
        } else {
            switch displayMode {
            case .inPlace:
                RoundedRectangle(cornerRadius: max(surfaceStyle.cornerRadius * 0.55, 3), style: .continuous)
                    .fill(Color.white.opacity(0.94))
                    .frame(width: layoutSize.width, height: layoutSize.height)
            case .assistOverlay:
                RoundedRectangle(cornerRadius: surfaceStyle.cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: surfaceStyle.cornerRadius, style: .continuous)
                            .fill(Color.white.opacity(surfaceStyle.backgroundOpacity))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: surfaceStyle.cornerRadius, style: .continuous)
                            .strokeBorder(Color.white.opacity(surfaceStyle.borderOpacity), lineWidth: 0.75)
                            .shadow(color: .black.opacity(0.34), radius: 0.8, y: 0.6)
                    }
                    .frame(width: layoutSize.width, height: layoutSize.height)
            case .annotation:
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.thinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.white.opacity(0.30))
                    }
                    .frame(width: layoutSize.width, height: layoutSize.height)
            }
        }
    }
'''
new_surface = '''    @ViewBuilder
    var body: some View {
        // There is no expansion interaction anymore, so every translation uses
        // its normal inline surface. Never draw the legacy grey preview card.
        switch displayMode {
        case .inPlace:
            RoundedRectangle(cornerRadius: max(surfaceStyle.cornerRadius * 0.55, 3), style: .continuous)
                .fill(Color.white.opacity(0.94))
                .frame(width: layoutSize.width, height: layoutSize.height)
        case .assistOverlay:
            RoundedRectangle(cornerRadius: surfaceStyle.cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: surfaceStyle.cornerRadius, style: .continuous)
                        .fill(Color.white.opacity(surfaceStyle.backgroundOpacity))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: surfaceStyle.cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(surfaceStyle.borderOpacity), lineWidth: 0.75)
                        .shadow(color: .black.opacity(0.34), radius: 0.8, y: 0.6)
                }
                .frame(width: layoutSize.width, height: layoutSize.height)
        case .annotation:
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(.thinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white.opacity(0.30))
                }
                .frame(width: layoutSize.width, height: layoutSize.height)
        }
    }
'''
replace_exact(path, old_surface, new_surface, "remove expansion surface")

replace_exact(
    path,
    '''        // 译文覆盖层始终只是被动绘制。即使极小区域触发 needsExpansion，
        // 也不再生成 Button / Sheet，避免阅读时误触“放大查看”。
''',
    '''        // 译文覆盖层始终只是被动绘制，不生成 Button / Sheet。
''',
    "translation renderer comment",
)
replace_exact(
    path,
    "        .padding(layoutStatus == .needsExpansion ? min(contentPadding, 3) : contentPadding)\n",
    "        .padding(contentPadding)\n",
    "translation inline padding",
)

# Tests: prove two-finger gate and keep the existing reset regression contract.
path = "mreaderTests/ReaderStateMutationTests.swift"
text = read(path)
needle = '''    func testComicMutationProducesTheValueThatPersistenceReceives() {
'''
insert = '''    func testDismissGestureRequiresExactlyTwoTouches() {
        XCTAssertFalse(ReaderDismissGestureGate.hasRequiredTouches(1))
        XCTAssertTrue(ReaderDismissGestureGate.hasRequiredTouches(2))
        XCTAssertFalse(ReaderDismissGestureGate.hasRequiredTouches(3))

        XCTAssertFalse(
            ReaderDismissGestureGate.shouldBegin(
                touchCount: 1,
                velocity: CGPoint(x: 0, y: 900)
            )
        )
        XCTAssertTrue(
            ReaderDismissGestureGate.shouldBegin(
                touchCount: 2,
                velocity: CGPoint(x: 20, y: 900)
            )
        )
        XCTAssertFalse(
            ReaderDismissGestureGate.shouldBegin(
                touchCount: 2,
                velocity: CGPoint(x: 900, y: 20)
            )
        )
        XCTAssertFalse(
            ReaderDismissGestureGate.isMostlyDownward(
                translation: CGPoint(x: 80, y: 40)
            )
        )
    }

'''
if text.count(needle) != 1:
    raise SystemExit("dismiss gesture test insertion point missing")
text = text.replace(needle, insert + needle, 1)
write(path, text)

# Add a regression test that zero progress maps to a zero statistics bar.
path = "mreaderTests/ReadingActivityStoreTests.swift"
text = read(path)
append = '''

final class ReadingProgressDisplayRegressionTests: XCTestCase {
    func testResetComicReportsZeroCompletedPages() {
        let comic = ComicBook(
            title: "Reset display",
            bookmarkData: Data(),
            totalPages: 120,
            currentPageIndex: 0,
            furthestPageIndex: 0,
            progressUpdatedAt: Date(),
            hasBeenOpened: false,
            scrollProgress: 0,
            scrollPageProgress: 0,
            lastReadAt: .distantPast
        )
        XCTAssertEqual(ComicReadingProgress.completedPages(for: comic), 0)
        XCTAssertFalse(ComicReadingProgress.isFinished(comic))
    }
}
'''
if "final class ReadingProgressDisplayRegressionTests" not in text:
    text += append
write(path, text)

print("mobile reader regression patch applied")
