from pathlib import Path

path = Path("mreader/ReaderView.swift")
text = path.read_text()


def replace_once(old: str, new: str, label: str) -> None:
    global text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    text = text.replace(old, new, 1)


replace_once(
'''        mangaVisionPreanalysisTask?.cancel()
        mangaVisionPreanalysisTask = nil
        // Guided Panel 不再走这条预分析：它由 GuidedPanelReader 自己的邻页预取接管
        // （那边会连着布局与推理一起预热，而且不会在翻页时被取消）。这里继续提交只会
        // 产生一份每次翻页都被取消、几乎跑不完的任务。
        let shouldPreanalyze = comic.isAutoOCRMagnificationEnabled
            || comic.isAutoTranslationEnabled
        if shouldPreanalyze {
            let comicID = comic.id
            let pages = manager.pages
            // Feed the same already-computed Reader prefetch ordering into Manga Vision.
            // The service itself caps work at three pages, so this can never expand to a book scan.
            let visionIndices = [index] + preferredIndices
            mangaVisionPreanalysisTask = Task(priority: .utility) {
                await MangaVisionService.shared.preanalyze(
                    comicID: comicID,
                    pages: pages,
                    indices: visionIndices
                )
            }
        }
''',
'''        mangaVisionPreanalysisTask?.cancel()
        mangaVisionPreanalysisTask = nil
        // Guided Panel needs model output before the page boundary, not after it. Run the
        // lightweight model-sized ImageIO preanalysis in parallel with the normal 4096px
        // display-image preloader so N+1/N+2 inference is hidden inside reading time.
        let shouldPreanalyze = readingMode == .guidedPanel
            || comic.isAutoOCRMagnificationEnabled
            || comic.isAutoTranslationEnabled
        if shouldPreanalyze {
            let comicID = comic.id
            let pages = manager.pages
            let visionIndices = readingMode == .guidedPanel
                ? GuidedPanelPrefetchPolicy.visionIndices(
                    currentPageIndex: index,
                    pageCount: pages.count
                )
                : [index] + preferredIndices
            mangaVisionPreanalysisTask = Task(priority: .utility) {
                await MangaVisionService.shared.preanalyze(
                    comicID: comicID,
                    pages: pages,
                    indices: visionIndices
                )
            }
        }
''',
"guided model preanalysis",
)

replace_once(
'''    var appliedPageURL: URL?
}

struct GuidedPanelReader: View {
''',
'''    var appliedPageURL: URL?
}

/// A short-lived decoded destination page used only while crossing a page boundary.
/// The image already lives in ReaderImageCache; holding it here for the transition prevents
/// LocalImageView's URL/task handoff from becoming visible without pinning whole-book images.
private struct GuidedPanelPageTransitionTarget {
    let pageIndex: Int
    let panelIndex: Int
    let entry: GuidedPanelLayoutStore.Entry
    let image: UIImage
}

struct GuidedPanelReader: View {
''',
"transition target type",
)

replace_once(
'''    @State private var panelMotionTask: Task<Void, Never>?
    @State private var layoutStore = GuidedPanelLayoutStore()
''',
'''    @State private var panelMotionTask: Task<Void, Never>?
    @State private var layoutStore = GuidedPanelLayoutStore()
    @State private var pageTransitionTarget: GuidedPanelPageTransitionTarget?
    @State private var pageTransitionProgress: Double = 0
''',
"transition state",
)

replace_once(
'''        GeometryReader { proxy in
            let camera = panelTransform(in: proxy.size)
            ZStack {
''',
'''        GeometryReader { proxy in
            let camera = panelTransform(in: proxy.size)
            let transitionCamera = pageTransitionTarget.map {
                panelTransform(for: $0.entry, panelIndex: $0.panelIndex, in: proxy.size)
            }
            ZStack {
''',
"transition camera",
)

replace_once(
'''                    .scaleEffect(camera.scale)
                    .offset(camera.offset)
                    .task(id: "\\(page.url.absoluteString)|\\(readingDirection.rawValue)") {
''',
'''                    .scaleEffect(camera.scale)
                    .offset(camera.offset)
                    .opacity(pageTransitionTarget == nil ? 1 : max(0, 1 - pageTransitionProgress))
                    .task(id: "\\(page.url.absoluteString)|\\(readingDirection.rawValue)") {
''',
"current page transition opacity",
)

replace_once(
'''                }

                if isDetecting {
                    ProgressView().tint(.white).allowsHitTesting(false)
                }
''',
'''                }

                if let transitionTarget = pageTransitionTarget,
                   let transitionCamera {
                    Image(uiImage: transitionTarget.image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .scaleEffect(transitionCamera.scale)
                        .offset(transitionCamera.offset)
                        .opacity(pageTransitionProgress)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }

                if isDetecting {
                    ProgressView().tint(.white).allowsHitTesting(false)
                }
''',
"destination page buffer",
)

