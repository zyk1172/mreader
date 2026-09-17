from pathlib import Path

path = Path("mreader/ReaderView.swift")
text = path.read_text()

def replace_once(old: str, new: str) -> None:
    global text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"expected exactly one match, found {count}\n--- old ---\n{old[:500]}")
    text = text.replace(old, new, 1)

replace_once(
'''    @State private var isPanelTransitioning = false
    @State private var panelMotionTask: Task<Void, Never>?
    @State private var layoutStore = GuidedPanelLayoutStore()
''',
'''    @State private var isPanelTransitioning = false
    @State private var panelMotionTask: Task<Void, Never>?
    @State private var pageBoundaryPreparationTask: Task<Void, Never>?
    @State private var layoutStore = GuidedPanelLayoutStore()
'''
)

replace_once(
'''        .onDisappear {
            panelMotionTask?.cancel()
            panelMotionTask = nil
            isPanelTransitioning = false
            layoutStore.prefetchTask?.cancel()
''',
'''        .onDisappear {
            panelMotionTask?.cancel()
            panelMotionTask = nil
            pageBoundaryPreparationTask?.cancel()
            pageBoundaryPreparationTask = nil
            isPanelTransitioning = false
            layoutStore.prefetchTask?.cancel()
'''
)

old_move = '''    private func moveToPage(_ pageIndex: Int, enterAtLastPanel: Bool) {
        guard pages.indices.contains(pageIndex) else {
            HapticManager.shared.play(.warning)
            return
        }

        panelMotionTask?.cancel()
        panelMotionTask = nil
        isPanelTransitioning = false
        HapticManager.shared.play(.light)

        let targetPage = pages[pageIndex]
        let targetURL = targetPage.url
        let cachedLayout = layoutStore.entries[targetURL.absoluteString]
        let bufferedImage = ReaderImageCache.shared.cachedImage(
            for: targetURL,
            maxPixelSize: ReaderImageCache.fitScreenMaxPixelSize
        )

        // A page boundary is a two-buffer handoff, not a URL mutation inside the visible
        // LocalImageView. Keep the old page alive while a predecoded N+1 image is already
        // framed on its first/last panel, crossfade them, then let LocalImageView adopt the
        // cached page underneath. No model, decode or disk wait occurs inside the animation.
        if let cached = cachedLayout,
           !cached.layout.panels.isEmpty,
           let bufferedImage {
            let lastPanelIndex = max(cached.layout.panels.count - 1, 0)
            let targetPanelIndex = enterAtLastPanel ? lastPanelIndex : 0
            beginBufferedPageTransition(
                to: pageIndex,
                panelIndex: min(max(targetPanelIndex, 0), lastPanelIndex),
                entry: cached,
                image: bufferedImage
            )
            return
        }

        MReaderLog.reader.notice(
            "guided panel page buffer miss page=\\(pageIndex + 1, privacy: .public) layoutReady=\\(cachedLayout != nil, privacy: .public) imageReady=\\(bufferedImage != nil, privacy: .public)"
        )

        // 预取还没落地：新页先以整页进入，检测完成后由入场动画收到目标分镜。
        layout = nil
        sourceSize = PageGeometryStore.shared.size(for: targetURL) ?? .zero
        cameraFocusOverride = nil
        panelIndex = 0
        enterCurrentPageAtLastPanel = enterAtLastPanel
        isDetecting = true
        layoutStore.appliedPageURL = nil
        currentPageIndex = pageIndex
        scheduleNeighbourPrefetch(around: pageIndex)
    }

'''

new_move = '''    private func moveToPage(_ pageIndex: Int, enterAtLastPanel: Bool) {
        guard pages.indices.contains(pageIndex) else {
            HapticManager.shared.play(.warning)
            return
        }

        panelMotionTask?.cancel()
        panelMotionTask = nil
        pageBoundaryPreparationTask?.cancel()
        pageBoundaryPreparationTask = nil
        isPanelTransitioning = false
        HapticManager.shared.play(.light)

        let targetPage = pages[pageIndex]
        let targetURL = targetPage.url
        let cachedLayout = layoutStore.entries[targetURL.absoluteString]
        let bufferedImage = ReaderImageCache.shared.cachedImage(
            for: targetURL,
            maxPixelSize: ReaderImageCache.fitScreenMaxPixelSize
        )

        // A page boundary is always a two-buffer handoff. Even a layout with zero explicit
        // panels can use contentBounds as its single fallback focus, so there is no reason to
        // expose an intermediate full-page/loading state to the reader.
        if let cached = cachedLayout,
           let bufferedImage {
            let lastPanelIndex = max(cached.layout.panels.count - 1, 0)
            let targetPanelIndex = enterAtLastPanel ? lastPanelIndex : 0
            beginBufferedPageTransition(
                to: pageIndex,
                panelIndex: min(max(targetPanelIndex, 0), lastPanelIndex),
                entry: cached,
                image: bufferedImage
            )
            return
        }

        MReaderLog.reader.notice(
            "guided panel page buffer miss page=\\(pageIndex + 1, privacy: .public) layoutReady=\\(cachedLayout != nil, privacy: .public) imageReady=\\(bufferedImage != nil, privacy: .public)"
        )

        // Do not mutate currentPageIndex on a miss. Keep the current last/first panel visible,
        // prepare the destination behind it, then perform the exact same buffered handoff used
        // by a cache hit. This removes the old visible ProgressView/full-page fallback entirely.
        prepareBufferedPageTransition(
            to: pageIndex,
            enterAtLastPanel: enterAtLastPanel
        )
    }

    private func prepareBufferedPageTransition(
        to pageIndex: Int,
        enterAtLastPanel: Bool
    ) {
        guard pages.indices.contains(pageIndex) else { return }
        let originPageIndex = currentPageIndex
        isPanelTransitioning = true

        pageBoundaryPreparationTask = Task { @MainActor in
            let targetPage = pages[pageIndex]
            let targetURL = targetPage.url
            let identifier = targetURL.absoluteString

            if layoutStore.entries[identifier] == nil {
                await prefetchLayout(at: pageIndex)
            }

            guard !Task.isCancelled,
                  currentPageIndex == originPageIndex,
                  let entry = layoutStore.entries[identifier] else {
                if !Task.isCancelled, currentPageIndex == originPageIndex {
                    isPanelTransitioning = false
                }
                pageBoundaryPreparationTask = nil
                return
            }

            var bufferedImage = ReaderImageCache.shared.cachedImage(
                for: targetURL,
                maxPixelSize: ReaderImageCache.fitScreenMaxPixelSize
            )
            if bufferedImage == nil {
                bufferedImage = await ReaderImageCache.shared.loadImage(
                    for: targetURL,
                    maxPixelSize: ReaderImageCache.fitScreenMaxPixelSize
                )
            }

            guard !Task.isCancelled,
                  currentPageIndex == originPageIndex,
                  let bufferedImage else {
                if !Task.isCancelled, currentPageIndex == originPageIndex {
                    isPanelTransitioning = false
                }
                pageBoundaryPreparationTask = nil
                return
            }

            let lastPanelIndex = max(entry.layout.panels.count - 1, 0)
            let targetPanelIndex = enterAtLastPanel ? lastPanelIndex : 0
            pageBoundaryPreparationTask = nil
            beginBufferedPageTransition(
                to: pageIndex,
                panelIndex: min(max(targetPanelIndex, 0), lastPanelIndex),
                entry: entry,
                image: bufferedImage
            )
        }
    }

'''
replace_once(old_move, new_move)

path.write_text(text)