replace_once(
'''            layoutStore.prefetchTask?.cancel()
            layoutStore.prefetchTask = nil
            layoutStore.pending.removeAll()
            layoutStore.scheduled.removeAll()
''',
'''            layoutStore.prefetchTask?.cancel()
            layoutStore.prefetchTask = nil
            layoutStore.pending.removeAll()
            layoutStore.scheduled.removeAll()
            pageTransitionTarget = nil
            pageTransitionProgress = 0
''',
"transition cleanup",
)

replace_once(
'''        // 向前两页、向后一页：读者读完一页时后面两页已经处理完，同时把每轮
        // Core ML 推理量压到 3 页以内（再多会明显增加常驻功耗）。
        for index in [pageIndex + 1, pageIndex + 2, pageIndex - 1]
        where pages.indices.contains(index) {
            let identifier = pages[index].url.absoluteString
''',
'''        // N+1 is always first, followed by N+2 and the previous page. The matching model
        // preanalysis runs from ReaderView on small thumbnails, so this queue mostly turns
        // already-warm model output into a final layout plus a decoded display buffer.
        for index in GuidedPanelPrefetchPolicy.layoutIndices(
            currentPageIndex: pageIndex,
            pageCount: pages.count
        ) {
            let identifier = pages[index].url.absoluteString
''',
"guided layout queue policy",
)

replace_once(
'''    private func panelTransform(in viewport: CGSize) -> (scale: CGFloat, offset: CGSize) {
''',
'''    private func panelTransform(
        for entry: GuidedPanelLayoutStore.Entry,
        panelIndex: Int,
        in viewport: CGSize
    ) -> (scale: CGFloat, offset: CGSize) {
        guard viewport.width > 0, viewport.height > 0,
              entry.sourceSize.width > 0, entry.sourceSize.height > 0 else {
            return (1, .zero)
        }
        let normalized = entry.layout.panelRects.indices.contains(panelIndex)
            ? entry.layout.panelRects[panelIndex]
            : entry.layout.contentBounds.cgRect
        let tuning = GuidedPanelMotionPlanner.viewportTuning(for: normalized)
        let transform = GuidedPanelViewport.transform(
            normalizedPanel: normalized,
            imageAspectRatio: entry.sourceSize.width / entry.sourceSize.height,
            viewportSize: viewport,
            contextPadding: tuning.contextPadding,
            maximumScale: tuning.maximumScale
        )
        return (transform.scale, transform.offset)
    }

    private func panelTransform(in viewport: CGSize) -> (scale: CGFloat, offset: CGSize) {
''',
"buffer transform helper",
)

replace_once(
'''        HapticManager.shared.play(.light)
        panelMotionTask?.cancel()

        guard !reduceMotion, profile.usesContextBridge else {
''',
'''        HapticManager.shared.play(.light)
        panelMotionTask?.cancel()
        promoteNextPagePrefetchIfNeeded(
            targetPanelIndex: targetIndex,
            panelCount: layout.panels.count
        )

        guard !reduceMotion, profile.usesContextBridge else {
''',
"near-boundary promotion",
)

old_page_transition = '''        let targetPage = pages[pageIndex]
        let targetURL = targetPage.url
        let profile = GuidedPanelMotionPlanner.profile(
            from: layout?.panelRects[safe: panelIndex],
            to: nil,
            crossesPageBoundary: true
        )

        // 预取命中：直接把相机落到目标分镜。新页在同一个 transaction 里替换旧页，
        // 相机从上一页的取景平滑移动到目标分镜取景——读者看到的是“上一个分镜 ->
        // 下一个分镜”，中间不出现整页画面，也不显示加载圈。
        if let cached = layoutStore.entries[targetURL.absoluteString],
           !cached.layout.panels.isEmpty {
            let lastPanelIndex = max(cached.layout.panels.count - 1, 0)
            let targetPanelIndex = enterAtLastPanel ? lastPanelIndex : 0
            withAnimation(cameraAnimation(for: profile)) {
                layout = cached.layout
                sourceSize = cached.sourceSize
                panelIndex = min(max(targetPanelIndex, 0), lastPanelIndex)
                cameraFocusOverride = nil
                currentPageIndex = pageIndex
            }
            enterCurrentPageAtLastPanel = false
            isDetecting = false
            layoutStore.appliedPageURL = targetURL
            scheduleNeighbourPrefetch(around: pageIndex)
            return
        }

        // 预取还没落地：新页先以整页进入，检测完成后由入场动画收到目标分镜。
'''
new_page_transition = '''        let targetPage = pages[pageIndex]
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
'''
replace_once(old_page_transition, new_page_transition, "buffered page transition")

replace_once(
'''        scheduleNeighbourPrefetch(around: pageIndex)
    }

    private func cameraAnimation(
''',
'''        scheduleNeighbourPrefetch(around: pageIndex)
    }

    private func promoteNextPagePrefetchIfNeeded(targetPanelIndex: Int, panelCount: Int) {
        guard GuidedPanelPrefetchPolicy.shouldPromoteNextPage(
            panelIndex: targetPanelIndex,
            panelCount: panelCount
        ) else { return }
        let nextPageIndex = currentPageIndex + 1
        guard pages.indices.contains(nextPageIndex) else { return }
        let nextPage = pages[nextPageIndex]
        let identifier = nextPage.url.absoluteString

        // Decode N+1 immediately instead of waiting for the ordinary 150 ms neighbour delay.
        ReaderImageCache.shared.preload(
            [nextPage.url],
            maxPixelSize: ReaderImageCache.fitScreenMaxPixelSize,
            maximumConcurrent: 1,
            delay: 0
        )

        // If layout work is queued behind N+2/N-1, move N+1 to the front. If it has not yet
        // been scheduled, add it now. Already-running work is not cancelled.
        if layoutStore.entries[identifier] == nil {
            if let pendingIndex = layoutStore.pending.firstIndex(of: nextPageIndex) {
                layoutStore.pending.remove(at: pendingIndex)
                layoutStore.pending.insert(nextPageIndex, at: 0)
            } else if !layoutStore.scheduled.contains(identifier) {
                layoutStore.scheduled.insert(identifier)
                layoutStore.pending.insert(nextPageIndex, at: 0)
            }
            drainNeighbourPrefetchQueue()
        }

        // The reader-level utility preanalysis normally has N+1 warm already. This foreground
        // request is a cheap cache/in-flight join when warm, and a priority safety net when the
        // user reaches the page boundary unusually quickly.
        let comicID = comic.id
        let pages = pages
        Task(priority: .userInitiated) {
            await MangaVisionService.shared.preanalyze(
                comicID: comicID,
                pages: pages,
                indices: [nextPageIndex]
            )
        }
    }

    private func beginBufferedPageTransition(
        to pageIndex: Int,
        panelIndex targetPanelIndex: Int,
        entry: GuidedPanelLayoutStore.Entry,
        image: UIImage
    ) {
        let target = GuidedPanelPageTransitionTarget(
            pageIndex: pageIndex,
            panelIndex: targetPanelIndex,
            entry: entry,
            image: image
        )
        MReaderLog.reader.debug(
            "guided panel page buffer hit page=\\(pageIndex + 1, privacy: .public) panels=\\(entry.layout.panels.count, privacy: .public)"
        )

        guard !reduceMotion else {
            adoptBufferedPage(target)
            pageTransitionTarget = nil
            pageTransitionProgress = 0
            isPanelTransitioning = false
            return
        }

        isPanelTransitioning = true
        pageTransitionTarget = target
        pageTransitionProgress = 0
        withAnimation(.easeInOut(duration: GuidedPanelPrefetchPolicy.bufferedPageTransitionDuration)) {
            pageTransitionProgress = 1
        }

        panelMotionTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(GuidedPanelPrefetchPolicy.bufferedPageTransitionDuration))
            guard !Task.isCancelled else {
                resetBufferedPageTransition()
                return
            }

            // Swap the logical page while the predecoded target still fully covers the view.
            // LocalImageView now gets a cache hit and can rebuild OCR/translation overlays out
            // of sight instead of exposing its URL/task handoff to the reader.
            adoptBufferedPage(target)
            try? await Task.sleep(for: .seconds(GuidedPanelPrefetchPolicy.bufferedPageHandoffDelay))
            guard !Task.isCancelled else {
                resetBufferedPageTransition()
                return
            }

            withAnimation(.easeOut(duration: GuidedPanelPrefetchPolicy.bufferedPageRevealDuration)) {
                pageTransitionProgress = 0
            }
            try? await Task.sleep(for: .seconds(GuidedPanelPrefetchPolicy.bufferedPageRevealDuration))
            guard !Task.isCancelled else {
                resetBufferedPageTransition()
                return
            }
            pageTransitionTarget = nil
            pageTransitionProgress = 0
            isPanelTransitioning = false
            panelMotionTask = nil
        }
    }

    private func adoptBufferedPage(_ target: GuidedPanelPageTransitionTarget) {
        layout = target.entry.layout
        sourceSize = target.entry.sourceSize
        panelIndex = target.panelIndex
        cameraFocusOverride = nil
        currentPageIndex = target.pageIndex
        enterCurrentPageAtLastPanel = false
        isDetecting = false
        layoutStore.appliedPageURL = pages[target.pageIndex].url
        scheduleNeighbourPrefetch(around: target.pageIndex)
    }

    private func resetBufferedPageTransition() {
        pageTransitionTarget = nil
        pageTransitionProgress = 0
        isPanelTransitioning = false
        panelMotionTask = nil
    }

    private func cameraAnimation(
''',
"buffer transition helpers",
)

path.write_text(text)
print("ReaderView guided-panel prefetch/buffer patch applied")
