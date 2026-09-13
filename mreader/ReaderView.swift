import SwiftUI
import ImageIO
import UIKit
import Combine
import os

struct ReaderContainerView: View {
    @State private var comic: ComicBook
    let showsControlsForTesting: Bool
    let onComicUpdate: (ComicBook) -> Void
    @State private var manager = ComicManager()
    @State private var isLoaded = false
    @State private var loadFailed = false

    init(
        comic: ComicBook,
        showsControlsForTesting: Bool = false,
        onComicUpdate: @escaping (ComicBook) -> Void
    ) {
        _comic = State(initialValue: comic)
        self.showsControlsForTesting = showsControlsForTesting
        self.onComicUpdate = onComicUpdate
    }
    
    var body: some View {
        Group {
            if isLoaded {
                ReaderView(
                    manager: manager,
                    comic: $comic,
                    showsControlsForTesting: showsControlsForTesting
                ) { updatedComic in
                    onComicUpdate(updatedComic)
                }
            } else if loadFailed {
                ContentUnavailableView("reader.loadFailed".localized, systemImage: "exclamationmark.triangle")
            } else {
                ProgressView("reader.parsing".localized)
            }
        }
        .onAppear {
            guard !isLoaded && !loadFailed else { return }
            Task {
                let result = await ReaderPageSourceService.loadPages(for: comic)
                if let result {
                    if comic.sourceType == .komga,
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
                    if comic.sourceType == .opds, comic.totalPages != result.pages.count {
                        comic.totalPages = result.pages.count
                        comic.remotePageCount = result.pages.count
                        comic.currentPageIndex = min(comic.currentPageIndex, max(0, result.pages.count - 1))
                        onComicUpdate(comic)
                    }
                    // 在 Reader 第一次创建前完成阅读预设检测（审查 #17）：
                    // 长条漫画第一次出现时就已经是 continuousScroll + fitWidth + 8192，
                    // 不会先产生一套 4096 普通阅读器。
                    // 远程源（Komga/OPDS）不做阻塞式检测：无缓存时先显示当前页，
                    // 由 ReaderView 后台检测（项13），避免首开串行下载第 3/4/5 页。
                    if !comic.hasInitializedReadingPreset, comic.sourceType == .local {
                        let preset = await InitialReadingPresetDetector.detect(
                            comic: comic,
                            pages: result.pages
                        )
                        comic.readingModeRaw = preset.readingMode.rawValue
                        comic.pageTurnAnimationRaw = preset.pageTurnAnimation.rawValue
                        comic.imageFitModeRaw = preset.imageFitMode.rawValue
                        comic.isAutoOCRMagnificationEnabled = false
                        comic.isAutoTranslationEnabled = false
                        comic.hasInitializedReadingPreset = true
                        comic.metadataUpdatedAt = Date()
                        onComicUpdate(comic)
                    }
                    await prewarmInitialScrollingPage(in: result)
                    manager.applyLoadedPages(result)
                    isLoaded = true
                } else {
                    loadFailed = true
                }
            }
        }
        .onDisappear {
            // ReaderView 必须先用仍然存在的页面数保存进度，再释放安全作用域和页面。
            DispatchQueue.main.async {
                manager.stopAccessing()
            }
        }
    }

    private func prewarmInitialScrollingPage(in result: ComicManager.LoadResult) async {
        let mode = ReadingMode(rawValue: comic.readingModeRaw) ?? .horizontalPage
        guard mode == .continuousScroll || mode == .infiniteScroll,
              !result.pages.isEmpty else {
            return
        }
        let index = min(max(comic.currentPageIndex, 0), result.pages.count - 1)
        let start = ContinuousClock.now
        _ = await ReaderImageCache.shared.loadImage(
            for: result.pages[index].url,
            maxPixelSize: 8192
        )
        MReaderLog.reader.debug(
            "initial scrolling page prewarmed page=\(index, privacy: .public) elapsed=\(String(describing: start.duration(to: .now)), privacy: .public)"
        )
    }
}

nonisolated enum ReadingMode: String, CaseIterable {
    case horizontalPage
    case verticalPage
    case continuousScroll
    case infiniteScroll
    case doublePage
    case guidedPanel
}

nonisolated enum ReadingDirection: String, CaseIterable {
    case leftToRight
    case rightToLeft
}

nonisolated enum PageTurnAnimation: String, CaseIterable {
    case none
    case slide
    case fade
    case curl
}

nonisolated enum ImageFitMode: String, CaseIterable {
    case fitScreen
    case fitWidth
    case fitHeight
    case original
}

/// 缩放 / 平移的纯几何计算，独立于视图以便直接测试。
///
/// 关键点：图片**不一定**铺满 viewport。`fitScreen` / `fitHeight` 会留下上下或左右留白，
/// `original` 甚至允许真实图片矩形小于容器。因此边界不能写成 `imageRect * (scale - 1) / 2`，
/// 必须看“缩放后的图片有没有超出 viewport”。
nonisolated enum ZoomPanGeometry {
    /// 各轴允许的最大平移距离。缩放后仍未铺满 viewport 的轴不允许平移（避免拖出空白）。
    static func panLimits(imageRect: CGRect, containerSize: CGSize, scale: CGFloat) -> CGSize {
        guard scale > 1,
              imageRect.width > 0, imageRect.height > 0,
              containerSize.width > 0, containerSize.height > 0 else {
            return .zero
        }
        return CGSize(
            width: max((imageRect.width * scale - containerSize.width) / 2, 0),
            height: max((imageRect.height * scale - containerSize.height) / 2, 0)
        )
    }

    static func clampedOffset(_ proposed: CGSize, limits: CGSize) -> CGSize {
        CGSize(
            width: min(max(proposed.width, -limits.width), limits.width),
            height: min(max(proposed.height, -limits.height), limits.height)
        )
    }
}

/// Reader 手势之间的最小协调规则。
///
/// 放大状态由页内图片回传给外层翻页容器；单页使用一个 Bool，双页使用按页维护的
/// Set。把门控规则集中在这里，避免 SwiftUI 手势组合的实现细节和阈值在多个 View
/// 中漂移，也让“只要还有一页放大就不能翻整组”可以直接做单元测试。
nonisolated enum ReaderGestureGate {
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

/// Reader 对 ComicBook 的一次 mutation 必须先产生唯一的最新值，再同时写回 Binding
/// 和传给持久化 callback。这个纯函数让 callback 不会意外拿到 mutation 前的旧副本。
nonisolated enum ReaderComicMutation {
    static func applying(
        _ mutate: (inout ComicBook) -> Void,
        to comic: ComicBook,
        now: Date
    ) -> ComicBook {
        var updatedComic = comic
        mutate(&updatedComic)
        updatedComic.metadataUpdatedAt = now
        if !updatedComic.isOCREnabled {
            updatedComic.isAutoOCRMagnificationEnabled = false
        }
        if !updatedComic.isAITranslationEnabled
            || (updatedComic.aiTranslationMode == .ocr && !updatedComic.isOCREnabled) {
            updatedComic.isAutoTranslationEnabled = false
        }
        return updatedComic
    }
}

nonisolated enum ScrollSpeed: String, CaseIterable {
    case slow
    case standard
    case fast

    var screenStepRatio: CGFloat {
        switch self {
        case .slow:
            return 0.45
        case .standard:
            return 0.65
        case .fast:
            return 0.8
        }
    }
}

nonisolated private struct InitialReadingPreset {
    let readingMode: ReadingMode
    let pageTurnAnimation: PageTurnAnimation
    let imageFitMode: ImageFitMode
    let reason: String

    static let longStrip = InitialReadingPreset(
        readingMode: .continuousScroll,
        pageTurnAnimation: .none,
        imageFitMode: .fitWidth,
        reason: "long-strip"
    )

    static let normalPage = InitialReadingPreset(
        readingMode: .horizontalPage,
        pageTurnAnimation: .slide,
        imageFitMode: .fitScreen,
        reason: "normal-page"
    )
}

nonisolated enum ReadingPresetSamplePagePolicy {
    static func pageIndices(totalPages: Int) -> [Int] {
        guard totalPages > 0 else { return [] }

        let preferredEnd = min(totalPages, 5)
        guard 2 < preferredEnd else {
            return Array(0..<totalPages)
        }
        return Array(2..<preferredEnd)
    }
}

/// 阅读预设检测器：在 Reader 第一次创建之前完成“这本漫画是不是长条”的判断，
/// 避免先按普通模式预载再切到 8192 重解码（审查 #17）。
nonisolated private enum InitialReadingPresetDetector {
    static func detect(comic: ComicBook, pages: [ComicPage]) async -> InitialReadingPreset {
        if isDocument(comic, "epub") {
            return InitialReadingPreset(
                readingMode: .horizontalPage,
                pageTurnAnimation: .curl,
                imageFitMode: .fitScreen,
                reason: "epub"
            )
        }
        if isDocument(comic, "pdf") {
            return InitialReadingPreset.longStrip
        }
        let sampleIndices = ReadingPresetSamplePagePolicy.pageIndices(totalPages: pages.count)
        guard !sampleIndices.isEmpty else { return .normalPage }
        var ratios: [CGFloat] = []
        for index in sampleIndices {
            guard pages.indices.contains(index),
                  let size = await pagePixelSize(for: pages[index].url) else { continue }
            await MainActor.run { PageGeometryStore.shared.setSize(size, for: pages[index].url) }
            ratios.append(size.height / max(size.width, 1))
        }
        guard let medianRatio = medianRatio(ratios) else { return .normalPage }
        if medianRatio > 1.8 {
            return InitialReadingPreset(
                readingMode: .continuousScroll,
                pageTurnAnimation: .none,
                imageFitMode: .fitWidth,
                reason: String(format: "median ratio %.3f pages %@", medianRatio, sampleIndices.map { "\($0 + 1)" }.joined(separator: ","))
            )
        }
        return InitialReadingPreset(
            readingMode: .horizontalPage,
            pageTurnAnimation: .slide,
            imageFitMode: .fitScreen,
            reason: String(format: "median ratio %.3f pages %@", medianRatio, sampleIndices.map { "\($0 + 1)" }.joined(separator: ","))
        )
    }

    private static func pagePixelSize(for url: URL) async -> CGSize? {
        if RemotePageLoader.isRemotePageURL(url) {
            if let request = RemotePageLoader.RemotePageRequest(url: url) {
                let cachedURL = RemotePageLoader.pageCacheURL(
                    sourceID: request.sourceID,
                    bookID: request.bookID,
                    pageIndex: request.pageIndex
                )
                if let data = try? Data(contentsOf: cachedURL) {
                    return imagePixelSize(from: data)
                }
            }
            guard let data = await RemotePageLoader.imageData(forRemotePageURL: url) else { return nil }
            return imagePixelSize(from: data)
        }
        if ComicManager.isArchivePageURL(url) {
            return await Task.detached(priority: .utility) {
                // 轻量尺寸读取，避免为了读宽高而完整解压图片（审查 #18）
                ComicManager.imagePixelSizeForArchivePageURL(url)
                    ?? ComicManager.imageData(forArchivePageURL: url).flatMap { imagePixelSize(from: $0) }
            }.value
        }
        return await Task.detached(priority: .utility) {
            imagePixelSize(from: url)
        }.value
    }

    private static func isDocument(_ comic: ComicBook, _ expectedExtension: String) -> Bool {
        let rawValues = [comic.libraryPath, comic.chapterPath, comic.sourceURL]
        if rawValues.contains(where: { path in
            guard let path else { return false }
            if let url = URL(string: path), url.scheme != nil {
                return url.pathExtension.lowercased() == expectedExtension
            }
            return URL(fileURLWithPath: path).pathExtension.lowercased() == expectedExtension
        }) {
            return true
        }
        return comic.chapterTypeRaw?.lowercased() == expectedExtension
    }

    private static func medianRatio(_ ratios: [CGFloat]) -> CGFloat? {
        guard !ratios.isEmpty else { return nil }
        let sortedRatios = ratios.sorted()
        let middle = sortedRatios.count / 2
        if sortedRatios.count.isMultiple(of: 2) {
            return (sortedRatios[middle - 1] + sortedRatios[middle]) / 2
        }
        return sortedRatios[middle]
    }
}

nonisolated private func deviceMemoryBytes() -> UInt64 {
    ProcessInfo.processInfo.physicalMemory
}

/// 页面几何缓存：图片解码/尺寸读取后登记真实宽高，供连续滚动占位使用真实比例（审查 #16）。
@MainActor
final class PageGeometryStore {
    static let shared = PageGeometryStore()
    private var sizes: [String: CGSize] = [:]

    func setSize(_ size: CGSize, for url: URL) {
        sizes[url.absoluteString] = size
    }

    func size(for url: URL) -> CGSize? {
        sizes[url.absoluteString]
    }
}

nonisolated private func cacheLimits() -> (memoryLimitMB: Int, preloadMB: Int) {
    let ramGB = Double(deviceMemoryBytes()) / (1024 * 1024 * 1024)
    if ramGB >= 6 {
        return (750, 600)
    } else if ramGB >= 4 {
        return (340, 260)
    } else {
        return (180, 130)
    }
}

private actor ReaderImageDecodeLimiter {
    static let shared = ReaderImageDecodeLimiter(maximumConcurrentDecodes: 2)

    private let maximumConcurrentDecodes: Int
    private var activeDecodes = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maximumConcurrentDecodes: Int) {
        self.maximumConcurrentDecodes = max(1, maximumConcurrentDecodes)
    }

    func acquire() async {
        if activeDecodes < maximumConcurrentDecodes {
            activeDecodes += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            activeDecodes = max(0, activeDecodes - 1)
        } else {
            waiters.removeFirst().resume()
        }
    }
}

@MainActor
private final class ReaderImageCache {
    static let shared = ReaderImageCache()

    private struct PreloadCandidate {
        let url: URL
        let key: String
        let cost: Int
        let maxPixelSize: CGFloat
    }

    private let cache = NSCache<NSString, UIImage>()
    private var inFlightLoads: [String: Task<UIImage?, Never>] = [:]
    private var loadingCosts: [String: Int] = [:]
    private var scheduledPreload: Task<Void, Never>?
    private var preloadQueue: [PreloadCandidate] = []
    private var activePreloadCount = 0
    private var maximumConcurrentPreloads = 2
    private var preloadKeys: Set<String> = []
    /// Foreground readers that joined a preload task protect that task from a
    /// subsequent preload-window refresh cancelling the shared decode.
    private var foregroundLoadKeys: Set<String> = []
    private let preloadBudgetBytes: Int

    private init() {
        let limits = cacheLimits()
        preloadBudgetBytes = limits.preloadMB * 1024 * 1024
        cache.countLimit = 0
        cache.totalCostLimit = limits.memoryLimitMB * 1024 * 1024
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task {
                await ReaderImageCache.clearSharedMemoryCache()
            }
        }
        NotificationCenter.default.addObserver(
            forName: .mreaderClearReaderMemoryCaches,
            object: nil,
            queue: .main
        ) { _ in
            Task {
                await ReaderImageCache.clearSharedMemoryCache()
            }
        }
    }

    // 升序：选择“最小但 >= 请求”的缓存（项12），避免无谓持有更大 UIImage。
    private let resolutionTiers: [CGFloat] = [4096, 6144, 8192]

    func cachedImage(for url: URL, maxPixelSize: CGFloat = 4096) -> UIImage? {
        for tier in resolutionTiers where tier >= maxPixelSize {
            if let image = cache.object(forKey: cacheKey(for: url, maxPixelSize: tier) as NSString) {
                return image
            }
        }
        return nil
    }

    /// 返回 ≥ 请求分辨率且在途的 task 对应 cacheKey（项11：让低分辨率请求 join 高分辨率在途任务）。
    private func inFlightKeySatisfying(url: URL, maxPixelSize: CGFloat) -> String? {
        for tier in resolutionTiers where tier >= maxPixelSize {
            let key = cacheKey(for: url, maxPixelSize: tier)
            if inFlightLoads[key] != nil {
                return key
            }
        }
        return nil
    }

    func loadImage(for url: URL, maxPixelSize: CGFloat = 4096) async -> UIImage? {
        // 跨分辨率复用：已有更高分辨率缓存（如 8192）时，低分辨率请求（如 4096）直接复用（项11）
        if let cached = cachedImage(for: url, maxPixelSize: maxPixelSize) {
            return cached
        }
        let key = cacheKey(for: url, maxPixelSize: maxPixelSize)
        if let existingTask = inFlightLoads[key] {
            foregroundLoadKeys.insert(key)
            defer { foregroundLoadKeys.remove(key) }
            return await existingTask.value
        }
        // 加入更高分辨率的在途解码任务，避免同时双解码
        if let higherKey = inFlightKeySatisfying(url: url, maxPixelSize: maxPixelSize),
           let existingTask = inFlightLoads[higherKey] {
            foregroundLoadKeys.insert(higherKey)
            defer { foregroundLoadKeys.remove(higherKey) }
            return await existingTask.value
        }

        let estimatedCost = estimatedDecodedCost(for: url, maxPixelSize: maxPixelSize)
        let task = Task.detached(priority: .userInitiated) {
            await decodeReaderImage(from: url, maxPixelSize: maxPixelSize)
        }
        inFlightLoads[key] = task
        loadingCosts[key] = estimatedCost
        foregroundLoadKeys.insert(key)
        let image = await task.value
        foregroundLoadKeys.remove(key)
        inFlightLoads[key] = nil
        loadingCosts[key] = nil
        if let image {
            cache.setObject(image, forKey: key as NSString, cost: image.cacheCost)
        }
        drainPreloadQueue()
        return image
    }

    func preload(
        _ urls: [URL],
        maxPixelSize: CGFloat = 4096,
        maximumConcurrent: Int = 2,
        delay: TimeInterval = 0.25
    ) {
        scheduledPreload?.cancel()
        var seenURLs = Set<URL>()
        let uniqueURLs = urls.filter { seenURLs.insert($0).inserted }
        scheduledPreload = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled, let self else { return }
            self.startPreloading(
                uniqueURLs,
                maxPixelSize: maxPixelSize,
                maximumConcurrent: maximumConcurrent
            )
        }
    }

    private func startPreloading(_ urls: [URL], maxPixelSize: CGFloat, maximumConcurrent: Int) {
        let desiredKeys = Set(urls.map { cacheKey(for: $0, maxPixelSize: maxPixelSize) })
        for staleKey in preloadKeys.subtracting(desiredKeys) {
            guard !foregroundLoadKeys.contains(staleKey) else { continue }
            inFlightLoads[staleKey]?.cancel()
        }

        let candidates = urls
            .map { url in
                PreloadCandidate(
                    url: url,
                    key: cacheKey(for: url, maxPixelSize: maxPixelSize),
                    cost: estimatedDecodedCost(for: url, maxPixelSize: maxPixelSize),
                    maxPixelSize: maxPixelSize
                )
            }
            .filter {
                cachedImage(for: $0.url, maxPixelSize: maxPixelSize) == nil
                    && inFlightKeySatisfying(url: $0.url, maxPixelSize: maxPixelSize) == nil
            }

        preloadQueue = candidates
        maximumConcurrentPreloads = max(1, maximumConcurrent)
        let queuedBytes = candidates.reduce(0) { $0 + $1.cost }
        MReaderLog.reader.debug(
            "decoded image preload budget=\(self.preloadBudgetBytes, privacy: .public) queuedBytes=\(queuedBytes, privacy: .public) queued=\(candidates.count, privacy: .public)"
        )
        drainPreloadQueue()
    }

    private func drainPreloadQueue() {
        while activePreloadCount < maximumConcurrentPreloads, !preloadQueue.isEmpty {
            let candidate = preloadQueue[0]
            guard cache.object(forKey: candidate.key as NSString) == nil,
                  inFlightLoads[candidate.key] == nil else {
                preloadQueue.removeFirst()
                continue
            }
            let activeBytes = loadingCosts.values.reduce(0, +)
            guard activeBytes == 0 || activeBytes + candidate.cost <= preloadBudgetBytes else {
                return
            }
            preloadQueue.removeFirst()

            activePreloadCount += 1
            preloadKeys.insert(candidate.key)
            loadingCosts[candidate.key] = candidate.cost
            let task: Task<UIImage?, Never> = Task.detached(priority: .utility) {
                guard !Task.isCancelled else { return nil }
                let image = await decodeReaderImage(from: candidate.url, maxPixelSize: candidate.maxPixelSize)
                return Task.isCancelled ? nil : image
            }
            inFlightLoads[candidate.key] = task
            Task { @MainActor [weak self] in
                let image = await task.value
                guard let self else { return }
                self.inFlightLoads[candidate.key] = nil
                self.loadingCosts[candidate.key] = nil
                self.preloadKeys.remove(candidate.key)
                self.activePreloadCount = max(0, self.activePreloadCount - 1)
                if let image {
                    self.cache.setObject(image, forKey: candidate.key as NSString, cost: image.cacheCost)
                }
                self.drainPreloadQueue()
            }
        }
    }

    func clearMemoryCache() {
        scheduledPreload?.cancel()
        scheduledPreload = nil
        preloadQueue.removeAll()
        for key in preloadKeys {
            inFlightLoads[key]?.cancel()
            inFlightLoads[key] = nil
            loadingCosts[key] = nil
        }
        preloadKeys.removeAll()
        foregroundLoadKeys.removeAll()
        activePreloadCount = 0
        cache.removeAllObjects()
        MReaderLog.reader.debug("decoded image cache memory cleared")
    }

    private static func clearSharedMemoryCache() {
        shared.clearMemoryCache()
    }

    private func cacheKey(for url: URL, maxPixelSize: CGFloat) -> String {
        if ComicManager.isArchivePageURL(url) {
            let sourceKey = ComicManager.archivePageCacheKey(for: url) ?? url.absoluteString
            return "\(sourceKey)#px=\(Int(maxPixelSize))"
        }
        if RemotePageLoader.isRemotePageURL(url) {
            return "\(url.absoluteString)#px=\(Int(maxPixelSize))"
        }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = values?.fileSize ?? 0
        return "\(url.path)#\(size)#\(mtime)#px=\(Int(maxPixelSize))"
    }

    private func estimatedDecodedCost(for url: URL, maxPixelSize: CGFloat) -> Int {
        if ComicManager.isArchivePageURL(url) {
            // 估算阶段不能再次解压 CBZ；优先使用已经登记的几何信息，未知时采用保守预算。
            if let pixelSize = PageGeometryStore.shared.size(for: url),
               pixelSize.width > 0,
               pixelSize.height > 0 {
                let scale = min(1, maxPixelSize / max(pixelSize.width, pixelSize.height))
                return max(1, Int(pixelSize.width * scale * pixelSize.height * scale * 4))
            }
            return max(12 * 1024 * 1024, Int(maxPixelSize * maxPixelSize * 0.55))
        }
        if RemotePageLoader.isRemotePageURL(url) {
            return Int(maxPixelSize * maxPixelSize * 0.55)
        }
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
           let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
           width > 0,
           height > 0 {
            let scale = min(1, maxPixelSize / max(width, height))
            return Int(width * scale * height * scale * 4)
        }
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return max(fileSize * 6, 12 * 1024 * 1024)
    }
}

private extension UIImage {
    var cacheCost: Int {
        guard let cgImage else { return 1 }
        return cgImage.bytesPerRow * cgImage.height
    }
}

nonisolated private func decodeReaderImage(from url: URL, maxPixelSize: CGFloat) async -> UIImage? {
    let remoteData: Data?
    if RemotePageLoader.isRemotePageURL(url) {
        remoteData = await RemotePageLoader.imageData(forRemotePageURL: url)
    } else {
        remoteData = nil
    }
    await ReaderImageDecodeLimiter.shared.acquire()
    if Task.isCancelled {
        await ReaderImageDecodeLimiter.shared.release()
        return nil
    }
    let image = autoreleasepool { () -> UIImage? in
        let source: CGImageSource?
        if ComicManager.isArchivePageURL(url), let data = ComicManager.imageData(forArchivePageURL: url) {
            source = CGImageSourceCreateWithData(data as CFData, nil)
        } else if let remoteData {
            source = CGImageSourceCreateWithData(remoteData as CFData, nil)
        } else {
            source = CGImageSourceCreateWithURL(url as CFURL, nil)
        }
        guard let source else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldCache: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return UIImage(cgImage: cgImage)
        }
        return UIImage(contentsOfFile: url.path)
    }
    if Task.isCancelled {
        await ReaderImageDecodeLimiter.shared.release()
        return nil
    }
    await ReaderImageDecodeLimiter.shared.release()
    if let image {
        let pixelSize = CGSize(
            width: image.size.width * image.scale,
            height: image.size.height * image.scale
        )
        await MainActor.run { PageGeometryStore.shared.setSize(pixelSize, for: url) }
    }
    return image
}

nonisolated private func imagePixelSize(from data: Data) -> CGSize? {
    guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
        return nil
    }
    return imagePixelSize(from: source)
}

nonisolated private func imagePixelSize(from url: URL) -> CGSize? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
        return nil
    }
    return imagePixelSize(from: source)
}

nonisolated private func imagePixelSize(from source: CGImageSource) -> CGSize? {
    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
          let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
          width > 0,
          height > 0 else {
        return nil
    }
    return CGSize(width: width, height: height)
}

struct ReaderView: View {
    var manager: ComicManager
    @Binding var comic: ComicBook
    let showsControlsForTesting: Bool
    let onComicUpdate: (ComicBook) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    
    @AppStorage("translation_target_language") private var translationTargetLanguage = TranslationTargetLanguage.simplifiedChinese.rawValue
    @AppStorage("translation_style_instructions") private var translationStyleInstructions = AITranslator.defaultTranslationStyleInstructions
    @AppStorage("vision_translation_prompt_template") private var visionTranslationPromptTemplate = AITranslator.defaultVisionTranslationPromptTemplate
    @AppStorage("ocr_show_debug_boxes") private var ocrShowDebugBoxes = false
    @AppStorage("ocr_visual_verification_enabled") private var ocrVisualVerificationEnabled = false
    @AppStorage("ocr_local_recognition_mode") private var ocrRecognitionModeRaw = OCRRecognitionMode.adaptive.rawValue
    @AppStorage("ai_translation_border_progress_enabled") private var aiTranslationBorderProgressEnabled = true
    @AppStorage("translation_color_style") private var translationColorStyleRaw = TranslationColorStyle.contrast.rawValue
    @AppStorage("translation_use_apple_low_latency") private var useAppleLowLatency = false
    @State private var currentPageIndex: Int
    @State private var showControls: Bool = false
    @State private var showComicSettings = false
    @State private var showOfflineTranslationStart = false
    @State private var showOfflineTranslationManager = false
    @State private var translateRequestID = UUID()
    @State private var ocrMagnifyRequestID = UUID()
    @State private var isOCRMagnificationVisible = false
    @State private var pageTurnDirection = 1
    @State private var jumpPageText = ""
    @State private var scrollJumpRequestID = UUID()
    @State private var didRecordReaderOpen = false
    @State private var lastSavedScrollProgress: Double
    @State private var lastSavedScrollPageProgress: Double
    @State private var lastProgressPersistDate = Date.distantPast
    @State private var lastPrefetchPageIndex: Int
    @State private var activeTranslationCount = 0
    private var isAITranslationInProgress: Bool { activeTranslationCount > 0 }
    private var areReaderControlsVisible: Bool {
        showControls || showsControlsForTesting
    }
    @State private var translationPrefetchTask: Task<Void, Never>?
    @State private var activityLastRecordedAt = Date()
    @State private var activityLastPageIndex: Int
    @State private var dismissGestureProgress: CGFloat = 0
    @State private var isDismissAnimating = false
    @State private var lastReaderInteractionAt = Date()
    @State private var isBurnInProtectionLocked = false
    @AppStorage("burn_in_protection_enabled") private var isBurnInProtectionEnabled = true
    @State private var editingBookmark: ComicBookmark?
    @State private var bookmarkNoteText = ""
    @State private var showBookmarkNoteAlert = false

    private var readingMode: ReadingMode {
        ReadingMode(rawValue: comic.readingModeRaw) ?? .horizontalPage
    }

    private var readingDirection: ReadingDirection {
        ReadingDirection(rawValue: comic.readingDirectionRaw) ?? .leftToRight
    }

    private var pageTurnAnimation: PageTurnAnimation {
        PageTurnAnimation(rawValue: comic.pageTurnAnimationRaw) ?? .slide
    }

    private var imageFitMode: ImageFitMode {
        ImageFitMode(rawValue: comic.imageFitModeRaw) ?? .fitScreen
    }

    private var scrollSpeed: ScrollSpeed {
        ScrollSpeed(rawValue: comic.scrollSpeedRaw) ?? .standard
    }

    private var aiTranslationMode: AITranslationMode {
        comic.aiTranslationMode
    }

    private var selectedTranslationTarget: TranslationTargetLanguage {
        TranslationTargetLanguage.migrateLegacyValue(translationTargetLanguage)
    }

    private var isOCRMagnificationActive: Bool {
        comic.isOCREnabled && (isOCRMagnificationVisible || comic.isAutoOCRMagnificationEnabled)
    }

    private var readingModeRaw: Binding<String> {
        Binding(
            get: { comic.readingModeRaw },
            set: { newValue in updateComic { $0.readingModeRaw = newValue; $0.hasInitializedReadingPreset = true } }
        )
    }

    private var readingDirectionRaw: Binding<String> {
        Binding(
            get: { comic.readingDirectionRaw },
            set: { newValue in updateComic { $0.readingDirectionRaw = newValue; $0.hasInitializedReadingPreset = true } }
        )
    }

    private var scrollSpeedRaw: Binding<String> {
        Binding(
            get: { comic.scrollSpeedRaw },
            set: { newValue in updateComic { $0.scrollSpeedRaw = newValue; $0.hasInitializedReadingPreset = true } }
        )
    }

    private var pageTurnAnimationRaw: Binding<String> {
        Binding(
            get: { comic.pageTurnAnimationRaw },
            set: { newValue in updateComic { $0.pageTurnAnimationRaw = newValue; $0.hasInitializedReadingPreset = true } }
        )
    }

    private var imageFitModeRaw: Binding<String> {
        Binding(
            get: { comic.imageFitModeRaw },
            set: { newValue in updateComic { $0.imageFitModeRaw = newValue; $0.hasInitializedReadingPreset = true } }
        )
    }

    init(
        manager: ComicManager,
        comic: Binding<ComicBook>,
        showsControlsForTesting: Bool = false,
        onComicUpdate: @escaping (ComicBook) -> Void
    ) {
        let initialComic = comic.wrappedValue
        self.manager = manager
        self._comic = comic
        self.showsControlsForTesting = showsControlsForTesting
        self.onComicUpdate = onComicUpdate
        let maxIndex = max(0, manager.pages.count - 1)
        _currentPageIndex = State(initialValue: min(max(initialComic.currentPageIndex, 0), maxIndex))
        _lastSavedScrollProgress = State(initialValue: initialComic.scrollProgress)
        _lastSavedScrollPageProgress = State(initialValue: initialComic.scrollPageProgress)
        _lastPrefetchPageIndex = State(initialValue: min(max(initialComic.currentPageIndex, 0), maxIndex))
        _activityLastPageIndex = State(initialValue: min(max(initialComic.currentPageIndex, 0), maxIndex))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if manager.pages.isEmpty {
                ContentUnavailableView("reader.noImagesFound".localized, systemImage: "photo.on.rectangle.angled", description: Text("reader.noImagesDescription".localized))
                    .foregroundStyle(.white)
            } else if readingMode == .guidedPanel {
                GuidedPanelReader(
                    pages: manager.pages,
                    currentPageIndex: $currentPageIndex,
                    readingDirection: readingDirection,
                    comic: comic,
                    translateRequestID: translateRequestID,
                    ocrMagnifyRequestID: ocrMagnifyRequestID,
                    isOCRMagnificationVisible: isOCRMagnificationActive,
                    targetLanguage: selectedTranslationTarget.rawValue,
                    onTranslationStateChange: updateAITranslationProgress,
                    areControlsVisible: areReaderControlsVisible,
                    onShowControls: showControlsIfNeeded,
                    onHideControls: hideControls
                )
                .ignoresSafeArea()
            } else if readingMode == .horizontalPage || readingMode == .verticalPage {
                AnimatedPageReader(
                    pages: manager.pages,
                    currentPageIndex: $currentPageIndex,
                    pageTurnDirection: $pageTurnDirection,
                    readingDirection: readingDirection,
                    readingMode: readingMode,
                    pageTurnAnimation: pageTurnAnimation,
                    imageFitMode: imageFitMode,
                    comic: comic,
                    translateRequestID: translateRequestID,
                    ocrMagnifyRequestID: ocrMagnifyRequestID,
                    isOCRMagnificationVisible: isOCRMagnificationActive,
                    targetLanguage: selectedTranslationTarget.rawValue,
                    onTranslationStateChange: updateAITranslationProgress,
                    areControlsVisible: areReaderControlsVisible,
                    onShowControls: showControlsIfNeeded,
                    onHideControls: hideControls
                )
                .environment(\.layoutDirection, readingDirection == .rightToLeft ? .rightToLeft : .leftToRight)
                .ignoresSafeArea()
            } else if readingMode == .doublePage {
                DoublePageReader(
                    pages: manager.pages,
                    currentPageIndex: $currentPageIndex,
                    pageTurnDirection: $pageTurnDirection,
                    readingDirection: readingDirection,
                    pageTurnAnimation: pageTurnAnimation,
                    imageFitMode: imageFitMode,
                    comic: comic,
                    translateRequestID: translateRequestID,
                    ocrMagnifyRequestID: ocrMagnifyRequestID,
                    isOCRMagnificationVisible: isOCRMagnificationActive,
                    targetLanguage: selectedTranslationTarget.rawValue,
                    onTranslationStateChange: updateAITranslationProgress,
                    areControlsVisible: areReaderControlsVisible,
                    onShowControls: showControlsIfNeeded,
                    onHideControls: hideControls
                )
                .environment(\.layoutDirection, readingDirection == .rightToLeft ? .rightToLeft : .leftToRight)
                .ignoresSafeArea()
            } else {
                ContinuousScrollReader(
                    pages: manager.pages,
                    currentPageIndex: $currentPageIndex,
                    readingMode: readingMode,
                    scrollSpeed: scrollSpeed,
                    comic: comic,
                    translateRequestID: translateRequestID,
                    ocrMagnifyRequestID: ocrMagnifyRequestID,
                    isOCRMagnificationVisible: isOCRMagnificationActive,
                    targetLanguage: selectedTranslationTarget.rawValue,
                    scrollJumpRequestID: scrollJumpRequestID,
                    scrollProgress: comic.scrollProgress,
                    scrollPageProgress: comic.scrollPageProgress,
                    onScrollPositionChange: saveScrollPosition,
                    onTranslationStateChange: updateAITranslationProgress,
                    areControlsVisible: areReaderControlsVisible,
                    onShowControls: showControlsIfNeeded,
                    onHideControls: hideControls
                )
                .ignoresSafeArea()
            }

            if isAITranslationInProgress && aiTranslationBorderProgressEnabled {
                AppleIntelligenceGlowBorder(
                    cornerRadius: 36,
                    lineWidth: 18,
                    blurRadius: 0,
                    animationDuration: 2.0,
                    colors: TranslationTextRenderer.palette
                )
                .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            TwoFingerSwipeDownDismissView(
                onProgress: { progress in
                    guard !isDismissAnimating else { return }
                    dismissGestureProgress = progress
                    recordReaderInteraction()
                },
                onCancel: {
                    guard !isDismissAnimating else { return }
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
                        dismissGestureProgress = 0
                    }
                },
                onSwipe: completeTwoFingerDismiss
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .background(ScrollsToTopDisabledView())

            ReaderControlsDoubleTapOverlay(isEnabled: !showComicSettings) {
                toggleControls()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()

            ReaderPageTapOverlay(
                isEnabled: (readingMode == .horizontalPage || readingMode == .verticalPage || readingMode == .doublePage) && !showControls && !showComicSettings,
                onPreviousPage: previousContainerPage,
                onNextPage: nextContainerPage,
                onLongPress: {
                    guard comic.isAITranslationEnabled else { return }
                    HapticManager.shared.play(.medium)
                    translateRequestID = UUID()
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()

            if areReaderControlsVisible {
                GeometryReader { proxy in
                    VStack(spacing: 0) {
                        readerTopControlBar
                            .padding(.top, proxy.safeAreaInsets.top + 4)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 8)
                            .background(.ultraThinMaterial)
                        Spacer(minLength: 0)
                    }
                    .ignoresSafeArea(edges: .top)
                }
                .transition(.opacity)
                .zIndex(20)
            }

            if areReaderControlsVisible {
                VStack {
                    Spacer()
                    HStack(spacing: 10) {
                        Spacer()
                        if comic.isOCREnabled {
                        Button {
                            HapticManager.shared.play(.light)
                            isOCRMagnificationVisible.toggle()
                            if isOCRMagnificationVisible {
                                ocrMagnifyRequestID = UUID()
                            }
                        } label: {
                            Image(systemName: isOCRMagnificationActive ? "text.magnifyingglass" : "text.viewfinder")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                                .overlay(
                                    Circle()
                                        .stroke(.white.opacity(0.22), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("reader.ocrMagnify".localized)
                        }

                        if comic.isAITranslationEnabled {
                        Button {
                            HapticManager.shared.play(.light)
                            translateRequestID = UUID()
                        } label: {
                            Text("AI")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                                .overlay(
                                    Circle()
                                        .stroke(.white.opacity(0.22), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("reader.aiTranslationLabel".localized)
                        }
                    }
                    .padding(.trailing, 18)
                    .padding(.bottom, 18)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .bottomTrailing)))
            }

            if isBurnInProtectionLocked {
                Color.black
                    .ignoresSafeArea()
                    .overlay {
                        VStack(spacing: 14) {
                            Image(systemName: "lock.display")
                                .font(.system(size: 38, weight: .medium))
                            Text("reader.burnInEnabled".localized)
                                .font(.headline)
                            Text("reader.burnInDescription".localized)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(28)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        isBurnInProtectionLocked = false
                        recordReaderInteraction()
                    }
                    .zIndex(100)
            }
        }
        .scaleEffect(max(0.72, 1 - dismissGestureProgress * 0.22))
        .offset(y: dismissGestureProgress * 190)
        .opacity(max(0.08, 1 - dismissGestureProgress * 0.88))
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle("")
        .navigationBarBackButtonHidden(true) // 核心：拦截原生左侧边缘的滑动返回手势
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mreader.reader.root")
        .defersSystemGestures(on: .horizontal) // 将水平滑动优先级完全交给翻页
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showComicSettings) {
            comicSettingsSheet
        }
        .sheet(isPresented: $showOfflineTranslationStart) {
            OfflineTranslationStartView(
                comic: comic,
                currentPageIndex: currentPageIndex,
                intent: .fromCurrent,
                onBackground: {
                    showOfflineTranslationStart = false
                    showOfflineTranslationManager = false
                    dismiss()
                }
            )
        }
        .sheet(isPresented: $showOfflineTranslationManager) {
            OfflineTranslationManagerView(
                comic: comic,
                onBackground: {
                    showOfflineTranslationStart = false
                    showOfflineTranslationManager = false
                    dismiss()
                }
            )
        }
        .alert("reader.bookmarkEditNote".localized, isPresented: $showBookmarkNoteAlert) {
            TextField("reader.bookmarkNotePlaceholder".localized, text: $bookmarkNoteText)
            Button("nav.cancel".localized, role: .cancel) {
                editingBookmark = nil
                bookmarkNoteText = ""
            }
            Button("nav.save".localized) {
                if let bookmark = editingBookmark {
                    updateBookmarkNote(bookmark: bookmark, note: bookmarkNoteText)
                }
                editingBookmark = nil
                bookmarkNoteText = ""
            }
        }
        .onAppear {
            let migratedLanguage = selectedTranslationTarget.rawValue
            if translationTargetLanguage != migratedLanguage {
                translationTargetLanguage = migratedLanguage
            }
            if showsControlsForTesting {
                showControls = true
            }
            recordReaderInteraction()
            applyEPUBPresetBeforeFirstOpen()
            Task {
                await initializeReadingPresetIfNeeded()
            }
            recordReaderOpenIfNeeded()
            preloadPages(around: currentPageIndex)
            scheduleTranslationPrefetch(around: currentPageIndex)
        }
        .onDisappear {
            RemotePagePrefetcher.shared.cancelAll()
            translationPrefetchTask?.cancel()
            translationPrefetchTask = nil
            recordReadingActivity()
            persistReadingProgress(pageIndex: currentPageIndex, reason: "readerDisappear", force: true)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { break }
                recordReadingActivity()
                checkBurnInProtection()
            }
        }
        .statusBar(hidden: true)
        .onChange(of: currentPageIndex) { oldValue, newValue in
            let clampedValue = min(max(newValue, 0), max(0, manager.pages.count - 1))
            if clampedValue != newValue {
                currentPageIndex = clampedValue
                return
            }
            if newValue != oldValue {
                pageTurnDirection = newValue > oldValue ? 1 : -1
                recordReadingActivity()
                recordReaderInteraction()
            }
            let isScrollingMode = readingMode == .continuousScroll || readingMode == .infiniteScroll
            persistReadingProgress(pageIndex: clampedValue, reason: "currentPageIndexChanged", force: !isScrollingMode)
            preloadPages(around: clampedValue)
            scheduleTranslationPrefetch(around: clampedValue)
        }
        .onChange(of: comic.isAutoTranslationEnabled) { _, isEnabled in
            if isEnabled {
                scheduleTranslationPrefetch(around: currentPageIndex)
            } else {
                translationPrefetchTask?.cancel()
                translationPrefetchTask = nil
                MReaderLog.aiTranslation.debug(
                    "AI translation prefetch disabled comic=\(comic.id.uuidString, privacy: .public)"
                )
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .background || newPhase == .inactive else { return }
            recordReadingActivity()
            persistReadingProgress(pageIndex: currentPageIndex, reason: "scenePhase-\(newPhase)", force: true)
        }
    }

    private var bottomControlBar: some View {
        VStack(spacing: 14) {
            HStack(spacing: 18) {
                Button(action: previousPage) {
                    Image(systemName: readingDirection == .rightToLeft ? "chevron.right" : "chevron.left")
                        .frame(width: 36, height: 36)
                }
                .disabled(currentPageIndex <= 0)
                .accessibilityIdentifier("mreader.reader.previousPage")

                Spacer()

                Text("\(currentPageIndex + 1) / \(manager.pages.count)")
                    .font(.system(.headline, design: .rounded))
                    .monospacedDigit()
                    .accessibilityIdentifier("mreader.reader.progress")

                Spacer()

                Button(action: nextPage) {
                    Image(systemName: readingDirection == .rightToLeft ? "chevron.left" : "chevron.right")
                        .frame(width: 36, height: 36)
                }
                .disabled(currentPageIndex >= max(0, manager.pages.count - 1))
                .accessibilityIdentifier("mreader.reader.nextPage")
            }

            let sliderBinding = Binding<Double>(get: { Double(currentPageIndex) }, set: { currentPageIndex = Int($0) })
            Slider(value: sliderBinding, in: 0...Double(max(0, manager.pages.count - 1)), step: 1.0).tint(.white)
                .environment(\.layoutDirection, readingDirection == .rightToLeft ? .rightToLeft : .leftToRight)

            HStack {
                Picker("reader.mode".localized, selection: readingModeRaw) {
                    Label("翻页", systemImage: "book").tag(ReadingMode.horizontalPage.rawValue)
                    Label("滚动", systemImage: "scroll").tag(ReadingMode.continuousScroll.rawValue)
                }
                .pickerStyle(.segmented)

                Picker("reader.direction".localized, selection: readingDirectionRaw) {
                    Image(systemName: "arrow.left").tag(ReadingDirection.rightToLeft.rawValue)
                    Image(systemName: "arrow.right").tag(ReadingDirection.leftToRight.rawValue)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .background(.ultraThinMaterial).environment(\.colorScheme, .dark)
    }

    private var readerTopControlBar: some View {
        HStack(spacing: 12) {
            Button {
                HapticManager.shared.play(.light)
                dismiss()
            } label: {
                Label("nav.back".localized, systemImage: "chevron.backward")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 72, minHeight: 40, alignment: .leading)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 4)

            Text(manager.pages.isEmpty ? "" : "\(currentPageIndex + 1) / \(manager.pages.count)")
                .font(.system(.headline, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(minWidth: 76, minHeight: 40)
                .accessibilityIdentifier("mreader.reader.progress")

            Spacer(minLength: 4)

            Menu {
                Button {
                    showOfflineTranslationStart = true
                } label: {
                    Label("offlineTranslation.startFromReader".localized, systemImage: "text.bubble.fill")
                }
                .accessibilityIdentifier("mreader.reader.offlineTranslationStart")
                Button {
                    showOfflineTranslationManager = true
                } label: {
                    Label("offlineTranslation.manage".localized, systemImage: "list.bullet.rectangle")
                }
                .accessibilityIdentifier("mreader.reader.offlineTranslationManage")
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 40)
            }
            .accessibilityLabel("offlineTranslation.menu".localized)
            .accessibilityIdentifier("mreader.reader.offlineTranslationMenu")

            Button {
                HapticManager.shared.play(.light)
                showComicSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("reader.settings".localized)
            .accessibilityIdentifier("mreader.reader.settings")
        }
        .contentShape(Rectangle())
    }

    private var comicSettingsSheet: some View {
        NavigationStack {
            Form {
                Section(header: Text("ocr.aiTranslation.sectionTitle".localized)) {
                    Toggle("ocr.enable".localized, isOn: Binding(
                        get: { comic.isOCREnabled },
                        set: { newValue in updateComic { $0.isOCREnabled = newValue } }
                    ))

                    Toggle("ocr.autoMagnify".localized, isOn: Binding(
                        get: { comic.isAutoOCRMagnificationEnabled },
                        set: { newValue in updateComic { $0.isAutoOCRMagnificationEnabled = newValue } }
                    ))
                    .disabled(!comic.isOCREnabled)

                    HStack {
                        Text("ocr.magnifySize".localized)
                        Slider(value: Binding(
                            get: { normalizedOCRTextScale(comic.ocrTextScale) },
                            set: { newValue in updateComic { $0.ocrTextScale = newValue } }
                        ), in: 0...1, step: 0.02)
                        Text(ocrTextSizeLabel)
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                    .disabled(!comic.isOCREnabled)

                    HStack {
                        Text("ocr.safeArea".localized)
                        Slider(value: Binding(
                            get: { comic.ocrSafeAreaInset },
                            set: { newValue in updateComic { $0.ocrSafeAreaInset = newValue } }
                        ), in: 0...0.2, step: 0.01)
                        Text("\(Int(comic.ocrSafeAreaInset * 100))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .disabled(!comic.isOCREnabled)

                    Toggle("ocr.aiTranslation.toggleTitle".localized, isOn: Binding(
                        get: { comic.isAITranslationEnabled },
                        set: { newValue in updateComic { $0.isAITranslationEnabled = newValue } }
                    ))

                    Picker("ocr.translationMode".localized, selection: Binding(
                        get: { comic.aiTranslationMode },
                        set: { newValue in
                            updateComic {
                                $0.aiTranslationModeRaw = newValue.rawValue
                                if newValue == .ocr {
                                    $0.isOCREnabled = true
                                }
                            }
                        }
                    )) {
                        Text("ocr.translationMode.ocr".localized).tag(AITranslationMode.ocr)
                        Text("ocr.translationMode.vision".localized).tag(AITranslationMode.vision)
                    }
                    .pickerStyle(.segmented)
                    .disabled(!comic.isAITranslationEnabled)

                    Toggle("ocr.autoTranslate".localized, isOn: Binding(
                        get: { comic.isAutoTranslationEnabled },
                        set: { newValue in updateComic { $0.isAutoTranslationEnabled = newValue } }
                    ))
                    .disabled(!comic.isAITranslationEnabled || (aiTranslationMode == .ocr && !comic.isOCREnabled))

                    Toggle("offlineTranslation.showLocal".localized, isOn: Binding(
                        get: { comic.isOfflineTranslationOverlayEnabled },
                        set: { newValue in updateComic { $0.isOfflineTranslationOverlayEnabled = newValue } }
                    ))

                    Toggle("ocr.appleTranslation".localized, isOn: $useAppleLowLatency)
                        .disabled(!comic.isAITranslationEnabled || aiTranslationMode != .ocr)
                    Text("ocr.appleTranslationFooter".localized)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Toggle("ocr.borderProgress".localized, isOn: $aiTranslationBorderProgressEnabled)
                        .disabled(!comic.isAITranslationEnabled)

                    Picker("ocr.colorStyle".localized, selection: $translationColorStyleRaw) {
                        ForEach(TranslationColorStyle.allCases, id: \.rawValue) { style in
                            Text(style.title).tag(style.rawValue)
                        }
                    }
                    .disabled(!comic.isAITranslationEnabled)

                    Picker("ocr.targetLanguage".localized, selection: $translationTargetLanguage) {
                        ForEach(TranslationTargetLanguage.allCases) { language in
                            Text(language.localizedTitle).tag(language.rawValue)
                        }
                    }

                    Picker("ocr.sourceLanguage".localized, selection: Binding(
                        get: { comic.translationSourceLanguageRaw },
                        set: { newValue in updateComic { $0.translationSourceLanguageRaw = newValue } }
                    )) {
                        ForEach(TranslationSourceLanguage.allCases) { language in
                            Text(language.localizedTitle).tag(language.rawValue)
                        }
                    }
                    .disabled(!comic.isAITranslationEnabled)
                }

                Section(header: Text("ocr.filter".localized), footer: Text("ocr.filterDescription".localized)) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("ocr.minTextSize".localized)
                            Slider(value: Binding(
                                get: { comic.ocrMinimumTextHeight },
                                set: { newValue in updateComic { $0.ocrMinimumTextHeight = newValue } }
                            ), in: 0.002...0.035, step: 0.001)
                        }

                        HStack(alignment: .center, spacing: 12) {
                            Text("reader.ocrFilterExample".localized)
                                .font(.system(size: ocrMinimumPreviewFontSize, weight: .semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Color.secondary.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                            VStack(alignment: .leading, spacing: 2) {
                                Text("reader.ocrFilterThreshold".localizedFormat(Int(comic.ocrMinimumTextHeight * 1000)))
                                    .font(.caption.monospacedDigit())
                                Text("reader.ocrFilterSmallText".localized)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(!comic.isOCREnabled)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("ocr.measuredTextFontSize".localized)
                            Slider(value: Binding(
                                get: { comic.measuredTextTranslationFontSize },
                                set: { newValue in
                                    updateComic {
                                        $0.measuredTextTranslationFontSize = ComicBook.clampedMeasuredTextTranslationFontSize(newValue)
                                    }
                                }
                            ), in: ComicBook.measuredTextTranslationFontSizeRange, step: 1)
                        }

                        Text("ocr.measuredTextFontSizeValue".localizedFormat(
                            Int(comic.measuredTextTranslationFontSize.rounded())
                        ))
                        .font(.caption.monospacedDigit())

                        Text("ocr.measuredTextFontSizeDescription".localized)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Divider()

                        HStack {
                            Text("ocr.minimumReadableTranslationFontSize".localized)
                            Slider(value: Binding(
                                get: { comic.minimumReadableTranslationFontSize },
                                set: { newValue in
                                    updateComic {
                                        $0.minimumReadableTranslationFontSize = ComicBook.clampedMinimumReadableTranslationFontSize(newValue)
                                    }
                                }
                            ), in: ComicBook.minimumReadableTranslationFontSizeRange, step: 1)
                        }
                        Text("ocr.minimumReadableTranslationFontSizeValue".localizedFormat(
                            Int(comic.minimumReadableTranslationFontSize.rounded())
                        ))
                        .font(.caption.monospacedDigit())
                        Text("ocr.minimumReadableTranslationFontSizeDescription".localized)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Toggle("ocr.inPlaceTranslation".localized, isOn: Binding(
                            get: { comic.prefersInPlaceTranslation },
                            set: { newValue in updateComic { $0.prefersInPlaceTranslation = newValue } }
                        ))
                        .disabled(!comic.isAITranslationEnabled)
                        Text("ocr.inPlaceTranslationDescription".localized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section(header: Text("reader.jumpToPage".localized)) {
                    HStack {
                        TextField("reader.pageNumber".localized, text: $jumpPageText)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                        Button("reader.jumpToPage".localized) {
                            jumpToPage()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Text("reader.currentPageOf".localizedFormat(currentPageIndex + 1, manager.pages.count))
                        .foregroundStyle(.secondary)
                }

                Section(header: Text("reader.bookmark".localized)) {
                    Button {
                        addBookmark()
                    } label: {
                        Label("reader.addBookmark".localizedFormat(currentPageIndex + 1), systemImage: "bookmark.fill")
                    }

                    if comic.bookmarks.isEmpty {
                        Text("reader.noBookmarks".localized)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(comic.bookmarks.sorted(by: { $0.pageIndex < $1.pageIndex })) { bookmark in
                            HStack(spacing: 12) {
                                Button {
                                    currentPageIndex = bookmark.pageIndex
                                    showComicSettings = false
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Label("reader.bookmarkPage".localizedFormat(bookmark.pageIndex + 1), systemImage: "bookmark")
                                        if !bookmark.note.isEmpty {
                                            Text(bookmark.note)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)

                                Button {
                                    removeBookmark(bookmark: bookmark)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 36, height: 36)
                                }
                                .buttonStyle(.plain)
                            }
                            .contextMenu {
                                Button {
                                    editingBookmark = bookmark
                                    bookmarkNoteText = bookmark.note
                                    showBookmarkNoteAlert = true
                                } label: {
                                    Label("reader.editBookmarkNote".localized, systemImage: "pencil")
                                }
                            }
                        }
                    }
                }

                Section(header: Text("reader.mode".localized)) {
                    Picker("reader.mode".localized, selection: readingModeRaw) {
                        Label("reader.mode.horizontalPage".localized, systemImage: "book").tag(ReadingMode.horizontalPage.rawValue)
                        Label("reader.mode.verticalPage".localized, systemImage: "arrow.up.and.down").tag(ReadingMode.verticalPage.rawValue)
                        Label("reader.mode.continuousScroll".localized, systemImage: "scroll").tag(ReadingMode.continuousScroll.rawValue)
                        Label("reader.mode.infiniteScroll".localized, systemImage: "infinity").tag(ReadingMode.infiniteScroll.rawValue)
                        Label("reader.mode.doublePage".localized, systemImage: "book.pages").tag(ReadingMode.doublePage.rawValue)
                        Label("reader.mode.guidedPanel".localized, systemImage: "rectangle.split.2x2").tag(ReadingMode.guidedPanel.rawValue)
                    }
                    .accessibilityIdentifier("mreader.reader.modePicker")

                    Picker("reader.direction".localized, selection: readingDirectionRaw) {
                        Label("reader.direction.leftToRight".localized, systemImage: "arrow.right").tag(ReadingDirection.leftToRight.rawValue)
                        Label("reader.direction.rightToLeft".localized, systemImage: "arrow.left").tag(ReadingDirection.rightToLeft.rawValue)
                    }

                    Picker("reader.animation".localized, selection: pageTurnAnimationRaw) {
                        Label("reader.animation.none".localized, systemImage: "circle.slash").tag(PageTurnAnimation.none.rawValue)
                        Label("reader.animation.slide".localized, systemImage: "rectangle.portrait.on.rectangle.portrait").tag(PageTurnAnimation.slide.rawValue)
                        Label("reader.animation.fade".localized, systemImage: "square.stack.3d.up").tag(PageTurnAnimation.fade.rawValue)
                        Label("reader.animation.curl".localized, systemImage: "book.pages").tag(PageTurnAnimation.curl.rawValue)
                    }

                    Picker("reader.fitMode".localized, selection: imageFitModeRaw) {
                        Label("reader.fitMode.fitScreen".localized, systemImage: "rectangle.inset.filled").tag(ImageFitMode.fitScreen.rawValue)
                        Label("reader.fitMode.fitWidth".localized, systemImage: "arrow.left.and.right").tag(ImageFitMode.fitWidth.rawValue)
                        Label("reader.fitMode.fitHeight".localized, systemImage: "arrow.up.and.down").tag(ImageFitMode.fitHeight.rawValue)
                        Label("reader.fitMode.original".localized, systemImage: "1.magnifyingglass").tag(ImageFitMode.original.rawValue)
                    }

                    Picker("reader.scrollSpeed".localized, selection: scrollSpeedRaw) {
                        Label("reader.scrollSpeed.slow".localized, systemImage: "tortoise").tag(ScrollSpeed.slow.rawValue)
                        Label("reader.scrollSpeed.standard".localized, systemImage: "circle").tag(ScrollSpeed.standard.rawValue)
                        Label("reader.scrollSpeed.fast".localized, systemImage: "hare").tag(ScrollSpeed.fast.rawValue)
                    }
                }
            }
            .navigationTitle(comic.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("nav.done".localized) { showComicSettings = false }
                    .accessibilityIdentifier("mreader.reader.settings.done")
            }
        }
        .accessibilityIdentifier("mreader.reader.settings.sheet")
    }

    private func initializeReadingPresetIfNeeded() async {
        guard !comic.hasInitializedReadingPreset else { return }

        let preset = await detectInitialReadingPreset()
        await MainActor.run {
            guard !comic.hasInitializedReadingPreset else { return }
            comic.readingModeRaw = preset.readingMode.rawValue
            comic.pageTurnAnimationRaw = preset.pageTurnAnimation.rawValue
            comic.imageFitModeRaw = preset.imageFitMode.rawValue
            comic.isAutoOCRMagnificationEnabled = false
            comic.isAutoTranslationEnabled = false
            comic.hasInitializedReadingPreset = true
            comic.metadataUpdatedAt = Date()
            MReaderLog.reader.debug(
                "initial preset comic=\(comic.id.uuidString, privacy: .public) mode=\(comic.readingModeRaw, privacy: .public) animation=\(comic.pageTurnAnimationRaw, privacy: .public) fit=\(comic.imageFitModeRaw, privacy: .public) reason=\(preset.reason, privacy: .public)"
            )
            onComicUpdate(comic)
        }
    }

    private func applyEPUBPresetBeforeFirstOpen() {
        guard isEPUBComic, !comic.hasBeenOpened else { return }
        comic.readingModeRaw = ReadingMode.horizontalPage.rawValue
        comic.pageTurnAnimationRaw = PageTurnAnimation.curl.rawValue
        comic.imageFitModeRaw = ImageFitMode.fitScreen.rawValue
        comic.hasInitializedReadingPreset = true
        comic.metadataUpdatedAt = Date()
        onComicUpdate(comic)
    }

    private func detectInitialReadingPreset() async -> InitialReadingPreset {
        if isEPUBComic {
            return InitialReadingPreset(
                readingMode: .horizontalPage,
                pageTurnAnimation: .curl,
                imageFitMode: .fitScreen,
                reason: "epub"
            )
        }
        if isPDFComic {
            return InitialReadingPreset(
                readingMode: InitialReadingPreset.longStrip.readingMode,
                pageTurnAnimation: InitialReadingPreset.longStrip.pageTurnAnimation,
                imageFitMode: InitialReadingPreset.longStrip.imageFitMode,
                reason: "pdf"
            )
        }
        let sampleIndices = ReadingPresetSamplePagePolicy.pageIndices(totalPages: manager.pages.count)
        guard !sampleIndices.isEmpty else {
            MReaderLog.reader.notice(
                "initial preset fallback reason=noSamplePages comic=\(comic.id.uuidString, privacy: .public)"
            )
            return InitialReadingPreset.normalPage
        }
        var ratios: [CGFloat] = []
        for index in sampleIndices {
            guard manager.pages.indices.contains(index),
                  let size = await pagePixelSize(for: manager.pages[index].url) else {
                MReaderLog.reader.notice(
                    "initial preset sample skipped comic=\(comic.id.uuidString, privacy: .public) page=\(index + 1, privacy: .public)"
                )
                continue
            }
            ratios.append(size.height / max(size.width, 1))
        }
        guard let medianRatio = medianRatio(ratios) else {
            MReaderLog.reader.notice(
                "initial preset fallback reason=samplePageSizeUnavailable comic=\(comic.id.uuidString, privacy: .public) samples=\(String(describing: sampleIndices.map { $0 + 1 }), privacy: .public)"
            )
            return InitialReadingPreset.normalPage
        }
        if medianRatio > 1.8 {
            return InitialReadingPreset(
                readingMode: .continuousScroll,
                pageTurnAnimation: .none,
                imageFitMode: .fitWidth,
                reason: String(format: "median ratio %.3f pages %@", medianRatio, sampleIndices.map { "\($0 + 1)" }.joined(separator: ","))
            )
        }
        return InitialReadingPreset(
            readingMode: .horizontalPage,
            pageTurnAnimation: .slide,
            imageFitMode: .fitScreen,
            reason: String(format: "median ratio %.3f pages %@", medianRatio, sampleIndices.map { "\($0 + 1)" }.joined(separator: ","))
        )
    }

    private func medianRatio(_ ratios: [CGFloat]) -> CGFloat? {
        guard !ratios.isEmpty else { return nil }
        let sortedRatios = ratios.sorted()
        let middle = sortedRatios.count / 2
        if sortedRatios.count.isMultiple(of: 2) {
            return (sortedRatios[middle - 1] + sortedRatios[middle]) / 2
        }
        return sortedRatios[middle]
    }

    private var isEPUBComic: Bool {
        hasDocumentExtension("epub")
    }

    private var isPDFComic: Bool {
        hasDocumentExtension("pdf")
    }

    private func hasDocumentExtension(_ expectedExtension: String) -> Bool {
        let rawValues = [comic.libraryPath, comic.chapterPath, comic.sourceURL]
        if rawValues.contains(where: { path in
            guard let path else { return false }
            if let url = URL(string: path), url.scheme != nil {
                return url.pathExtension.lowercased() == expectedExtension
            }
            return URL(fileURLWithPath: path).pathExtension.lowercased() == expectedExtension
        }) {
            return true
        }
        let chapterType = comic.chapterTypeRaw?.lowercased()
        return chapterType == expectedExtension
    }

    private func pagePixelSize(for url: URL) async -> CGSize? {
        if RemotePageLoader.isRemotePageURL(url) {
            if let request = RemotePageLoader.RemotePageRequest(url: url) {
                let cachedURL = RemotePageLoader.pageCacheURL(sourceID: request.sourceID, bookID: request.bookID, pageIndex: request.pageIndex)
                if let data = try? Data(contentsOf: cachedURL) {
                    return imagePixelSize(from: data)
                }
            }
            guard let data = await RemotePageLoader.imageData(forRemotePageURL: url) else { return nil }
            return imagePixelSize(from: data)
        }
        if ComicManager.isArchivePageURL(url) {
            return await Task.detached(priority: .utility) {
                guard let data = ComicManager.imageData(forArchivePageURL: url) else { return nil }
                return imagePixelSize(from: data)
            }.value
        }
        return await Task.detached(priority: .utility) {
            imagePixelSize(from: url)
        }.value
    }

    private func updateComic(_ mutate: (inout ComicBook) -> Void) {
        HapticManager.shared.play(.light)
        let updatedComic = ReaderComicMutation.applying(mutate, to: comic, now: Date())
        comic = updatedComic
        if !updatedComic.isOCREnabled {
            isOCRMagnificationVisible = false
        }
        onComicUpdate(updatedComic)
    }

    private var ocrMinimumPreviewFontSize: CGFloat {
        min(max(CGFloat(comic.ocrMinimumTextHeight) * 900, 2), 32)
    }

    private var ocrTextSizeLabel: String {
        switch normalizedOCRTextScale(comic.ocrTextScale) {
        case ..<0.2:
            return "reader.ocrTextSizeSmall".localized
        case ..<0.55:
            return "reader.ocrTextSizeStandard".localized
        case ..<0.82:
            return "reader.ocrTextSizeLarge".localized
        default:
            return "reader.ocrTextSizeExtraLarge".localized
        }
    }

    private func normalizedOCRTextScale(_ rawValue: Double) -> Double {
        if rawValue > 1 {
            return min(max((rawValue - 0.8) / 2.4, 0), 1)
        }
        return min(max(rawValue, 0), 1)
    }

    private func jumpToPage() {
        let pageNumber = Int(jumpPageText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        guard pageNumber > 0 else {
            HapticManager.shared.play(.warning)
            return
        }
        let targetIndex = min(max(pageNumber - 1, 0), max(0, manager.pages.count - 1))
        HapticManager.shared.play(.medium)
        currentPageIndex = targetIndex
        lastSavedScrollProgress = 0
        lastSavedScrollPageProgress = 0
        persistReadingProgress(pageIndex: targetIndex, scrollProgress: 0, scrollPageProgress: 0, reason: "jumpToPage", force: true)
        scrollJumpRequestID = UUID()
        jumpPageText = ""
        showComicSettings = false
    }

    private func addBookmark() {
        guard !comic.bookmarks.contains(where: { $0.pageIndex == currentPageIndex }) else {
            HapticManager.shared.play(.warning)
            return
        }
        HapticManager.shared.play(.medium)
        let bookmark = ComicBookmark(pageIndex: currentPageIndex)
        comic.bookmarks.append(bookmark)
        editingBookmark = bookmark
        bookmarkNoteText = ""
        showBookmarkNoteAlert = true
        onComicUpdate(comic)
    }

    private func removeBookmark(bookmark: ComicBookmark) {
        HapticManager.shared.play(.light)
        comic.bookmarks.removeAll { $0.id == bookmark.id }
        onComicUpdate(comic)
    }

    private func updateBookmarkNote(bookmark: ComicBookmark, note: String) {
        guard let index = comic.bookmarks.firstIndex(where: { $0.id == bookmark.id }) else { return }
        HapticManager.shared.play(.light)
        comic.bookmarks[index].note = note
        onComicUpdate(comic)
    }

    private func recordReaderOpenIfNeeded() {
        guard !didRecordReaderOpen else { return }
        didRecordReaderOpen = true
        comic.hasBeenOpened = true
        activityLastRecordedAt = Date()
        activityLastPageIndex = currentPageIndex
        let clampedValue = min(max(currentPageIndex, 0), max(0, manager.pages.count - 1))
        MReaderLog.reader.debug(
            "progress open comic=\(comic.id.uuidString, privacy: .public) restoredPage=\(clampedValue, privacy: .public) storedPage=\(comic.currentPageIndex, privacy: .public) mode=\(comic.readingModeRaw, privacy: .public)"
        )
        persistReadingProgress(pageIndex: clampedValue, reason: "readerOpen", force: true)
    }

    private func saveScrollPosition(pageIndex: Int, progress: Double, pageProgress: Double) {
        if pageIndex != currentPageIndex ||
            abs(progress - lastSavedScrollProgress) > 0.001 ||
            abs(pageProgress - lastSavedScrollPageProgress) > 0.004 {
            recordReaderInteraction()
        }
        persistReadingProgress(pageIndex: pageIndex, scrollProgress: progress, scrollPageProgress: pageProgress, reason: "scrollVisiblePage", force: false)
    }

    private func updateAITranslationProgress(_ isInProgress: Bool) {
        let next = max(0, activeTranslationCount + (isInProgress ? 1 : -1))
        guard next != activeTranslationCount else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            activeTranslationCount = next
        }
    }

    private func persistReadingProgress(pageIndex: Int, scrollProgress: Double? = nil, scrollPageProgress: Double? = nil, reason: String, force: Bool) {
        let clampedPageIndex = ReaderProgressPolicy.clampedPageIndex(
            pageIndex,
            loadedPageCount: manager.pages.count,
            declaredPageCount: comic.totalPages
        )
        let clampedProgress = min(max(scrollProgress ?? comic.scrollProgress, 0), 1)
        let clampedPageProgress = min(max(scrollPageProgress ?? comic.scrollPageProgress, 0), 1)
        let now = Date()
        if !force {
            guard now.timeIntervalSince(lastProgressPersistDate) >= 0.7 else { return }
        }
        guard force ||
                clampedPageIndex != comic.currentPageIndex ||
                abs(clampedProgress - lastSavedScrollProgress) > 0.003 ||
                abs(clampedPageProgress - lastSavedScrollPageProgress) > 0.01 else { return }

        lastProgressPersistDate = now
        currentPageIndex = clampedPageIndex
        lastSavedScrollProgress = clampedProgress
        lastSavedScrollPageProgress = clampedPageProgress
        comic.currentPageIndex = clampedPageIndex
        comic.furthestPageIndex = max(comic.furthestPageIndex, clampedPageIndex)
        comic.progressUpdatedAt = now
        comic.hasBeenOpened = true
        comic.scrollProgress = clampedProgress
        comic.scrollPageProgress = clampedPageProgress
        comic.lastReadAt = Date()
        MReaderLog.reader.debug(
            "progress persist reason=\(reason, privacy: .public) comic=\(comic.id.uuidString, privacy: .public) page=\(clampedPageIndex, privacy: .public) global=\(String(format: "%.4f", clampedProgress), privacy: .public) pageProgress=\(String(format: "%.4f", clampedPageProgress), privacy: .public)"
        )
        onComicUpdate(comic)
    }

    private func recordReadingActivity() {
        let now = Date()
        let pageIndex = min(max(currentPageIndex, 0), max(0, manager.pages.count - 1))
        ReadingActivityStore.shared.record(
            comicID: comic.id,
            previousDate: activityLastRecordedAt,
            now: now,
            previousPageIndex: activityLastPageIndex,
            currentPageIndex: pageIndex,
            completed: comic.hasBeenOpened && pageIndex >= max(0, manager.pages.count - 1)
        )
        activityLastRecordedAt = now
        activityLastPageIndex = pageIndex
    }

    private func preloadPages(around index: Int) {
        guard !manager.pages.isEmpty else { return }
        let isContinuous = readingMode == .continuousScroll || readingMode == .infiniteScroll
        let scrollDirection = index >= lastPrefetchPageIndex ? 1 : -1
        lastPrefetchPageIndex = index
        if comic.sourceType == .komga {
            RemotePagePrefetcher.shared.updateWindow(
                currentPageIndex: index,
                pages: manager.pages,
                readingDirection: readingDirection,
                readingMode: readingMode,
                scrollDirection: scrollDirection
            )
        }

        let preferredIndices = ReaderPrefetchPolicy.pageIndices(
            currentPageIndex: index,
            pageCount: manager.pages.count,
            readingDirection: readingDirection,
            readingMode: readingMode,
            scrollDirection: scrollDirection,
            forwardCount: isContinuous ? 6 : 4,
            backwardCount: 2,
            includesCurrentPage: false
        )
        let urls = preferredIndices.compactMap { pageIndex -> URL? in
            guard manager.pages.indices.contains(pageIndex) else { return nil }
            return manager.pages[pageIndex].url
        }
        ReaderImageCache.shared.preload(
            urls,
            maxPixelSize: isContinuous ? 8192 : 4096,
            maximumConcurrent: isContinuous ? 2 : 3,
            delay: isContinuous ? 0.05 : 0.1
        )
    }

    private func scheduleTranslationPrefetch(around index: Int) {
        translationPrefetchTask?.cancel()
        translationPrefetchTask = nil
        guard comic.isAutoTranslationEnabled,
              comic.isAITranslationEnabled,
              comic.aiTranslationMode == .vision || comic.isOCREnabled,
              let configuration = AIProviderStore.shared.activeConfiguration() else {
            return
        }

        let candidates = AITranslationPrefetchPolicy.pageIndices(
            currentPageIndex: index,
            pageCount: manager.pages.count,
            isAutoTranslationEnabled: comic.isAutoTranslationEnabled
        )
        guard !candidates.isEmpty else { return }
        let comicID = comic.id
        let mode = comic.aiTranslationMode
        let target = selectedTranslationTarget
        let isRightToLeft = readingDirection == .rightToLeft
        let minimumTextHeight = comic.ocrMinimumTextHeight
        let safeAreaInset = comic.ocrSafeAreaInset
        let usesVisualVerification = ocrVisualVerificationEnabled
        let ocrRecognitionMode = OCRRecognitionMode(rawValue: ocrRecognitionModeRaw) ?? .adaptive
        let translationPrompt = translationStyleInstructions
        let visionPrompt = visionTranslationPromptTemplate

        translationPrefetchTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(0.9))
                while isAITranslationInProgress && !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(250))
                }
                for pageIndex in candidates {
                    try Task.checkCancellation()
                    guard comic.id == comicID, comic.isAutoTranslationEnabled else { return }
                    let page = manager.pages[pageIndex]
                    guard let image = await ReaderImageCache.shared.loadImage(
                        for: page.url,
                        maxPixelSize: 4096
                    ) else {
                        continue
                    }
                    try Task.checkCancellation()
                    let request = AITranslationPageRequest(
                        pageURL: page.url,
                        image: image,
                        mode: mode,
                        configuration: configuration,
                        target: target,
                        translationPromptTemplate: translationPrompt,
                        visionPromptTemplate: visionPrompt,
                        isRightToLeft: isRightToLeft,
                        minimumTextHeight: minimumTextHeight,
                        ocrRecognitionMode: ocrRecognitionMode,
                        safeAreaInset: safeAreaInset,
                        usesVisualOCRVerification: usesVisualVerification,
                        viewportAspect: 2.0,
                        sourceLanguagePreference: comic.translationSourceLanguage,
                        previousContext: "",
                        contextScopeID: TranslationContextBuilder.scopeID(
                            comicID: comicID,
                            target: target
                        ),
                        pageIndex: pageIndex
                    )
                    _ = try await AITranslationPageCoordinator.shared.translatedBlocks(for: request)
                    MReaderLog.aiTranslation.debug(
                        "AI translation prefetched comic=\(comicID.uuidString, privacy: .public) page=\(pageIndex, privacy: .public)"
                    )
                }
            } catch is CancellationError {
                MReaderLog.aiTranslation.debug(
                    "AI translation prefetch cancelled comic=\(comicID.uuidString, privacy: .public)"
                )
            } catch {
                MReaderLog.aiTranslation.notice("translation prefetch failed comic=\(comicID, privacy: .public) reason=\(MReaderLog.describe(error), privacy: .public)")
            }
        }
    }

    private func previousPage() {
        guard currentPageIndex > 0 else {
            HapticManager.shared.play(.warning)
            return
        }
        HapticManager.shared.play(.light)
        pageTurnDirection = -1
        currentPageIndex = max(0, currentPageIndex - 1)
    }

    private func nextPage() {
        guard currentPageIndex < max(0, manager.pages.count - 1) else {
            HapticManager.shared.play(.warning)
            return
        }
        HapticManager.shared.play(.light)
        pageTurnDirection = 1
        currentPageIndex = min(max(0, manager.pages.count - 1), currentPageIndex + 1)
    }

    private func previousContainerPage() {
        if readingMode == .doublePage {
            let leftPageIndex = currentPageIndex - currentPageIndex % 2
            guard leftPageIndex > 0 else {
                HapticManager.shared.play(.warning)
                return
            }
            HapticManager.shared.play(.light)
            pageTurnDirection = -1
            currentPageIndex = max(0, leftPageIndex - 2)
        } else {
            previousPage()
        }
    }

    private func nextContainerPage() {
        if readingMode == .doublePage {
            let leftPageIndex = currentPageIndex - currentPageIndex % 2
            guard leftPageIndex + 2 <= max(0, manager.pages.count - 1) else {
                HapticManager.shared.play(.warning)
                return
            }
            HapticManager.shared.play(.light)
            pageTurnDirection = 1
            currentPageIndex = min(max(0, manager.pages.count - 1), leftPageIndex + 2)
        } else {
            nextPage()
        }
    }
    
    private func toggleControls() {
        if showControls {
            HapticManager.shared.play(.light)
            hideControls()
        } else {
            showControlsIfNeeded()
        }
    }

    private func showControlsIfNeeded() {
        recordReaderInteraction()
        HapticManager.shared.play(.light)
        if !showControls {
            withAnimation(.easeInOut(duration: 0.18)) {
                showControls = true
            }
        }
    }

    private func hideControls() {
        recordReaderInteraction()
        withAnimation(.easeInOut(duration: 0.18)) {
            showControls = false
        }
    }

    private func recordReaderInteraction() {
        lastReaderInteractionAt = Date()
    }

    private func checkBurnInProtection(now: Date = Date()) {
        guard isBurnInProtectionEnabled,
              !isBurnInProtectionLocked,
              now.timeIntervalSince(lastReaderInteractionAt) >= BurnInProtectionPolicy.timeout else { return }
        recordReadingActivity()
        persistReadingProgress(pageIndex: currentPageIndex, reason: "burnInProtection", force: true)
        UIApplication.shared.isIdleTimerDisabled = false
        HapticManager.shared.play(.warning)
        isBurnInProtectionLocked = true
    }

    private func completeTwoFingerDismiss() {
        guard !isDismissAnimating else { return }
        isDismissAnimating = true
        HapticManager.shared.play(.medium)
        recordReadingActivity()
        persistReadingProgress(pageIndex: currentPageIndex, reason: "twoFingerDismiss", force: true)
        withAnimation(.easeIn(duration: 0.24)) {
            dismissGestureProgress = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            dismiss()
        }
    }

}

nonisolated enum BurnInProtectionPolicy {
    static let timeout: TimeInterval = 4 * 60 * 60
}

nonisolated enum ReaderProgressPolicy {
    static func clampedPageIndex(_ pageIndex: Int, loadedPageCount: Int, declaredPageCount: Int) -> Int {
        let pageCount = max(loadedPageCount, declaredPageCount)
        return min(max(pageIndex, 0), max(0, pageCount - 1))
    }
}

// MARK: - 支持 AI 的图片加载器
private struct ReaderControlsDoubleTapOverlay: View {
    let isEnabled: Bool
    let onToggle: () -> Void

    var body: some View {
        ReaderControlsDoubleTapRecognizer(isEnabled: isEnabled, onToggle: onToggle)
    }
}

private struct ReaderControlsDoubleTapRecognizer: UIViewRepresentable {
    let isEnabled: Bool
    let onToggle: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isEnabled: isEnabled, onToggle: onToggle)
    }

    func makeUIView(context: Context) -> UIView {
        let view = InstallingView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.onToggle = onToggle
        context.coordinator.attach(to: uiView.window)
    }

    final class InstallingView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.attach(to: window)
        }

        deinit {
            // UIView 由 SwiftUI 主线程层级持有，dealloc 在主线程发生；
            // assumeIsolated 把这一前提显式化并在违反时立即暴露。
            MainActor.assumeIsolated {
                coordinator?.detach()
            }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var isEnabled: Bool
        var onToggle: () -> Void
        private weak var hostView: UIView?
        private var recognizer: UITapGestureRecognizer?

        init(isEnabled: Bool, onToggle: @escaping () -> Void) {
            self.isEnabled = isEnabled
            self.onToggle = onToggle
        }

        func attach(to view: UIView?) {
            if hostView == nil && view == nil {
                return
            }
            if let hostView, let view, hostView === view {
                return
            }
            detach()
            guard let view else { return }
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
            recognizer.numberOfTapsRequired = 2
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            view.addGestureRecognizer(recognizer)
            self.hostView = view
            self.recognizer = recognizer
        }

        func detach() {
            if let recognizer {
                recognizer.view?.removeGestureRecognizer(recognizer)
            }
            recognizer = nil
            hostView = nil
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            onToggle()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard isEnabled, let view = gestureRecognizer.view else { return false }
            guard !ReaderGestureTouchFilter.isInteractiveTouch(touch) else { return false }
            let location = touch.location(in: view)
            let bounds = view.bounds
            guard bounds.width > 1, bounds.height > 1 else { return false }
            return location.x >= bounds.width * 0.35 &&
                location.x <= bounds.width * 0.65 &&
                location.y >= bounds.height * 0.25 &&
                location.y <= bounds.height * 0.75
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

private struct ReaderPageTapOverlay: View {
    let isEnabled: Bool
    let onPreviousPage: () -> Void
    let onNextPage: () -> Void
    let onLongPress: () -> Void

    var body: some View {
        ReaderPageTapRecognizer(
            isEnabled: isEnabled,
            onPreviousPage: onPreviousPage,
            onNextPage: onNextPage,
            onLongPress: onLongPress
        )
    }
}

private struct ReaderPageTapRecognizer: UIViewRepresentable {
    let isEnabled: Bool
    let onPreviousPage: () -> Void
    let onNextPage: () -> Void
    let onLongPress: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isEnabled: isEnabled,
            onPreviousPage: onPreviousPage,
            onNextPage: onNextPage,
            onLongPress: onLongPress
        )
    }

    func makeUIView(context: Context) -> UIView {
        let view = InstallingView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.onPreviousPage = onPreviousPage
        context.coordinator.onNextPage = onNextPage
        context.coordinator.onLongPress = onLongPress
        context.coordinator.attach(to: uiView.window)
    }

    final class InstallingView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.attach(to: window)
        }

        deinit {
            MainActor.assumeIsolated {
                coordinator?.detach()
            }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var isEnabled: Bool
        var onPreviousPage: () -> Void
        var onNextPage: () -> Void
        var onLongPress: () -> Void
        private weak var hostView: UIView?
        private var recognizer: UITapGestureRecognizer?
        private var longPressRecognizer: UILongPressGestureRecognizer?

        init(isEnabled: Bool, onPreviousPage: @escaping () -> Void, onNextPage: @escaping () -> Void, onLongPress: @escaping () -> Void) {
            self.isEnabled = isEnabled
            self.onPreviousPage = onPreviousPage
            self.onNextPage = onNextPage
            self.onLongPress = onLongPress
        }

        func attach(to view: UIView?) {
            if hostView == nil && view == nil {
                return
            }
            if let hostView, let view, hostView === view {
                return
            }
            detach()
            guard let view else { return }
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            recognizer.numberOfTapsRequired = 1
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
            longPress.minimumPressDuration = 0.55
            longPress.allowableMovement = 18
            longPress.cancelsTouchesInView = false
            longPress.delegate = self
            recognizer.require(toFail: longPress)
            view.addGestureRecognizer(recognizer)
            view.addGestureRecognizer(longPress)
            self.hostView = view
            self.recognizer = recognizer
            self.longPressRecognizer = longPress
        }

        func detach() {
            if let recognizer {
                recognizer.view?.removeGestureRecognizer(recognizer)
            }
            if let longPressRecognizer {
                longPressRecognizer.view?.removeGestureRecognizer(longPressRecognizer)
            }
            recognizer = nil
            longPressRecognizer = nil
            hostView = nil
        }

        @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began else { return }
            onLongPress()
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            let location = recognizer.location(in: view)
            let xRatio = location.x / max(view.bounds.width, 1)
            if xRatio < 0.35 {
                onPreviousPage()
            } else if xRatio > 0.65 {
                onNextPage()
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard isEnabled, let view = gestureRecognizer.view else { return false }
            guard !ReaderGestureTouchFilter.isInteractiveTouch(touch) else { return false }
            let location = touch.location(in: view)
            let bounds = view.bounds
            guard bounds.width > 1, bounds.height > 1 else { return false }
            if gestureRecognizer is UILongPressGestureRecognizer {
                return true
            }
            let xRatio = location.x / bounds.width
            return xRatio < 0.35 || xRatio > 0.65
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

private enum ReaderGestureTouchFilter {
    static func isInteractiveTouch(_ touch: UITouch) -> Bool {
        var view = touch.view
        while let current = view {
            if current is UIControl ||
                current is UINavigationBar ||
                current is UIToolbar ||
                current is UITextField ||
                current is UITextView {
                return true
            }
            let typeName = String(describing: type(of: current))
            if typeName.contains("NavigationBar") ||
                typeName.contains("Toolbar") ||
                typeName.contains("TextField") {
                return true
            }
            view = current.superview
        }
        return false
    }
}

private struct PageHeightPreferenceKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]

    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newValue in newValue })
    }
}

nonisolated enum ReaderVisiblePageDetector {
    static func visiblePageIndex(frames: [Int: CGRect], viewport: CGRect) -> Int? {
        guard !frames.isEmpty, viewport.width > 0, viewport.height > 0 else { return nil }
        let viewportCenterY = viewport.midY
        let candidates = frames.compactMap { index, frame -> (index: Int, visibleArea: CGFloat, centerDistance: CGFloat)? in
            let intersection = frame.intersection(viewport)
            guard !intersection.isNull, intersection.width > 1, intersection.height > 1 else { return nil }
            return (
                index: index,
                visibleArea: intersection.width * intersection.height,
                centerDistance: abs(frame.midY - viewportCenterY)
            )
        }
        return candidates.max { lhs, rhs in
            if abs(lhs.visibleArea - rhs.visibleArea) > 1 {
                return lhs.visibleArea < rhs.visibleArea
            }
            if abs(lhs.centerDistance - rhs.centerDistance) > 0.5 {
                return lhs.centerDistance > rhs.centerDistance
            }
            return lhs.index > rhs.index
        }?.index
    }
}

private struct PageFramePreferenceKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]

    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newValue in newValue })
    }
}

private struct ScrollViewportSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

private struct ScrollViewAccessor: UIViewRepresentable {
    let onResolve: (UIScrollView) -> Void
    let onScroll: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScroll: onScroll)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        DispatchQueue.main.async {
                if let scrollView = view.enclosingScrollView {
                    context.coordinator.attach(to: scrollView)
                    onResolve(scrollView)
            }
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            if let scrollView = uiView.enclosingScrollView {
                context.coordinator.onScroll = onScroll
                context.coordinator.attach(to: scrollView)
                onResolve(scrollView)
            }
        }
    }

    final class Coordinator {
        var onScroll: () -> Void
        weak var scrollView: UIScrollView?
        private var contentOffsetObservation: NSKeyValueObservation?

        init(onScroll: @escaping () -> Void) {
            self.onScroll = onScroll
        }

        func attach(to scrollView: UIScrollView) {
            scrollView.scrollsToTop = false
            guard self.scrollView !== scrollView else { return }
            self.scrollView = scrollView
            contentOffsetObservation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                guard let self else { return }
                // UIScrollView 的 contentOffset 变化只发生在主线程；
                // assumeIsolated 让编译器认可这条路径并保留运行时校验。
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        self.onScroll()
                    }
                } else {
                    DispatchQueue.main.async {
                        self.onScroll()
                    }
                }
            }
        }
    }
}

private struct ScrollsToTopDisabledView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        DispatchQueue.main.async {
            context.coordinator.disableScrollsToTop(from: view.window)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.disableScrollsToTop(from: uiView.window)
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.restore()
    }

    final class Coordinator {
        private var originalStates: [ObjectIdentifier: (scrollView: WeakScrollView, scrollsToTop: Bool)] = [:]

        func disableScrollsToTop(from window: UIWindow?) {
            guard let window else { return }
            let scrollViews = window.allScrollViews
            let liveIDs = Set(scrollViews.map(ObjectIdentifier.init))
            originalStates = originalStates.filter { id, state in
                guard let scrollView = state.scrollView.value else { return false }
                return liveIDs.contains(id) && scrollView.window === window
            }
            for scrollView in scrollViews {
                let id = ObjectIdentifier(scrollView)
                if originalStates[id] == nil {
                    originalStates[id] = (WeakScrollView(scrollView), scrollView.scrollsToTop)
                }
                scrollView.scrollsToTop = false
            }
        }

        func restore() {
            for (_, state) in originalStates {
                state.scrollView.value?.scrollsToTop = state.scrollsToTop
            }
            originalStates.removeAll()
        }
    }

    final class WeakScrollView {
        weak var value: UIScrollView?

        init(_ value: UIScrollView) {
            self.value = value
        }
    }
}

private extension UIView {
    var enclosingScrollView: UIScrollView? {
        if let scrollView = self as? UIScrollView {
            return scrollView
        }
        return superview?.enclosingScrollView
    }

    var allScrollViews: [UIScrollView] {
        var result: [UIScrollView] = []
        if let scrollView = self as? UIScrollView {
            result.append(scrollView)
        }
        for subview in subviews {
            result.append(contentsOf: subview.allScrollViews)
        }
        return result
    }
}

struct ContinuousScrollReader: View {
    private static let coordinateSpaceName = "mreader.readerScroll"

    let pages: [ComicPage]
    @Binding var currentPageIndex: Int
    let readingMode: ReadingMode
    let scrollSpeed: ScrollSpeed
    let comic: ComicBook
    let translateRequestID: UUID
    let ocrMagnifyRequestID: UUID
    let isOCRMagnificationVisible: Bool
    let targetLanguage: String
    let scrollJumpRequestID: UUID
    let scrollProgress: Double
    let scrollPageProgress: Double
    let onScrollPositionChange: (Int, Double, Double) -> Void
    let onTranslationStateChange: (Bool) -> Void
    let areControlsVisible: Bool
    let onShowControls: () -> Void
    let onHideControls: () -> Void

    @State private var scrollView: UIScrollView?
    @State private var pageHeights: [Int: CGFloat] = [:]
    @State private var pageFrames: [Int: CGRect] = [:]
    @State private var viewportSize: CGSize = .zero
    @State private var didRestorePosition = false
    @State private var lastStepTime = Date.distantPast
    @State private var lastScrollPositionNotifyDate = Date.distantPast
    @State private var visiblePageUpdateWorkItem: DispatchWorkItem?
    @State private var lastStableContentOffsetY: CGFloat = 0
    @State private var allowTopOffsetUntil = Date.distantPast
    @State private var lastPageFrameCommitDate = Date.distantPast

    var body: some View {
        GeometryReader { viewportProxy in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(pages) { page in
                            LocalImageView(
                                url: page.url,
                                comic: comic,
                                comicID: comic.id,
                                pageIndex: page.index,
                                isOCREnabled: comic.isOCREnabled,
                                isAITranslationEnabled: comic.isAITranslationEnabled,
                                isAutoTranslationEnabled: comic.isAutoTranslationEnabled && page.index == currentPageIndex,
                                aiTranslationModeRaw: comic.aiTranslationModeRaw,
                                translationSourceLanguageRaw: comic.translationSourceLanguageRaw,
                                translateRequestID: translateRequestID,
                                ocrMagnifyRequestID: ocrMagnifyRequestID,
                                isOCRMagnificationVisible: isOCRMagnificationVisible && page.index == currentPageIndex,
                                ocrTextScale: comic.ocrTextScale,
                                ocrSafeAreaInset: comic.ocrSafeAreaInset,
                                ocrMinimumTextHeight: comic.ocrMinimumTextHeight,
                                isRightToLeftReading: comic.readingDirectionRaw == ReadingDirection.rightToLeft.rawValue,
                                targetLanguage: targetLanguage,
                                imageFitMode: .fitWidth,
                                visionViewportAspect: max(viewportProxy.size.height / max(viewportProxy.size.width, 1), 1.25),
                                placeholderHeight: placeholderHeight(for: page.url, viewport: viewportProxy.size),
                                imageLoadDelay: 0,
                                showsLoadingIndicator: page.index == currentPageIndex,
                                isPageTapGestureEnabled: !areControlsVisible,
                                onTranslationStateChange: page.index == currentPageIndex ? onTranslationStateChange : { _ in },
                                onPreviousPage: { stepScroll(-1) },
                                onNextPage: { stepScroll(1) },
                                areControlsVisible: areControlsVisible,
                                onShowControls: onShowControls,
                                onHideControls: onHideControls
                            )
                            .frame(maxWidth: .infinity)
                            .id(page.index)
                            .background(
                                GeometryReader { geo in
                                    Color.clear
                                        .preference(key: PageHeightPreferenceKey.self, value: [page.index: max(geo.size.height, 1)])
                                        .preference(
                                            key: PageFramePreferenceKey.self,
                                            value: [page.index: geo.frame(in: .named(Self.coordinateSpaceName))]
                                        )
                                }
                            )
                        }
                    }
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: ScrollViewportSizePreferenceKey.self,
                                value: viewportProxy.size == .zero ? geo.size : viewportProxy.size
                            )
                        }
                    )
                }
                .coordinateSpace(name: Self.coordinateSpaceName)
                .background(ScrollViewAccessor(
                    onResolve: { resolvedScrollView in
                        if scrollView !== resolvedScrollView {
                            scrollView = resolvedScrollView
                        }
                    },
                    onScroll: {
                        scheduleVisiblePageUpdate(delay: 0.04)
                    }
                ))
                .onAppear {
                    viewportSize = viewportProxy.size
                    restoreScrollPosition(proxy, animated: false)
                }
                .onChange(of: readingMode) { _, _ in
                    restoreScrollPosition(proxy, animated: false)
                }
                .onChange(of: scrollJumpRequestID) { _, _ in
                    restoreScrollPosition(proxy, animated: true)
                }
                .onPreferenceChange(ScrollViewportSizePreferenceKey.self) { size in
                    guard size != .zero else { return }
                    viewportSize = size
                    scheduleVisiblePageUpdate(delay: 0.02)
                }
                .onPreferenceChange(PageHeightPreferenceKey.self) { heights in
                    guard pageHeights != heights else { return }
                    pageHeights = heights
                }
                .onPreferenceChange(PageFramePreferenceKey.self) { frames in
                    let now = Date()
                    guard pageFrames != frames else { return }
                    guard !didRestorePosition || now.timeIntervalSince(lastPageFrameCommitDate) >= 0.08 else {
                        return
                    }
                    lastPageFrameCommitDate = now
                    pageFrames = frames
                    scheduleVisiblePageUpdate(delay: 0.04)
                }
                .onDisappear {
                    visiblePageUpdateWorkItem?.cancel()
                    visiblePageUpdateWorkItem = nil
                    updateCurrentPageFromVisibleFrames()
                }
            }
        }
    }

    private func stepScroll(_ direction: Int) {
        guard let scrollView else { return }
        let now = Date()
        guard now.timeIntervalSince(lastStepTime) > 0.24 else { return }
        lastStepTime = now

        HapticManager.shared.play(.light)
        let visibleHeight = max(scrollView.bounds.height - scrollView.adjustedContentInset.top - scrollView.adjustedContentInset.bottom, 1)
        let distance = min(visibleHeight * scrollSpeed.screenStepRatio, visibleHeight * 0.8)
        let maxOffsetY = max(-scrollView.adjustedContentInset.top, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
        let minOffsetY = -scrollView.adjustedContentInset.top
        let targetY = min(max(scrollView.contentOffset.y + CGFloat(direction) * distance, minOffsetY), maxOffsetY)

        UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
            scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: targetY), animated: false)
        } completion: { _ in
            updateCurrentPageFromVisibleFrames()
        }
    }

    private func restoreScrollPosition(_ proxy: ScrollViewProxy, animated: Bool) {
        guard readingMode == .continuousScroll || readingMode == .infiniteScroll else { return }
        let targetIndex = min(max(currentPageIndex, 0), max(0, pages.count - 1))
        didRestorePosition = false
        allowTopOffsetUntil = Date().addingTimeInterval(0.8)
        let savedProgress = min(max(scrollProgress, 0), 1)
        let savedPageProgress = min(max(scrollPageProgress, 0), 1)
        DispatchQueue.main.async {
            let animation = animated ? Animation.easeInOut(duration: 0.3) : nil
            withAnimation(animation) {
                proxy.scrollTo(targetIndex, anchor: .top)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                if let scrollView {
                    let maxOffsetY = max(-scrollView.adjustedContentInset.top, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
                    let minOffsetY = -scrollView.adjustedContentInset.top
                    let targetPageHeight = estimatedPageHeight(for: targetIndex)
                    if targetPageHeight > 1 {
                        let pageOffset = min(max(targetPageHeight * savedPageProgress, 0), max(targetPageHeight - 1, 0))
                        let targetY = min(max(minOffsetY + pageTop(for: targetIndex) + pageOffset, minOffsetY), maxOffsetY)
                        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: targetY), animated: animated)
                    } else if savedProgress > 0.001 {
                        let targetY = minOffsetY + (maxOffsetY - minOffsetY) * savedProgress
                        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: targetY), animated: false)
                    }
                    lastStableContentOffsetY = scrollView.contentOffset.y
                }
                didRestorePosition = true
                scheduleVisiblePageUpdate(delay: 0.05)
            }
        }
    }

    private func scheduleVisiblePageUpdate(delay: TimeInterval = 0.12) {
        guard visiblePageUpdateWorkItem == nil else { return }
        let workItem = DispatchWorkItem {
            visiblePageUpdateWorkItem = nil
            updateCurrentPageFromVisibleFrames()
        }
        visiblePageUpdateWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func updateCurrentPageFromVisibleFrames() {
        updateCurrentPageFromViewport(frames: pageFrames, viewportSize: viewportSize)
    }

    private func estimatedPageHeight(for index: Int) -> CGFloat {
        pageHeights[index] ?? max(viewportSize.height, scrollView?.bounds.height ?? 1, 1)
    }

    private func pageTop(for index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        return (0..<index).reduce(CGFloat.zero) { partial, pageIndex in
            partial + estimatedPageHeight(for: pageIndex)
        }
    }

    private func updateCurrentPageFromViewport(frames: [Int: CGRect], viewportSize: CGSize) {
        guard didRestorePosition, !frames.isEmpty else { return }
        let visibleSize: CGSize
        if viewportSize != .zero {
            visibleSize = viewportSize
        } else if let scrollView {
            visibleSize = scrollView.bounds.size
        } else {
            return
        }

        if restoreUnexpectedScrollToTopIfNeeded(visibleHeight: visibleSize.height) {
            return
        }

        let viewport = CGRect(origin: .zero, size: visibleSize)
        guard let visiblePageIndex = ReaderVisiblePageDetector.visiblePageIndex(frames: frames, viewport: viewport) else { return }
        if visiblePageIndex == 0,
           currentPageIndex > 0,
           let scrollView {
            let minOffsetY = -scrollView.adjustedContentInset.top
            let isStillBelowTop = scrollView.contentOffset.y > minOffsetY + max(visibleSize.height * 0.42, 140)
            if isStillBelowTop {
                MReaderLog.reader.debug(
                    "scroll ignored stale page-zero frame current=\(currentPageIndex, privacy: .public) offsetY=\(Int(scrollView.contentOffset.y), privacy: .public) frames=\(frames.count, privacy: .public)"
                )
                scheduleVisiblePageUpdate(delay: 0.06)
                return
            }
        }
        let didChangePage = currentPageIndex != visiblePageIndex
        if didChangePage {
            MReaderLog.reader.debug(
                "scroll currentPageIndex update old=\(currentPageIndex, privacy: .public) new=\(visiblePageIndex, privacy: .public) frames=\(frames.count, privacy: .public)"
            )
            currentPageIndex = visiblePageIndex
        }

        let progress: CGFloat
        if let scrollView {
            let maxOffsetY = max(-scrollView.adjustedContentInset.top, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
            let minOffsetY = -scrollView.adjustedContentInset.top
            let denominator = max(maxOffsetY - minOffsetY, 1)
            progress = min(max((scrollView.contentOffset.y - minOffsetY) / denominator, 0), 1)
            if scrollView.contentOffset.y > minOffsetY + 8 {
                lastStableContentOffsetY = scrollView.contentOffset.y
            }
        } else {
            progress = CGFloat(visiblePageIndex) / CGFloat(max(pages.count - 1, 1))
        }
        let activeFrame = frames[visiblePageIndex]
        let pageProgress: CGFloat
        if let activeFrame, activeFrame.height > 1 {
            pageProgress = min(max(-activeFrame.minY / max(activeFrame.height, 1), 0), 1)
        } else {
            pageProgress = 0
        }
        let shouldNotifyProgress = didChangePage || Date().timeIntervalSince(lastScrollPositionNotifyDate) > 1.0
        if shouldNotifyProgress {
            lastScrollPositionNotifyDate = Date()
            onScrollPositionChange(visiblePageIndex, Double(progress), Double(pageProgress))
        }
    }

    /// 已知道真实宽高比时用真实比例预留高度，避免长条页加载后大幅重排（审查 #16）。
    private func placeholderHeight(for url: URL, viewport: CGSize) -> CGFloat {
        if let size = PageGeometryStore.shared.size(for: url), size.width > 1 {
            return max(viewport.height, viewport.width * size.height / size.width)
        }
        return max(viewport.height, viewport.width * 1.35)
    }

    private func restoreUnexpectedScrollToTopIfNeeded(visibleHeight: CGFloat) -> Bool {
        guard let scrollView, currentPageIndex > 0 else { return false }
        guard Date() > allowTopOffsetUntil else { return false }
        let minOffsetY = -scrollView.adjustedContentInset.top
        let currentY = scrollView.contentOffset.y
        let hadMeaningfulPosition = lastStableContentOffsetY > minOffsetY + max(visibleHeight * 0.45, 160)
        let jumpedToTop = currentY <= minOffsetY + 2
        guard hadMeaningfulPosition, jumpedToTop else { return false }

        let maxOffsetY = max(minOffsetY, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
        let restoreY = min(max(lastStableContentOffsetY, minOffsetY), maxOffsetY)
        MReaderLog.reader.notice(
            "scroll prevented unexpected top jump page=\(currentPageIndex, privacy: .public) restoreY=\(Int(restoreY), privacy: .public)"
        )
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: restoreY), animated: false)
        scheduleVisiblePageUpdate(delay: 0.04)
        return true
    }
}

struct GuidedPanelReader: View {
    let pages: [ComicPage]
    @Binding var currentPageIndex: Int
    let readingDirection: ReadingDirection
    let comic: ComicBook
    let translateRequestID: UUID
    let ocrMagnifyRequestID: UUID
    let isOCRMagnificationVisible: Bool
    let targetLanguage: String
    let onTranslationStateChange: (Bool) -> Void
    let areControlsVisible: Bool
    let onShowControls: () -> Void
    let onHideControls: () -> Void

    @State private var layout: PanelPageLayout?
    @State private var sourceSize: CGSize = .zero
    @State private var panelIndex = 0
    @State private var isDetecting = false

    private var currentPage: ComicPage? {
        guard pages.indices.contains(currentPageIndex) else { return nil }
        return pages[currentPageIndex]
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let page = currentPage {
                    LocalImageView(
                        url: page.url,
                        comic: comic,
                        comicID: comic.id,
                        pageIndex: page.index,
                        isOCREnabled: comic.isOCREnabled,
                        isAITranslationEnabled: comic.isAITranslationEnabled,
                        isAutoTranslationEnabled: comic.isAutoTranslationEnabled,
                        aiTranslationModeRaw: comic.aiTranslationModeRaw,
                        translationSourceLanguageRaw: comic.translationSourceLanguageRaw,
                        translateRequestID: translateRequestID,
                        ocrMagnifyRequestID: ocrMagnifyRequestID,
                        isOCRMagnificationVisible: isOCRMagnificationVisible,
                        ocrTextScale: comic.ocrTextScale,
                        ocrSafeAreaInset: comic.ocrSafeAreaInset,
                        ocrMinimumTextHeight: comic.ocrMinimumTextHeight,
                        isRightToLeftReading: readingDirection == .rightToLeft,
                        targetLanguage: targetLanguage,
                        imageFitMode: .fitScreen,
                        isPageTapGestureEnabled: false,
                        isLongPressTranslationEnabled: areControlsVisible,
                        onTranslationStateChange: onTranslationStateChange,
                        onPreviousPage: previousPanel,
                        onNextPage: nextPanel,
                        areControlsVisible: areControlsVisible,
                        onShowControls: onShowControls,
                        onHideControls: onHideControls
                    )
                    .scaleEffect(panelTransform(in: proxy.size).scale)
                    .offset(panelTransform(in: proxy.size).offset)
                    .animation(.easeInOut(duration: 0.34), value: panelIndex)
                    .animation(.easeInOut(duration: 0.28), value: currentPageIndex)
                    .task(id: page.url) { await detectPanels(for: page) }
                }

                if isDetecting {
                    ProgressView().tint(.white).allowsHitTesting(false)
                }

                if !areControlsVisible {
                    HStack(spacing: 0) {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { previousPanel() }
                        Color.clear.frame(width: proxy.size.width * 0.30).allowsHitTesting(false)
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { nextPanel() }
                    }
                }
            }
            .clipped()
        }
    }

    private func detectPanels(for page: ComicPage) async {
        isDetecting = true
        defer { isDetecting = false }
        guard let image = await ReaderImageCache.shared.loadImage(for: page.url, maxPixelSize: 6144) else {
            layout = nil
            sourceSize = .zero
            return
        }
        sourceSize = CGSize(
            width: image.cgImage.map { CGFloat($0.width) } ?? image.size.width,
            height: image.cgImage.map { CGFloat($0.height) } ?? image.size.height
        )
        layout = await PanelDetectionService.shared.layout(
            for: page.url,
            image: image,
            isRightToLeft: readingDirection == .rightToLeft
        )
        panelIndex = min(panelIndex, max((layout?.panels.count ?? 1) - 1, 0))
    }

    private func panelTransform(in viewport: CGSize) -> (scale: CGFloat, offset: CGSize) {
        guard viewport.width > 0, viewport.height > 0,
              sourceSize.width > 0, sourceSize.height > 0,
              let layout else { return (1, .zero) }
        let normalized = layout.panelRects.indices.contains(panelIndex)
            ? layout.panelRects[panelIndex]
            : layout.contentBounds.cgRect
        let imageAspect = sourceSize.width / sourceSize.height
        let viewportAspect = viewport.width / viewport.height
        let displaySize: CGSize
        if imageAspect > viewportAspect {
            displaySize = CGSize(width: viewport.width, height: viewport.width / imageAspect)
        } else {
            displaySize = CGSize(width: viewport.height * imageAspect, height: viewport.height)
        }
        let imageOrigin = CGPoint(
            x: (viewport.width - displaySize.width) / 2,
            y: (viewport.height - displaySize.height) / 2
        )
        let panel = CGRect(
            x: imageOrigin.x + normalized.minX * displaySize.width,
            y: imageOrigin.y + normalized.minY * displaySize.height,
            width: max(normalized.width * displaySize.width, 1),
            height: max(normalized.height * displaySize.height, 1)
        )
        let scale = min(max(min(viewport.width * 0.92 / panel.width, viewport.height * 0.92 / panel.height), 1), 4.8)
        return (
            scale,
            CGSize(
                width: (viewport.width / 2 - panel.midX) * scale,
                height: (viewport.height / 2 - panel.midY) * scale
            )
        )
    }

    private func previousPanel() {
        if panelIndex > 0 {
            panelIndex -= 1
            HapticManager.shared.play(.light)
        } else if currentPageIndex > 0 {
            currentPageIndex -= 1
            panelIndex = Int.max
            HapticManager.shared.play(.light)
        } else {
            HapticManager.shared.play(.warning)
        }
    }

    private func nextPanel() {
        let count = max(layout?.panels.count ?? 1, 1)
        if panelIndex + 1 < count {
            panelIndex += 1
            HapticManager.shared.play(.light)
        } else if currentPageIndex + 1 < pages.count {
            currentPageIndex += 1
            panelIndex = 0
            HapticManager.shared.play(.light)
        } else {
            HapticManager.shared.play(.warning)
        }
    }
}

struct AnimatedPageReader: View {
    let pages: [ComicPage]
    @Binding var currentPageIndex: Int
    @Binding var pageTurnDirection: Int
    let readingDirection: ReadingDirection
    let readingMode: ReadingMode
    let pageTurnAnimation: PageTurnAnimation
    let imageFitMode: ImageFitMode
    let comic: ComicBook
    let translateRequestID: UUID
    let ocrMagnifyRequestID: UUID
    let isOCRMagnificationVisible: Bool
    let targetLanguage: String
    let onTranslationStateChange: (Bool) -> Void
    let areControlsVisible: Bool
    let onShowControls: () -> Void
    let onHideControls: () -> Void

    @GestureState private var dragOffset: CGFloat = 0
    /// 当前页是否处于放大态：放大时单指拖动属于平移，必须屏蔽翻页拖拽。
    @State private var isPageZoomed = false

    var body: some View {
        GeometryReader { geo in
            let isRTL = readingDirection == .rightToLeft

            ZStack {
                if pageTurnAnimation == .curl,
                   let revealedPageIndex = revealedPageIndex(isRTL: isRTL),
                   pages.indices.contains(revealedPageIndex) {
                    pageView(index: revealedPageIndex)
                        .id("revealed-\(pages[revealedPageIndex].id)")
                }

                if pages.indices.contains(currentPageIndex) {
                    pageView(index: currentPageIndex)
                        .id(pages[currentPageIndex].id)
                        .transition(transition)
                        .modifier(
                            InteractiveBookPageCurlModifier(
                                dragOffset: pageTurnAnimation == .curl ? dragOffset : 0,
                                pageExtent: readingMode == .verticalPage ? geo.size.height : geo.size.width,
                                isVertical: readingMode == .verticalPage
                            )
                        )
                        .offset(pageOffset)
                        .animation(pageChangeAnimation, value: currentPageIndex)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 28)
                    .updating($dragOffset) { value, state, _ in
                        guard ReaderGestureGate.allowsSinglePageTurn(isZoomed: isPageZoomed) else { return }
                        state = readingMode == .verticalPage ? value.translation.height : value.translation.width
                    }
                    .onEnded { value in
                        guard ReaderGestureGate.allowsSinglePageTurn(isZoomed: isPageZoomed) else { return }
                        let axisLength = readingMode == .verticalPage ? geo.size.height : geo.size.width
                        let threshold = max(axisLength * 0.2, 72)
                        let rawDelta = readingMode == .verticalPage ? value.translation.height : value.translation.width
                        let logicalDelta = readingMode == .verticalPage ? rawDelta : (isRTL ? rawDelta : -rawDelta)
                        if logicalDelta > threshold {
                            nextPage()
                        } else if logicalDelta < -threshold {
                            previousPage()
                        }
                    }
            )
            .onChange(of: currentPageIndex) { _, _ in isPageZoomed = false }
        }
    }

    private var transition: AnyTransition {
        switch pageTurnAnimation {
        case .none:
            return .identity
        case .slide:
            return directionalSlideTransition
        case .curl:
            return .asymmetric(
                insertion: .modifier(
                    active: PageCurlTransitionModifier(
                        angle: pageTurnDirection >= 0 ? 68 : -68,
                        opacity: 0.08,
                        isVertical: readingMode == .verticalPage
                    ),
                    identity: PageCurlTransitionModifier(angle: 0, opacity: 1, isVertical: readingMode == .verticalPage)
                ),
                removal: .modifier(
                    active: PageCurlTransitionModifier(
                        angle: pageTurnDirection >= 0 ? -68 : 68,
                        opacity: 0.08,
                        isVertical: readingMode == .verticalPage
                    ),
                    identity: PageCurlTransitionModifier(angle: 0, opacity: 1, isVertical: readingMode == .verticalPage)
                )
            )
        case .fade:
            return .opacity.combined(with: .scale(scale: 0.975))
        }
    }

    private var pageChangeAnimation: Animation? {
        switch pageTurnAnimation {
        case .none:
            return nil
        case .slide:
            return .easeOut(duration: 0.28)
        case .fade:
            return .easeInOut(duration: 0.34)
        case .curl:
            return .spring(response: 0.44, dampingFraction: 0.84)
        }
    }

    private var directionalSlideTransition: AnyTransition {
        let isForward = pageTurnDirection >= 0
        if readingMode == .verticalPage {
            return .asymmetric(
                insertion: .move(edge: isForward ? .bottom : .top),
                removal: .move(edge: isForward ? .top : .bottom)
            )
        }

        let forwardInsertion: Edge = readingDirection == .rightToLeft ? .leading : .trailing
        let forwardRemoval: Edge = readingDirection == .rightToLeft ? .trailing : .leading
        return .asymmetric(
            insertion: .move(edge: isForward ? forwardInsertion : forwardRemoval),
            removal: .move(edge: isForward ? forwardRemoval : forwardInsertion)
        )
    }

    private var pageOffset: CGSize {
        guard pageTurnAnimation == .slide else { return .zero }
        if readingMode == .verticalPage {
            return CGSize(width: 0, height: dragOffset * 0.18)
        }
        return CGSize(width: dragOffset * 0.18, height: 0)
    }

    private func revealedPageIndex(isRTL: Bool) -> Int? {
        guard abs(dragOffset) > 2 else { return nil }
        if readingMode == .verticalPage {
            return currentPageIndex + (dragOffset < 0 ? 1 : -1)
        }
        let isForwardDrag = isRTL ? dragOffset > 0 : dragOffset < 0
        return currentPageIndex + (isForwardDrag ? 1 : -1)
    }

    private func pageView(index: Int) -> some View {
        LocalImageView(
            url: pages[index].url,
            comic: comic,
            comicID: comic.id,
            pageIndex: index,
            isOCREnabled: comic.isOCREnabled,
            isAITranslationEnabled: comic.isAITranslationEnabled,
            // 卷曲动画的“被揭示页”不在此触发自动翻译，避免拖拽松手时白做；
            // 下一页的翻译由 Reader 层 scheduleTranslationPrefetch 统一预取。
            isAutoTranslationEnabled: index == currentPageIndex ? comic.isAutoTranslationEnabled : false,
            aiTranslationModeRaw: comic.aiTranslationModeRaw,
            translationSourceLanguageRaw: comic.translationSourceLanguageRaw,
            translateRequestID: translateRequestID,
            ocrMagnifyRequestID: ocrMagnifyRequestID,
            isOCRMagnificationVisible: isOCRMagnificationVisible,
            ocrTextScale: comic.ocrTextScale,
            ocrSafeAreaInset: comic.ocrSafeAreaInset,
            ocrMinimumTextHeight: comic.ocrMinimumTextHeight,
            isRightToLeftReading: readingDirection == .rightToLeft,
            targetLanguage: targetLanguage,
            imageFitMode: imageFitMode,
            isPageTapGestureEnabled: false,
            isLongPressTranslationEnabled: areControlsVisible,
            onTranslationStateChange: onTranslationStateChange,
            onZoomChange: { zoomed in
                guard index == currentPageIndex else { return }
                isPageZoomed = zoomed
            },
            onPreviousPage: previousPage,
            onNextPage: nextPage,
            areControlsVisible: areControlsVisible,
            onShowControls: onShowControls,
            onHideControls: onHideControls
        )
    }

    private func previousPage() {
        guard currentPageIndex > 0 else {
            HapticManager.shared.play(.warning)
            return
        }
        HapticManager.shared.play(.light)
        pageTurnDirection = -1
        currentPageIndex = max(0, currentPageIndex - 1)
    }

    private func nextPage() {
        guard currentPageIndex < max(0, pages.count - 1) else {
            HapticManager.shared.play(.warning)
            return
        }
        HapticManager.shared.play(.light)
        pageTurnDirection = 1
        currentPageIndex = min(max(0, pages.count - 1), currentPageIndex + 1)
    }
}

struct DoublePageReader: View {
    let pages: [ComicPage]
    @Binding var currentPageIndex: Int
    @Binding var pageTurnDirection: Int
    let readingDirection: ReadingDirection
    let pageTurnAnimation: PageTurnAnimation
    let imageFitMode: ImageFitMode
    let comic: ComicBook
    let translateRequestID: UUID
    let ocrMagnifyRequestID: UUID
    let isOCRMagnificationVisible: Bool
    let targetLanguage: String
    let onTranslationStateChange: (Bool) -> Void
    let areControlsVisible: Bool
    let onShowControls: () -> Void
    let onHideControls: () -> Void

    @GestureState private var dragOffset: CGFloat = 0
    /// 左/右两页可以各自放大：必须按页记录，任何一个 Bool 都会被另一页的回调覆盖。
    /// 只有集合为空（两页都是 1x）才允许跨页拖拽。
    @State private var zoomedPageIndexes: Set<Int> = []

    private var leftPageIndex: Int {
        currentPageIndex - currentPageIndex % 2
    }

    private var rightPageIndex: Int {
        leftPageIndex + 1
    }

    var body: some View {
        GeometryReader { geo in
            let isRTL = readingDirection == .rightToLeft
            HStack(spacing: 0) {
                let pair = isRTL ? [rightPageIndex, leftPageIndex] : [leftPageIndex, rightPageIndex]
                ForEach(pair, id: \.self) { index in
                    if pages.indices.contains(index) {
                        pageView(index: index)
                            .frame(width: geo.size.width / 2, height: geo.size.height)
                    } else {
                        Color.black.frame(width: geo.size.width / 2, height: geo.size.height)
                    }
                }
            }
            .id(leftPageIndex)
            .transition(doublePageTransition)
            .offset(x: (pageTurnAnimation == .slide || pageTurnAnimation == .curl) ? dragOffset * 0.16 : 0)
            .animation(pageChangeAnimation, value: leftPageIndex)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 28)
                    .updating($dragOffset) { value, state, _ in
                        guard ReaderGestureGate.allowsDoublePageTurn(zoomedPageIndexes: zoomedPageIndexes) else { return }
                        state = value.translation.width
                    }
                    .onEnded { value in
                        guard ReaderGestureGate.allowsDoublePageTurn(zoomedPageIndexes: zoomedPageIndexes) else { return }
                        let threshold = max(geo.size.width * 0.2, 72)
                        let logicalDelta = isRTL ? value.translation.width : -value.translation.width
                        if logicalDelta > threshold {
                            nextSpread()
                        } else if logicalDelta < -threshold {
                            previousSpread()
                        }
                    }
            )
            .onChange(of: leftPageIndex) { _, _ in zoomedPageIndexes.removeAll() }
        }
    }

    private func pageView(index: Int) -> some View {
        LocalImageView(
            url: pages[index].url,
            comic: comic,
            comicID: comic.id,
            pageIndex: index,
            isOCREnabled: comic.isOCREnabled,
            isAITranslationEnabled: comic.isAITranslationEnabled,
            isAutoTranslationEnabled: comic.isAutoTranslationEnabled,
            aiTranslationModeRaw: comic.aiTranslationModeRaw,
            translationSourceLanguageRaw: comic.translationSourceLanguageRaw,
            translateRequestID: translateRequestID,
            ocrMagnifyRequestID: ocrMagnifyRequestID,
            isOCRMagnificationVisible: isOCRMagnificationVisible,
            ocrTextScale: comic.ocrTextScale,
            ocrSafeAreaInset: comic.ocrSafeAreaInset,
            ocrMinimumTextHeight: comic.ocrMinimumTextHeight,
            isRightToLeftReading: readingDirection == .rightToLeft,
            targetLanguage: targetLanguage,
            imageFitMode: imageFitMode,
            isPageTapGestureEnabled: false,
            isLongPressTranslationEnabled: areControlsVisible,
            onTranslationStateChange: onTranslationStateChange,
            onZoomChange: { zoomed in
                guard index == leftPageIndex || index == rightPageIndex else { return }
                // 按页登记：左页回到 1x 不能把右页的放大状态一起清掉。
                if zoomed {
                    zoomedPageIndexes.insert(index)
                } else {
                    zoomedPageIndexes.remove(index)
                }
            },
            onPreviousPage: {},
            onNextPage: {},
            areControlsVisible: areControlsVisible,
            onShowControls: onShowControls,
            onHideControls: onHideControls
        )
    }

    private var doublePageTransition: AnyTransition {
        switch pageTurnAnimation {
        case .fade:
            return .opacity.combined(with: .scale(scale: 0.975))
        case .slide:
            let isForward = pageTurnDirection >= 0
            let forwardInsertion: Edge = readingDirection == .rightToLeft ? .leading : .trailing
            let forwardRemoval: Edge = readingDirection == .rightToLeft ? .trailing : .leading
            return .asymmetric(
                insertion: .move(edge: isForward ? forwardInsertion : forwardRemoval),
                removal: .move(edge: isForward ? forwardRemoval : forwardInsertion)
            )
        case .curl:
            return .asymmetric(
                insertion: .modifier(
                    active: PageCurlTransitionModifier(angle: pageTurnDirection >= 0 ? 68 : -68, opacity: 0.08, isVertical: false),
                    identity: PageCurlTransitionModifier(angle: 0, opacity: 1, isVertical: false)
                ),
                removal: .modifier(
                    active: PageCurlTransitionModifier(angle: pageTurnDirection >= 0 ? -68 : 68, opacity: 0.08, isVertical: false),
                    identity: PageCurlTransitionModifier(angle: 0, opacity: 1, isVertical: false)
                )
            )
        case .none:
            return .identity
        }
    }

    private var pageChangeAnimation: Animation? {
        switch pageTurnAnimation {
        case .none:
            return nil
        case .slide:
            return .easeOut(duration: 0.28)
        case .fade:
            return .easeInOut(duration: 0.34)
        case .curl:
            return .spring(response: 0.44, dampingFraction: 0.84)
        }
    }

    private func previousSpread() {
        guard leftPageIndex > 0 else {
            HapticManager.shared.play(.warning)
            return
        }
        HapticManager.shared.play(.light)
        pageTurnDirection = -1
        currentPageIndex = max(0, leftPageIndex - 2)
    }

    private func nextSpread() {
        guard leftPageIndex + 2 <= max(0, pages.count - 1) else {
            HapticManager.shared.play(.warning)
            return
        }
        HapticManager.shared.play(.light)
        pageTurnDirection = 1
        currentPageIndex = min(max(0, pages.count - 1), leftPageIndex + 2)
    }
}

private struct PageCurlTransitionModifier: AnimatableModifier {
    var angle: Double
    var opacity: Double
    let isVertical: Bool

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(angle, opacity) }
        set {
            angle = newValue.first
            opacity = newValue.second
        }
    }

    func body(content: Content) -> some View {
        let progress = min(abs(angle) / 90, 1)
        content
            .overlay {
                LinearGradient(
                    colors: [
                        .clear,
                        .black.opacity(0.08 + progress * 0.18),
                        .white.opacity(progress * 0.22)
                    ],
                    startPoint: isVertical ? .top : (angle >= 0 ? .leading : .trailing),
                    endPoint: isVertical ? .bottom : (angle >= 0 ? .trailing : .leading)
                )
                .allowsHitTesting(false)
            }
            .rotation3DEffect(
                .degrees(angle),
                axis: isVertical ? (x: 1, y: 0, z: 0) : (x: 0, y: 1, z: 0),
                anchor: angle >= 0 ? (isVertical ? .top : .leading) : (isVertical ? .bottom : .trailing),
                perspective: 0.58
            )
            .scaleEffect(0.985 + opacity * 0.015)
            .opacity(opacity)
            .shadow(
                color: .black.opacity(0.52 * progress),
                radius: 10 + progress * 20,
                x: isVertical ? 0 : (angle >= 0 ? -14 : 14),
                y: isVertical ? (angle >= 0 ? -14 : 14) : 0
            )
    }
}

private struct InteractiveBookPageCurlModifier: ViewModifier {
    let dragOffset: CGFloat
    let pageExtent: CGFloat
    let isVertical: Bool

    func body(content: Content) -> some View {
        let extent = max(pageExtent, 1)
        let progress = min(abs(dragOffset) / extent, 1)
        let direction: CGFloat = dragOffset < 0 ? -1 : 1
        let angle = Double(direction * progress * 86)
        let anchor: UnitPoint = isVertical
            ? (direction < 0 ? .top : .bottom)
            : (direction < 0 ? .leading : .trailing)

        content
            .overlay {
                if progress > 0 {
                    ZStack {
                        Color.white.opacity(progress * 0.10)
                        LinearGradient(
                            colors: [
                                .clear,
                                .black.opacity(progress * 0.30),
                                .white.opacity(progress * 0.34),
                                .clear
                            ],
                            startPoint: foldStart(direction: direction),
                            endPoint: foldEnd(direction: direction)
                        )
                    }
                    .allowsHitTesting(false)
                }
            }
            .rotation3DEffect(
                .degrees(angle),
                axis: isVertical ? (x: 1, y: 0, z: 0) : (x: 0, y: 1, z: 0),
                anchor: anchor,
                perspective: 0.52
            )
            .offset(
                x: isVertical ? 0 : direction * extent * progress * 0.12,
                y: isVertical ? direction * extent * progress * 0.12 : 0
            )
            .shadow(
                color: .black.opacity(progress * 0.62),
                radius: 8 + progress * 26,
                x: isVertical ? 0 : -direction * (8 + progress * 18),
                y: isVertical ? -direction * (8 + progress * 18) : 0
            )
    }

    private func foldStart(direction: CGFloat) -> UnitPoint {
        if isVertical {
            return direction < 0 ? .bottom : .top
        }
        return direction < 0 ? .trailing : .leading
    }

    private func foldEnd(direction: CGFloat) -> UnitPoint {
        if isVertical {
            return direction < 0 ? .top : .bottom
        }
        return direction < 0 ? .leading : .trailing
    }
}

struct TwoFingerSwipeDownDismissView: UIViewRepresentable {
    let onProgress: (CGFloat) -> Void
    let onCancel: () -> Void
    let onSwipe: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onProgress: onProgress, onCancel: onCancel, onSwipe: onSwipe)
    }

    func makeUIView(context: Context) -> UIView {
        let view = WindowGestureInstallView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onProgress = onProgress
        context.coordinator.onCancel = onCancel
        context.coordinator.onSwipe = onSwipe
        (uiView as? WindowGestureInstallView)?.coordinator = context.coordinator
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onProgress: (CGFloat) -> Void
        var onCancel: () -> Void
        var onSwipe: () -> Void
        let recognizer = UIPanGestureRecognizer()
        private var hasTriggered = false

        init(
            onProgress: @escaping (CGFloat) -> Void,
            onCancel: @escaping () -> Void,
            onSwipe: @escaping () -> Void
        ) {
            self.onProgress = onProgress
            self.onCancel = onCancel
            self.onSwipe = onSwipe
            super.init()
            recognizer.minimumNumberOfTouches = 2
            recognizer.maximumNumberOfTouches = 2
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            recognizer.addTarget(self, action: #selector(handlePan(_:)))
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
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
    }

    final class WindowGestureInstallView: UIView {
        weak var coordinator: Coordinator? {
            didSet {
                installRecognizerIfNeeded()
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            installRecognizerIfNeeded()
        }

        private func installRecognizerIfNeeded() {
            guard let window, let coordinator else { return }
            if coordinator.recognizer.view !== window {
                coordinator.recognizer.view?.removeGestureRecognizer(coordinator.recognizer)
                window.addGestureRecognizer(coordinator.recognizer)
            }
        }

        deinit {
            MainActor.assumeIsolated {
                if let recognizer = coordinator?.recognizer {
                    recognizer.view?.removeGestureRecognizer(recognizer)
                }
            }
        }
    }
}

struct LocalImageView: View {
    let url: URL
    var comic: ComicBook? = nil
    var comicID: UUID? = nil
    var pageIndex: Int? = nil
    let isOCREnabled: Bool
    let isAITranslationEnabled: Bool
    let isAutoTranslationEnabled: Bool
    let aiTranslationModeRaw: String
    let translationSourceLanguageRaw: String
    let translateRequestID: UUID
    let ocrMagnifyRequestID: UUID
    let isOCRMagnificationVisible: Bool
    let ocrTextScale: Double
    let ocrSafeAreaInset: Double
    let ocrMinimumTextHeight: Double
    let isRightToLeftReading: Bool
    let targetLanguage: String
    let imageFitMode: ImageFitMode
    var visionViewportAspect: CGFloat? = nil
    var placeholderHeight: CGFloat? = nil
    var imageLoadDelay: TimeInterval = 0
    var showsLoadingIndicator: Bool = true
    var isPageTapGestureEnabled: Bool = true
    var isLongPressTranslationEnabled: Bool = true
    var onTranslationStateChange: (Bool) -> Void = { _ in }
    /// 缩放态回传：外层翻页容器据此在 scale > 1 时屏蔽翻页拖拽。
    var onZoomChange: (Bool) -> Void = { _ in }
    let onPreviousPage: () -> Void
    let onNextPage: () -> Void
    let areControlsVisible: Bool
    let onShowControls: () -> Void
    let onHideControls: () -> Void
    @State private var uiImage: UIImage? = nil
    @State private var isLoadingImage = true
    @State private var loadFailed = false
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    /// 单指平移的基准位移：拖动开始时 offset 的取值，避免每次 onChanged 累积抖动。
    @State private var lastOffset: CGSize = .zero
    /// 覆盖层 GeometryReader 报告的未缩放内容尺寸，用于平移边界 clamp。
    @State private var zoomContentSize: CGSize = .zero
    /// 覆盖层布局缓存：只有排版输入真正变化时才重算整页 O(n²) 布局（审查 #7）。
    @State private var layoutStore = TranslationLayoutStore()
    @State private var pendingSingleTapWorkItem: DispatchWorkItem?
    @State private var lastDoubleTapTime = Date.distantPast
    @State private var viewportWidth: CGFloat = 0
    @State private var viewportSize: CGSize = .zero
    
    // AI 相关的状态
    @State private var textBlocks: [TextBlock] = []
    @State private var ocrTextBlocks: [TextBlock] = []
    @State private var debugRawBlocks: [TextBlock] = []
    @State private var debugCandidateBlocks: [TextBlock] = []
    @State private var debugFilteredBlocks: [TextBlock] = []
    @State private var debugFilteredOutBlocks: [TextBlock] = []
    @State private var debugLineBlocks: [TextBlock] = []
    @State private var debugBubbleBlocks: [TextBlock] = []
    @State private var debugRejectedBlocks: [TextBlock] = []
    @State private var recognizedPipelineCache: OCRPipelineResult?
    @State private var recognizedPipelineCacheKey: String?
    @State private var isTranslating = false
    @State private var isRecognizingOCR = false
    @State private var translationErrorMessage: String?
    @State private var translationTask: Task<Void, Never>?
    @State private var offlineTranslationTask: Task<OfflineTranslationOverlayResult, Never>?
    @State private var isOfflineTranslationDisplayed = false
    @State private var translationGeneration = UUID()
    @State private var ocrMagnificationTask: Task<Void, Never>?
    @AppStorage("translation_use_apple_low_latency") private var useAppleLowLatency = false
    @State private var appleTranslationRequests: [AppleTranslationBlockRequest] = []
    @State private var appleTranslationGeneration = UUID()
    @State private var appleSourceLanguageCode: String? = nil
    @AppStorage("translation_style_instructions") private var translationStyleInstructions = AITranslator.defaultTranslationStyleInstructions
    @AppStorage("vision_translation_prompt_template") private var visionTranslationPromptTemplate = AITranslator.defaultVisionTranslationPromptTemplate
    @AppStorage("ocr_show_debug_boxes") private var ocrShowDebugBoxes = false
    @AppStorage("ocr_debug_stage") private var ocrDebugStageRaw = OCRDebugStage.raw.rawValue
    @AppStorage("ocr_visual_verification_enabled") private var ocrVisualVerificationEnabled = false
    @AppStorage("ocr_local_recognition_mode") private var ocrRecognitionModeRaw = OCRRecognitionMode.adaptive.rawValue
    @AppStorage("translation_color_style") private var translationColorStyleRaw = TranslationColorStyle.contrast.rawValue

    private var shouldDisplayOfflineTranslation: Bool {
        comic?.isOfflineTranslationOverlayEnabled ?? true
    }

    private var aiTranslationMode: AITranslationMode {
        AITranslationMode(rawValue: aiTranslationModeRaw) ?? .ocr
    }

    private var comicTranslationSourceLanguage: TranslationSourceLanguage {
        TranslationSourceLanguage(rawValue: translationSourceLanguageRaw) ?? .automatic
    }

    private var selectedOCRDebugStage: OCRDebugStage {
        OCRDebugStage(rawValue: ocrDebugStageRaw) ?? .raw
    }

    private var canTranslate: Bool {
        isAITranslationEnabled && (aiTranslationMode == .vision || isOCREnabled)
    }

    private var imageLoadTaskID: String {
        "\(url.absoluteString)#delay=\(Int((imageLoadDelay * 1_000).rounded()))"
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let uiImage = uiImage {
                // 1. 底图与翻译文本覆盖层
                fittedImage(uiImage)
                    // 核心逻辑：直接在图片上层按比例渲染文本气泡
                    .overlay(
                        GeometryReader { geo in
                            ZStack {
                                translationOverlay(in: geo.size)
                                ocrMagnificationOverlay(in: geo.size)
                                ocrDebugOverlay(in: geo.size)
                            }
                            .onAppear { zoomContentSize = geo.size }
                            .onChange(of: geo.size) { _, newValue in zoomContentSize = newValue }
                        }
                    )
                    .scaleEffect(scale)
                    .offset(offset)
                    // 放大后把图片裁剪在自身布局框内，避免溢出到相邻页面与翻页过渡叠加。
                    .clipped()
                    .gesture(zoomGesture)
                    .gesture(gatedPanGesture)
                    .simultaneousGesture(tapPageGesture)
                    .simultaneousGesture(longPressTranslationGesture)
                    .frame(height: displayHeight(for: uiImage))

            } else if isLoadingImage {
                if showsLoadingIndicator {
                    ProgressView().tint(.white).controlSize(.regular)
                } else {
                    Color.clear
                }
            } else if loadFailed {
                ContentUnavailableView("reader.imageLoadFailed".localized, systemImage: "exclamationmark.triangle", description: Text(url.lastPathComponent))
                    .foregroundStyle(.white)
            }
        }
        .overlay(alignment: .bottom) {
            if let translationErrorMessage {
                Text(translationErrorMessage)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.62), in: Capsule())
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
        .background {
            if useAppleLowLatency, aiTranslationMode == .ocr, !appleTranslationRequests.isEmpty,
               let sourceCode = appleSourceLanguageCode {
                let bridgeGeneration = appleTranslationGeneration
                let bridgeTarget = TranslationTargetLanguage.migrateLegacyValue(targetLanguage).rawValue
                AppleTranslationBridge(
                    sourceLanguage: Locale.Language(identifier: sourceCode),
                    targetLanguage: Locale.Language(identifier: bridgeTarget),
                    requests: appleTranslationRequests,
                    onResult: { id, text in
                        guard self.isAppleBridgeCurrent(
                            generation: bridgeGeneration,
                            pageURL: self.url,
                            targetLanguage: bridgeTarget
                        ) else { return }
                        guard let index = self.textBlocks.firstIndex(where: { $0.id == id }) else { return }
                        self.textBlocks[index].translation = text
                        self.textBlocks[index].translationLines = [text]
                    },
                    onFinished: { seen in
                        guard self.isAppleBridgeCurrent(
                            generation: bridgeGeneration,
                            pageURL: self.url,
                            targetLanguage: bridgeTarget
                        ) else { return }
                        // 把整页（含增量结果）写入 Apple 页缓存，翻回旧页不再重复翻译
                        let cacheKey = AppleTranslationPageCache.key(
                            pageURL: self.url,
                            sourceLanguage: sourceCode,
                            targetLanguage: bridgeTarget,
                            segmentationRevision: AITranslationPageRequest.ocrGeometryRevision,
                            ocrRecognitionMode: OCRRecognitionMode(rawValue: self.ocrRecognitionModeRaw) ?? .adaptive,
                            usesVisualOCRVerification: self.ocrVisualVerificationEnabled,
                            isRightToLeft: self.isRightToLeftReading,
                            minimumTextHeight: self.ocrMinimumTextHeight,
                            safeAreaInset: self.ocrSafeAreaInset
                        )
                        Task {
                            await AppleTranslationPageCache.shared.store(self.textBlocks, key: cacheKey)
                            let target = TranslationTargetLanguage.migrateLegacyValue(bridgeTarget)
                            await TranslationContextRegistry.shared.record(
                                scopeID: TranslationContextBuilder.scopeID(
                                    comicID: self.comicID,
                                    target: target
                                ),
                                pageIndex: self.pageIndex,
                                blocks: self.textBlocks
                            )
                        }
                        let missing = self.appleTranslationRequests
                            .filter { !seen.contains($0.id) }
                            .map(\.id)
                        if !missing.isEmpty {
                            self.cloudFallbackForMissing(
                                missing,
                                generation: bridgeGeneration,
                                pageURL: self.url,
                                targetLanguage: bridgeTarget
                            )
                        }
                    }
                )
                .id(appleTranslationGeneration)
            }
        }
        .frame(height: reservedDisplayHeight)
        .frame(maxWidth: .infinity, minHeight: imageFitMode == .fitWidth ? nil : 0, maxHeight: imageFitMode == .fitWidth ? nil : .infinity)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        viewportWidth = proxy.size.width
                        viewportSize = proxy.size
                    }
                    .onChange(of: proxy.size) { _, newValue in
                        viewportWidth = newValue.width
                        viewportSize = newValue
                    }
            }
        }
        .task(id: imageLoadTaskID) {
            guard uiImage == nil else { return }
            if imageLoadDelay > 0 {
                do {
                    try await Task.sleep(for: .seconds(imageLoadDelay))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            await loadImage()
        }
        .onDisappear {
            translationTask?.cancel()
            translationTask = nil
            offlineTranslationTask?.cancel()
            offlineTranslationTask = nil
            translationGeneration = UUID()
            ocrMagnificationTask?.cancel()
            ocrMagnificationTask = nil
            if isTranslating {
                isTranslating = false
                onTranslationStateChange(false)
            }
            if isZoomedIn {
                onZoomChange(false)
            }
        }
        .onChange(of: isZoomedIn) { _, zoomed in
            if !zoomed {
                // 回到 1x：清空平移残留，避免下次放大沿用旧位移。
                offset = .zero
                lastOffset = .zero
                lastScale = 1
            }
            onZoomChange(zoomed)
        }
        .onChange(of: translateRequestID) { _, _ in
            startTranslation(force: true)
        }
        .onChange(of: ocrMagnifyRequestID) { _, _ in
            startOCRMagnification()
        }
        .onChange(of: isOCRMagnificationVisible) { _, newValue in
            if newValue {
                startOCRMagnification()
            } else {
                ocrTextBlocks.removeAll()
            }
        }
        .onChange(of: isAutoTranslationEnabled) { _, newValue in
            guard newValue else { return }
            startTranslation()
        }
        .onChange(of: shouldDisplayOfflineTranslation) { _, newValue in
            offlineTranslationTask?.cancel()
            if isOfflineTranslationDisplayed {
                isOfflineTranslationDisplayed = false
                textBlocks.removeAll()
            }
            guard newValue else {
                return
            }
            Task {
                let loaded = await loadOfflineTranslationIfAvailable()
                if !loaded, isAutoTranslationEnabled {
                    startTranslation()
                }
            }
        }
        .onChange(of: isOCREnabled) { _, newValue in
            if !newValue {
                ocrTextBlocks.removeAll()
            }
        }
        .onChange(of: canTranslate) { _, newValue in
            if !newValue, !isOfflineTranslationDisplayed {
                textBlocks.removeAll()
            }
        }
        .onChange(of: targetLanguage) { _, _ in
            textBlocks.removeAll()
            isOfflineTranslationDisplayed = false
            if isAutoTranslationEnabled {
                Task {
                    let loaded = await loadOfflineTranslationIfAvailable()
                    if !loaded { startTranslation() }
                }
            }
        }
        .onChange(of: translationSourceLanguageRaw) { _, _ in
            // 修改原文语言后，当前翻译与 Apple 请求一并失效并重译（审查 #4）；
            // 同时清掉之前自动识别的 stable language，避免旧语言继续污染（审查 #9）
            textBlocks.removeAll()
            isOfflineTranslationDisplayed = false
            appleTranslationRequests.removeAll()
            clearStableSourceLanguage()
            if isAutoTranslationEnabled {
                Task {
                    let loaded = await loadOfflineTranslationIfAvailable()
                    if !loaded { startTranslation() }
                }
            }
        }
        .onChange(of: aiTranslationModeRaw) { _, _ in
            textBlocks.removeAll()
            if isAutoTranslationEnabled {
                startTranslation()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .offlineTranslationPageDidUpdate)) { notification in
            guard shouldDisplayOfflineTranslation,
                  let comicID = notification.userInfo?[OfflineTranslationNotificationKey.comicID] as? UUID,
                  comicID == comic?.id,
                  let updatedPageIndex = notification.userInfo?[OfflineTranslationNotificationKey.pageIndex] as? Int,
                  updatedPageIndex == pageIndex else {
                return
            }
            Task {
                _ = await loadOfflineTranslationIfAvailable()
            }
        }
        .onChange(of: ocrRecognitionModeRaw) { _, _ in
            recognizedPipelineCacheKey = nil
            recognizedPipelineCache = nil
            ocrTextBlocks.removeAll()
            textBlocks.removeAll()
            if isOCRMagnificationVisible {
                startOCRMagnification()
            }
        }
    }

    @ViewBuilder
    private func fittedImage(_ image: UIImage) -> some View {
        switch imageFitMode {
        case .fitScreen:
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
        case .fitWidth:
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
        case .fitHeight:
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: .infinity)
        case .original:
            // “原始尺寸”：不放大显示。小图按原生像素 1:1 显示，超出容器则等比缩小到容器内。
            let nativeWidth = max(image.size.width * image.scale, 1)
            let nativeHeight = max(image.size.height * image.scale, 1)
            let scaleFactor = min(
                1,
                min(
                    max(viewportWidth, 1) / nativeWidth,
                    max(viewportSize.height, 1) / nativeHeight
                )
            )
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: max(nativeWidth * scaleFactor, 1), height: max(nativeHeight * scaleFactor, 1))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func displayHeight(for image: UIImage) -> CGFloat? {
        guard imageFitMode == .fitWidth, viewportWidth > 1, image.size.width > 0 else { return nil }
        return max(1, viewportWidth * image.size.height / image.size.width)
    }

    private var reservedDisplayHeight: CGFloat? {
        if let uiImage {
            return displayHeight(for: uiImage)
        }
        guard imageFitMode == .fitWidth else { return nil }
        return placeholderHeight
    }

    @ViewBuilder
    private func translationOverlay(in size: CGSize) -> some View {
        if (shouldDisplayOfflineTranslation && isOfflineTranslationDisplayed) || canTranslate {
            let items = translationLayoutItems(in: size)
            ZStack {
                // F07: all surfaces are one real layer below every glyph layer.
                ForEach(items) { item in
                    TranslationSurfaceRenderer(
                        layoutSize: item.rect.size,
                        surfaceStyle: item.surfaceStyle,
                        displayMode: item.displayMode,
                        layoutStatus: item.layoutStatus
                    )
                    .position(x: item.rect.midX, y: item.rect.midY)
                    .zIndex(TranslationSurfaceLayering.surfaceZIndex)
                    .allowsHitTesting(false)
                }
                ForEach(items) { item in
                    TranslationTextRenderer(
                        segments: item.displayText.map { [$0] } ?? item.blocks.compactMap {
                            let value = displayTranslation(for: $0)
                            return value.isEmpty ? nil : value
                        },
                        fontSize: item.fontSize,
                        layoutSize: item.rect.size,
                        contentPadding: item.contentPadding,
                        style: TranslationColorStyle(rawValue: translationColorStyleRaw) ?? .contrast,
                        textOrientation: item.textOrientation,
                        displayMode: item.displayMode,
                        layoutStatus: item.layoutStatus
                    )
                    .position(x: item.rect.midX, y: item.rect.midY)
                    .zIndex(TranslationSurfaceLayering.textZIndex)
                }
            }
        }
    }

    private var visibleTranslationBlocks: [TextBlock] {
        let candidates = textBlocks.filter {
            ($0.translation ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        return AITranslator.sortedTextBlocks(candidates, isRightToLeft: isRightToLeftReading)
    }

    private func displayTranslation(for block: TextBlock) -> String {
        // translationLines are a horizontal layout suggestion. Vertical
        // CoreText layout must receive the natural string so it can create
        // real vertical columns and apply vertical punctuation forms.
        if block.textOrientation == .vertical {
            return (block.translation ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return TranslationOutputValidator.validatedDisplayTranslation(
            canonicalTranslation: block.translation ?? "",
            translationLines: block.translationLines,
            sourceText: block.text,
            target: TranslationTargetLanguage.migrateLegacyValue(targetLanguage)
        )
    }

    private func validatedTranslationLines(for block: TextBlock) -> [String] {
        TranslationOutputValidator.validatedTranslationLines(
            block.translationLines,
            canonicalTranslation: block.translation ?? "",
            sourceText: block.text,
            target: TranslationTargetLanguage.migrateLegacyValue(targetLanguage)
        )
    }

    @ViewBuilder
    private func ocrMagnificationOverlay(in size: CGSize) -> some View {
        if isOCRMagnificationVisible {
            ForEach(ocrLayoutItems(in: size)) { item in
                let text = item.blocks.map(\.text).joined(separator: "\n\n")
                Text(text)
                    .font(.system(size: uniformOCRFontSize, weight: .semibold))
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.92))
                    .foregroundColor(.black)
                    .cornerRadius(6)
                    .frame(width: item.rect.size.width)
                    .position(x: item.rect.midX, y: item.rect.midY)
                    // 放大镜是纯展示层：白卡不得吞掉其下方的翻页/长按/缩放手势。
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func ocrDebugOverlay(in size: CGSize) -> some View {
        if ocrShowDebugBoxes, isOCREnabled {
            switch selectedOCRDebugStage {
            case .raw:
                ocrDebugStage(debugRawBlocks, stage: selectedOCRDebugStage.token, color: .yellow, in: size)
            case .candidate:
                ocrDebugStage(debugCandidateBlocks, stage: selectedOCRDebugStage.token, color: .orange, in: size)
            case .filtered:
                ocrDebugStage(debugFilteredBlocks, stage: selectedOCRDebugStage.token, color: .cyan, in: size)
            case .filteredOut:
                ocrDebugStage(debugFilteredOutBlocks, stage: selectedOCRDebugStage.token, color: .pink, in: size)
            case .rejected:
                ocrDebugStage(debugRejectedBlocks, stage: selectedOCRDebugStage.token, color: .red, in: size)
            case .bubble:
                ocrDebugStage(debugBubbleBlocks, stage: selectedOCRDebugStage.token, color: .green, in: size)
            case .translation:
                ocrDebugTranslationStage(in: size)
            }
        }
    }

    @ViewBuilder
    private func ocrDebugStage(
        _ blocks: [TextBlock],
        stage: String,
        color: Color,
        in size: CGSize
    ) -> some View {
        ForEach(blocks) { block in
            // Debug geometry must be the exact mapped OCR rectangle. The
            // readable label is allowed to overflow/float; it must never
            // enlarge the rectangle used to diagnose OCR or layout.
            let rect = exactOCRDebugRect(for: block, in: size)
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .strokeBorder(color, lineWidth: 1.2)
                Text(debugLabel(for: block, stage: stage))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .lineLimit(4)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(2)
                    .background(color.opacity(0.86))
                    .foregroundStyle(.white)
                    .offset(x: 2, y: -2)
            }
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
        }
    }

    private func debugLabel(for block: TextBlock, stage: String) -> String {
        let confidence = Int((block.confidence * 100).rounded())
        if block.isFiltered {
            return "\(stage) \(confidence)% \(block.filterReason ?? "common.filter".localized)\n\(block.text)"
        }
        return "\(stage) \(confidence)% \(block.ocrSource)\n\(block.text)"
    }

    @ViewBuilder
    private func ocrDebugTranslationStage(in size: CGSize) -> some View {
        ForEach(translationDebugItems(in: size)) { item in
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .stroke(.yellow, style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
                    .frame(width: item.sourceRect.width, height: item.sourceRect.height)
                    .position(x: item.sourceRect.midX, y: item.sourceRect.midY)
                Rectangle()
                    .stroke(.blue, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    .frame(width: item.allowedBounds.width, height: item.allowedBounds.height)
                    .position(x: item.allowedBounds.midX, y: item.allowedBounds.midY)
                Rectangle()
                    .stroke(.green, lineWidth: 1.5)
                    .frame(width: item.layoutRect.width, height: item.layoutRect.height)
                    .position(x: item.layoutRect.midX, y: item.layoutRect.midY)
                Text("SOURCE / ALLOWED / CARD\n\(item.block.text)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .lineLimit(3)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(2)
                    .background(Color.black.opacity(0.78))
                    .foregroundStyle(.white)
                    .position(
                        x: item.layoutRect.minX + 2,
                        y: max(item.layoutRect.minY - 10, 10)
                    )
            }
            .allowsHitTesting(false)
        }
    }

    private func exactOCRDebugRect(for block: TextBlock, in size: CGSize) -> CGRect {
        OCRCoordinateMapper.displayRect(
            forNormalizedPageRect: block.boundingBox,
            using: ocrDisplayTransform(in: size)
        )
    }

    private func overlayRect(for block: TextBlock, in size: CGSize, scaleMultiplier: CGFloat) -> CGRect {
        overlayRect(
            forNormalizedPageRect: block.boundingBox,
            in: size,
            scaleMultiplier: scaleMultiplier
        )
    }

    private func overlayRect(
        forNormalizedPageRect normalizedRect: CGRect,
        in size: CGSize,
        scaleMultiplier: CGFloat
    ) -> CGRect {
        let mapped = OCRCoordinateMapper.displayRect(
            forNormalizedPageRect: normalizedRect,
            using: ocrDisplayTransform(in: size)
        )
        let width = max(mapped.width * scaleMultiplier, 44)
        let height = max(mapped.height * scaleMultiplier, 24)
        return CGRect(
            x: mapped.midX - width / 2,
            y: mapped.midY - height / 2,
            width: width,
            height: height
        )
    }

    private func ocrDisplayTransform(in size: CGSize) -> OCRDisplayTransform {
        let sourceSize: CGSize
        if let cgImage = uiImage?.cgImage {
            sourceSize = CGSize(width: cgImage.width, height: cgImage.height)
        } else if let uiImage {
            sourceSize = CGSize(
                width: uiImage.size.width * uiImage.scale,
                height: uiImage.size.height * uiImage.scale
            )
        } else {
            sourceSize = size
        }
        let fitMode: OCRImageFitMode
        switch imageFitMode {
        case .fitScreen: fitMode = .fitScreen
        case .fitWidth: fitMode = .fitWidth
        case .fitHeight: fitMode = .fitHeight
        case .original: fitMode = .original
        }
        // 覆盖层附着在图片上，外层 scaleEffect/offset 会同时作用于两者。
        return OCRCoordinateMapper.displayTransform(
            sourcePixelSize: sourceSize,
            containerSize: size,
            fitMode: fitMode
        )
    }

    private func translationLayoutItem(for block: TextBlock, in size: CGSize) -> TranslationLayoutItem {
        let geometry = translationLayoutGeometry(for: block, in: size)
        let translation = (block.translation ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return TranslationLayoutItem(
            blocks: [block],
            rect: geometry.choice.layout.rect,
            allowedBounds: geometry.allowedBounds,
            fontSize: geometry.choice.layout.fontSize,
            contentPadding: geometry.choice.layout.contentPadding,
            displayText: translation.isEmpty ? nil : geometry.choice.text,
            textOrientation: geometry.translationOrientation,
            layoutRole: block.layoutRole,
            contentRole: block.translationContentRole,
            displayMode: geometry.displayMode,
            surfaceStyle: geometry.surfaceStyle,
            layoutStatus: geometry.choice.layout.status
        )
    }

    private func translationLayoutGeometry(
        for block: TextBlock,
        in size: CGSize
    ) -> (
        sourceRect: CGRect,
        allowedBounds: CGRect,
        layoutBounds: CGRect,
        translationOrientation: TextOrientation,
        displayMode: TranslationDisplayMode,
        surfaceStyle: TranslationSurfaceStyle,
        choice: OCRBubbleLayoutEngine.TranslationLayoutChoice
    ) {
        let transform = ocrDisplayTransform(in: size)
        // 离线译文以 OCR textBox 的真实显示矩形为锚点；不能复用带最小点击尺寸的 overlayRect。
        let textRect = OCRCoordinateMapper.displayRect(
            forNormalizedPageRect: block.boundingBox,
            using: transform
        )
        let translation = (block.translation ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveTranslation = translation.isEmpty ? block.text : translation
        let translationOrientation = OCRBubbleLayoutEngine.effectiveTranslationOrientation(
            sourceOrientation: block.textOrientation,
            targetLanguage: TranslationTargetLanguage.migrateLegacyValue(targetLanguage),
            translatedText: effectiveTranslation
        )
        let imageBounds = transform.imageRect
        let usableBubbleBounds = usableTranslationBubbleBounds(
            for: block,
            textRect: textRect,
            using: transform
        )
        // 气泡存在性只判定一次：allowedBounds、字号策略与渲染层的表面样式都从这
        // 一个结果派生，避免"布局判断 A、渲染判断 B"的状态漂移。
        let hasReliableBubble = usableBubbleBounds != nil
        let displayMode = TranslationDisplayPolicy.mode(
            contentRole: block.translationContentRole,
            hasReliableDetectedBubble: hasReliableBubble,
            prefersInPlace: comic?.prefersInPlaceTranslation ?? false
        )
        let surfaceStyle = TranslationSurfacePolicy.surfaceStyle(
            hasReliableBubble: hasReliableBubble
        )
        let mappedSafeRegion = block.effectiveLayoutSafeRegion.map {
            OCRCoordinateMapper.displayRect(forNormalizedPageRect: $0, using: transform)
        }
        let resolvedSafeRegion = TranslationRegionPolicy.resolvedLayoutSafeRegion(
            sourceTextRegion: textRect,
            proposedSafeRegion: mappedSafeRegion,
            detectedBubble: usableBubbleBounds,
            pageBounds: imageBounds
        )
        let fallbackBounds: CGRect
        if OCRBubbleLayoutEngine.usesStandaloneLayout(for: block) {
            fallbackBounds = OCRBubbleLayoutEngine.standaloneTranslationBounds(
                around: textRect,
                within: imageBounds
            )
        } else {
            fallbackBounds = limitedTranslationFallbackBounds(
                around: textRect,
                within: imageBounds
            )
        }
        let allowedBounds = resolvedSafeRegion ?? usableBubbleBounds ?? fallbackBounds
        let layoutBounds = OCRBubbleLayoutEngine.boundedTranslationBounds(
            around: textRect,
            within: allowedBounds,
            imageBounds: imageBounds
        )
        let automaticFontSize = hasReliableBubble
            ? preferredTranslationFontSize(
                for: block,
                in: size,
                textRect: textRect,
                sizingMode: .bubble
            )
            : 1
        let requestedFontSize = OCRBubbleLayoutEngine.requestedTranslationFontSize(
            hasReliableBubble: hasReliableBubble,
            automaticFontSize: automaticFontSize,
            measuredTextFontSize: measuredTextTranslationFontSize
        )
        let choice = OCRBubbleLayoutEngine.preferredTranslationLayout(
            translation: effectiveTranslation,
            translationLines: translation.isEmpty ? [] : validatedTranslationLines(for: block),
            sourceFontSize: requestedFontSize,
            sourceRect: textRect,
            allowedBounds: layoutBounds,
            lineSpacing: 2,
            textOrientation: translationOrientation,
            // detected bubble 沿用真实气泡范围；measuredText 只按译文测量结果排版。
            geometryStrategy: hasReliableBubble ? .detectedBubble : .measuredText,
            minimumReadableFontSize: CGFloat(comic?.minimumReadableTranslationFontSize ?? ComicBook.defaultMinimumReadableTranslationFontSize)
        )
        #if DEBUG
        MReaderLog.aiTranslation.debug(
            "translation layout sourceOrientation=\(block.textOrientation.rawValue, privacy: .public) translationOrientation=\(translationOrientation.rawValue, privacy: .public) role=\(block.layoutRole.rawValue, privacy: .public) sourceFont=\(String(format: "%.1f", requestedFontSize), privacy: .public) chosenFont=\(String(format: "%.1f", choice.layout.fontSize), privacy: .public) contentPadding=\(String(format: "%.1f", choice.layout.contentPadding), privacy: .public) sourceRect=\(String(describing: textRect), privacy: .public) allowedBounds=\(String(describing: allowedBounds), privacy: .public) layoutBounds=\(String(describing: layoutBounds), privacy: .public) bubble=\(hasReliableBubble, privacy: .public) surface=\(surfaceStyle.rawValue, privacy: .public) layoutRect=\(String(describing: choice.layout.rect), privacy: .public)"
        )
        #endif
        return (
            sourceRect: textRect,
            allowedBounds: allowedBounds,
            layoutBounds: layoutBounds,
            translationOrientation: translationOrientation,
            displayMode: displayMode,
            surfaceStyle: surfaceStyle,
            choice: choice
        )
    }

    private func usableTranslationBubbleBounds(
        for block: TextBlock,
        textRect: CGRect,
        using transform: OCRDisplayTransform
    ) -> CGRect? {
        OCRBubbleLayoutEngine.usableTranslationBubbleBounds(
            for: block,
            textRect: textRect,
            using: transform
        )
    }

    private func translationDebugItems(in size: CGSize) -> [OCRTranslationDebugItem] {
        translationLayoutItems(in: size).compactMap { item in
            guard let block = item.blocks.first else { return nil }
            let geometry = translationLayoutGeometry(for: block, in: size)
            return OCRTranslationDebugItem(
                block: block,
                sourceRect: geometry.sourceRect,
                allowedBounds: geometry.allowedBounds,
                layoutRect: item.rect
            )
        }
    }

    private func limitedTranslationFallbackBounds(around textRect: CGRect, within imageBounds: CGRect) -> CGRect {
        guard !imageBounds.isNull, imageBounds.width > 0, imageBounds.height > 0 else {
            return textRect
        }
        let maximumWidth = min(textRect.width * 2.5, imageBounds.width * 0.55)
        let maximumHeight = min(textRect.height * 3.5, imageBounds.height * 0.45)
        let bounds = CGRect(
            x: textRect.midX - maximumWidth / 2,
            y: textRect.midY - maximumHeight / 2,
            width: maximumWidth,
            height: maximumHeight
        ).intersection(imageBounds)
        return bounds.isNull || bounds.width <= 0 || bounds.height <= 0 ? textRect : bounds
    }

    // MARK: - 布局缓存键（审查 #7）

    private func translationLayoutCacheKey(in size: CGSize) -> TranslationLayoutStore.Key {
        TranslationLayoutStore.Key(
            scope: "translation",
            content: layoutContentFingerprint(visibleTranslationBlocks),
            width: size.width,
            height: size.height,
            image: layoutImagePixelToken,
            style: layoutStyleToken
        )
    }

    private func ocrLayoutCacheKey(in size: CGSize) -> TranslationLayoutStore.Key {
        TranslationLayoutStore.Key(
            scope: "ocr-magnification",
            content: layoutContentFingerprint(ocrTextBlocks),
            width: size.width,
            height: size.height,
            image: layoutImagePixelToken,
            style: layoutStyleToken
        )
    }

    /// 排版输入指纹。只组合真正影响布局的 block 字段，O(n) 且不触碰 CoreText。
    /// `Hasher` 在进程内稳定，用于缓存相等性判断足够。
    private func layoutContentFingerprint(_ blocks: [TextBlock]) -> String {
        var hasher = Hasher()
        hasher.combine(blocks.count)
        for block in blocks {
            hasher.combine(block.id)
            hasher.combine(block.text)
            hasher.combine(block.translation ?? "")
            hasher.combine(block.translationLines)
            hasher.combine(block.textOrientation)
            hasher.combine(block.layoutRole)
            hasher.combine(block.translationContentRole)
            hasher.combine(block.boundingBox)
            hasher.combine(block.bubbleBox)
            hasher.combine(block.layoutSafeRegion)
            hasher.combine(block.estimatedFontScale)
            hasher.combine(block.confidence)
            hasher.combine(block.isFiltered)
        }
        return String(hasher.finalize())
    }

    private var layoutImagePixelToken: String {
        if let cgImage = uiImage?.cgImage {
            return "\(cgImage.width)x\(cgImage.height)"
        }
        if let uiImage {
            return "\(Int(uiImage.size.width * uiImage.scale))x\(Int(uiImage.size.height * uiImage.scale))"
        }
        return "none"
    }

    private var layoutStyleToken: String {
        [
            "layout-v\(TranslationLayoutStore.layoutRevision)",
            imageFitMode.rawValue,
            targetLanguage,
            isRightToLeftReading ? "rtl" : "ltr",
            (comic?.prefersInPlaceTranslation ?? false) ? "in-place" : "overlay",
            String(format: "%.4f", ocrTextScale),
            String(format: "%.4f", ocrSafeAreaInset),
            String(format: "%.5f", ocrMinimumTextHeight),
            String(format: "%.4f", normalizedOCRScale),
            String(format: "%.4f", uniformOCRFontSize),
            String(format: "%.2f", measuredTextTranslationFontSize)
        ].joined(separator: "|")
    }

    private func translationLayoutItems(in size: CGSize) -> [TranslationLayoutItem] {
        layoutStore.translationItems(for: translationLayoutCacheKey(in: size)) {
            computeTranslationLayoutItems(in: size)
        }
    }

    private func computeTranslationLayoutItems(in size: CGSize) -> [TranslationLayoutItem] {
        let initialItems = visibleTranslationBlocks.map { translationLayoutItem(for: $0, in: size) }
        var occupiedRects: [CGRect] = []
        var items: [TranslationLayoutItem] = []
        let transform = ocrDisplayTransform(in: size)

        for item in initialItems {
            let original = item.rect
            let sourceRect = item.blocks.reduce(CGRect.null) { $0.union($1.boundingBox) }
            let mappedSourceRect = OCRCoordinateMapper.displayRect(
                forNormalizedPageRect: sourceRect,
                using: transform
            )
            let boundedMovement = item.allowedBounds.intersection(transform.imageRect)
            let movementBounds = boundedMovement.isNull || boundedMovement.width <= 0 || boundedMovement.height <= 0
                ? transform.imageRect
                : boundedMovement
            let rect = OCRBubbleLayoutEngine.nonOverlappingRect(
                original,
                anchor: CGPoint(x: mappedSourceRect.midX, y: mappedSourceRect.midY),
                occupiedRects: occupiedRects,
                // Reliable bubbles are now a hard movement boundary. Measured
                // text keeps its local fallback region as the anchor boundary.
                bounds: movementBounds,
                margin: 0
            )
            let collisionRemains = occupiedRects.contains { $0.intersects(rect) }
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
            items.append(TranslationLayoutItem(
                blocks: item.blocks,
                rect: presentationRect,
                allowedBounds: item.allowedBounds,
                fontSize: item.fontSize,
                contentPadding: item.contentPadding,
                displayText: item.displayText,
                textOrientation: item.textOrientation,
                layoutRole: item.layoutRole,
                contentRole: item.contentRole,
                displayMode: item.displayMode,
                surfaceStyle: item.surfaceStyle,
                layoutStatus: layoutStatus
            ))
        }
        return items
    }

    private func ocrBubbleRect(for block: TextBlock, in size: CGSize) -> CGRect {
        let rectScale = 1 + (ocrTextSizeFactor - 1) * 0.28
        let original = overlayRect(for: block, in: size, scaleMultiplier: rectScale)
        let safeMargin: CGFloat = 12
        let imageBounds = ocrDisplayTransform(in: size).imageRect
        let maxWidth = max(44, imageBounds.width - safeMargin * 2)
        let width = min(max(original.width, 72), maxWidth)
        let characterCount = max(block.text.count, 1)
        let charactersPerLine = max(Int(width / max(uniformOCRFontSize * 0.72, 1)), 1)
        let lineCount = max(1, Int(ceil(Double(characterCount) / Double(charactersPerLine))))
        let height = min(
            max(CGFloat(lineCount) * uniformOCRFontSize * 1.3 + 8, 34),
            min(140, max(imageBounds.height - safeMargin * 2, 34))
        )
        return OCRBubbleLayoutEngine.clamped(
            CGRect(
                x: original.midX - width / 2,
                y: original.midY - height / 2,
                width: width,
                height: height
            ),
            to: imageBounds,
            margin: safeMargin
        )
    }

    private func ocrLayoutItems(in size: CGSize) -> [TranslationLayoutItem] {
        layoutStore.ocrItems(for: ocrLayoutCacheKey(in: size)) {
            computeOCRLayoutItems(in: size)
        }
    }

    private func computeOCRLayoutItems(in size: CGSize) -> [TranslationLayoutItem] {
        var occupiedRects: [CGRect] = []
        var items: [TranslationLayoutItem] = []
        let transform = ocrDisplayTransform(in: size)
        for block in ocrTextBlocks {
            let original = ocrBubbleRect(for: block, in: size)
            let mappedSourceRect = OCRCoordinateMapper.displayRect(
                forNormalizedPageRect: block.boundingBox,
                using: transform
            )
            let rect = OCRBubbleLayoutEngine.nonOverlappingRect(
                original,
                anchor: CGPoint(x: mappedSourceRect.midX, y: mappedSourceRect.midY),
                occupiedRects: occupiedRects,
                bounds: transform.imageRect
            )
            occupiedRects.append(rect.insetBy(dx: -4, dy: -4))
            items.append(TranslationLayoutItem(
                blocks: [block],
                rect: rect,
                allowedBounds: transform.imageRect,
                fontSize: uniformOCRFontSize,
                contentPadding: TranslationLayoutMetrics.contentPadding,
                displayText: nil,
                textOrientation: block.textOrientation,
                layoutRole: block.layoutRole,
                contentRole: block.translationContentRole,
                displayMode: .assistOverlay,
                // OCR 放大本身就是要盖住原文字，属于有意绘制的白底卡片。
                surfaceStyle: .detectedBubble,
                layoutStatus: .fitted
            ))
        }
        return items
    }

    private func loadImage() async {
        await MainActor.run {
            translationTask?.cancel()
            translationTask = nil
            offlineTranslationTask?.cancel()
            offlineTranslationTask = nil
            isOfflineTranslationDisplayed = false
            translationGeneration = UUID()
            ocrMagnificationTask?.cancel()
            ocrMagnificationTask = nil
            if isTranslating {
                isTranslating = false
                onTranslationStateChange(false)
            }
        }
        let maxPixelSize = preferredDecodeMaxPixelSize
        if let cachedImage = ReaderImageCache.shared.cachedImage(for: url, maxPixelSize: maxPixelSize) {
            await MainActor.run {
                isLoadingImage = false
                loadFailed = false
                uiImage = cachedImage
                isOfflineTranslationDisplayed = false
                textBlocks.removeAll()
                ocrTextBlocks.removeAll()
                debugRawBlocks.removeAll()
                debugCandidateBlocks.removeAll()
                debugFilteredBlocks.removeAll()
                debugFilteredOutBlocks.removeAll()
                debugLineBlocks.removeAll()
                debugBubbleBlocks.removeAll()
                debugRejectedBlocks.removeAll()
                translationErrorMessage = nil
                recognizedPipelineCache = nil
                recognizedPipelineCacheKey = nil
                scale = 1
                lastScale = 1
                offset = .zero
                lastOffset = .zero
                pendingSingleTapWorkItem?.cancel()
                pendingSingleTapWorkItem = nil
            }
            let hasOfflineTranslation = await loadOfflineTranslationIfAvailable()
            if isAutoTranslationEnabled, !hasOfflineTranslation {
                await MainActor.run { startTranslation() }
            }
            if isOCRMagnificationVisible {
                await MainActor.run { startOCRMagnification() }
            }
            return
        }

        await MainActor.run {
            isLoadingImage = true
            loadFailed = false
            uiImage = nil
            isOfflineTranslationDisplayed = false
            textBlocks.removeAll()
            ocrTextBlocks.removeAll()
            debugRawBlocks.removeAll()
            debugCandidateBlocks.removeAll()
            debugFilteredBlocks.removeAll()
            debugFilteredOutBlocks.removeAll()
            debugLineBlocks.removeAll()
            debugBubbleBlocks.removeAll()
            debugRejectedBlocks.removeAll()
            translationErrorMessage = nil
            recognizedPipelineCache = nil
            recognizedPipelineCacheKey = nil
            scale = 1
            lastScale = 1
            offset = .zero
            pendingSingleTapWorkItem?.cancel()
            pendingSingleTapWorkItem = nil
        }

        let loadedImage = await ReaderImageCache.shared.loadImage(for: url, maxPixelSize: maxPixelSize)
        await MainActor.run {
            self.uiImage = loadedImage
            self.loadFailed = loadedImage == nil
            self.isLoadingImage = false
        }
        let hasOfflineTranslation = await loadOfflineTranslationIfAvailable()
        if isAutoTranslationEnabled, !hasOfflineTranslation {
            await MainActor.run { startTranslation() }
        }
        if isOCRMagnificationVisible {
            await MainActor.run { startOCRMagnification() }
        }
    }

    /// 先检查运行中的 Set，再回退到 active Set；开关关闭或没有漫画上下文时不读取离线仓库。
    private func loadOfflineTranslationIfAvailable() async -> Bool {
        guard shouldDisplayOfflineTranslation,
              let comic,
              let pageIndex,
              uiImage != nil else {
            return false
        }
        offlineTranslationTask?.cancel()
        let page = ComicPage(index: pageIndex, url: url)
        let pageURL = url
        let target = TranslationTargetLanguage.migrateLegacyValue(targetLanguage)
        let source = comicTranslationSourceLanguage
        let task = Task {
            await OfflineTranslationOverlayProvider.validOverlay(
                comic: comic,
                page: page,
                targetLanguage: target,
                sourceLanguage: source
            )
        }
        offlineTranslationTask = task
        let result = await task.value
        guard !Task.isCancelled,
              self.url == pageURL,
              self.comic?.id == comic.id else {
            return false
        }
        offlineTranslationTask = nil
        switch result {
        case .displayed(let blocks, _):
            textBlocks = blocks
            isOfflineTranslationDisplayed = true
            return true
        case .confirmedNoText:
            // “确认无文字”不是不可用：允许自动实时 OCR 再检查，手动强制翻译仍走原有路径。
            textBlocks.removeAll()
            isOfflineTranslationDisplayed = false
            return false
        case .unavailable:
            isOfflineTranslationDisplayed = false
            return false
        }
    }

    /// scale > 1.05 视为“已放大”。与点击/长按手势的门控阈值保持一致，
    /// 单指拖动只有在放大态才被当作平移消费。
    private var isZoomedIn: Bool {
        ReaderGestureGate.isZoomed(scale: scale)
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let updated = min(max(lastScale * value, 1), 5)
                scale = updated
                // 缩小过程中同步收敛位移，避免图片被推出可视区域。
                offset = clampedOffset(offset, scale: updated)
            }
            .onEnded { _ in
                lastScale = scale
                if !ReaderGestureGate.isZoomed(scale: scale) {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                        scale = 1
                        lastScale = 1
                        offset = .zero
                        lastOffset = .zero
                    }
                } else {
                    offset = clampedOffset(offset, scale: scale)
                    lastOffset = offset
                }
            }
    }

    /// 单指平移：只在放大态生效，位移按图片实际显示矩形做边界 clamp，
    /// 保证放大后图片始终铺满自身布局框（不露出空白）。
    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard ReaderGestureGate.isZoomed(scale: scale) else { return }
                offset = clampedOffset(
                    CGSize(
                        width: lastOffset.width + value.translation.width,
                        height: lastOffset.height + value.translation.height
                    ),
                    scale: scale
                )
            }
            .onEnded { _ in
                guard ReaderGestureGate.isZoomed(scale: scale) else { return }
                lastOffset = offset
            }
    }

    /// 未放大时挂一个永不识别的拖拽，避免子视图手势抢占外层翻页拖拽；
    /// 放大后切换为真正的平移手势（子视图手势优先于父级翻页手势）。
    private var gatedPanGesture: AnyGesture<Void> {
        guard isZoomedIn else {
            return AnyGesture(DragGesture(minimumDistance: .infinity).map { _ in () })
        }
        return AnyGesture(panGesture.map { _ in () })
    }

    private func clampedOffset(_ proposed: CGSize, scale currentScale: CGFloat) -> CGSize {
        let container = zoomContentSize
        guard container.width > 1, container.height > 1, currentScale > 1 else { return .zero }
        // 覆盖层与图片共用同一套 scaleEffect/offset，坐标映射仍按 1x 计算；
        // 因此边界由 1x 的图片显示矩形推导。letterbox / original 下图片小于容器，
        // 缩放后未铺满的轴不允许平移。
        let imageRect = ocrDisplayTransform(in: container).imageRect
        let limits = ZoomPanGeometry.panLimits(
            imageRect: imageRect,
            containerSize: container,
            scale: currentScale
        )
        return ZoomPanGeometry.clampedOffset(proposed, limits: limits)
    }

    private var tapPageGesture: some Gesture {
        SpatialTapGesture(count: 1, coordinateSpace: .local)
            .onEnded { value in
                guard isPageTapGestureEnabled else { return }
                guard !ReaderGestureGate.isZoomed(scale: scale) else { return }
                guard Date().timeIntervalSince(lastDoubleTapTime) > 0.28 else { return }

                pendingSingleTapWorkItem?.cancel()
                let tapLocation = value.location
                let workItem = DispatchWorkItem {
                    guard Date().timeIntervalSince(lastDoubleTapTime) > 0.28 else { return }
                    let width = max(viewportWidth, 1)
                    if tapLocation.x < width / 3.0 {
                        onPreviousPage()
                    } else if tapLocation.x > width * 2.0 / 3.0 {
                        onNextPage()
                    }
                }
                pendingSingleTapWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
            }
    }

    private var longPressTranslationGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.55, maximumDistance: 18)
            .onEnded { _ in
                guard isLongPressTranslationEnabled, canTranslate, !ReaderGestureGate.isZoomed(scale: scale) else { return }
                pendingSingleTapWorkItem?.cancel()
                pendingSingleTapWorkItem = nil
                HapticManager.shared.play(.medium)
                startTranslation(force: true)
            }
    }

    private var uniformOCRFontSize: CGFloat {
        11 + CGFloat(normalizedOCRScale) * 8
    }

    private var measuredTextTranslationFontSize: CGFloat {
        CGFloat(
            ComicBook.clampedMeasuredTextTranslationFontSize(
                comic?.measuredTextTranslationFontSize
                    ?? ComicBook.defaultMeasuredTextTranslationFontSize
            )
        )
    }

    private func preferredTranslationFontSize(
        for block: TextBlock,
        in size: CGSize,
        textRect: CGRect,
        sizingMode: OCRBubbleLayoutEngine.TranslationTextSizingMode? = nil
    ) -> CGFloat {
        let imageRect = ocrDisplayTransform(in: size).imageRect
        // 字号缩放统一由 LayoutEngine 在“确实装不下”时决定，避免 0.98 被重复套用。
        let mode: OCRBubbleLayoutEngine.TranslationTextSizingMode =
            sizingMode
            ?? (OCRBubbleLayoutEngine.usesStandaloneLayout(for: block) ? .standaloneGlyph : .bubble)
        return OCRBubbleLayoutEngine.geometryCappedSourceFontSize(
            for: block,
            imageRect: imageRect,
            textRect: textRect,
            sizingMode: mode
        )
    }

    private var ocrTextSizeFactor: CGFloat {
        0.92 + CGFloat(normalizedOCRScale) * 0.44
    }

    private var normalizedOCRScale: Double {
        if ocrTextScale > 1 {
            return min(max((ocrTextScale - 0.8) / 2.4, 0), 1)
        }
        return min(max(ocrTextScale, 0), 1)
    }

    private func preparedOCRResult(from result: OCRPipelineResult) -> OCRPipelineResult {
        let annotated = AITranslator.annotatedMangaTextBlocks(
            result.resolvedBlocks,
            safeAreaInset: ocrSafeAreaInset,
            minimumTextHeight: ocrMinimumTextHeight,
            isRightToLeft: isRightToLeftReading
        )
        let filtered = annotated.filter { !$0.isFiltered }
        let segmentation = MangaTextSegmenter.segment(
            filtered,
            isRightToLeft: isRightToLeftReading
        )
        let filteredOut = annotated.filter(\.isFiltered)
        if ocrShowDebugBoxes {
            debugRawBlocks = result.rawBlocks
            debugCandidateBlocks = result.resolvedBlocks
            debugFilteredBlocks = filtered
            debugFilteredOutBlocks = filteredOut
            debugLineBlocks = segmentation.lines
            debugBubbleBlocks = segmentation.bubbles
            debugRejectedBlocks = result.rejectedBlocks
        } else {
            debugRawBlocks.removeAll()
            debugCandidateBlocks.removeAll()
            debugFilteredBlocks.removeAll()
            debugFilteredOutBlocks.removeAll()
            debugLineBlocks.removeAll()
            debugBubbleBlocks.removeAll()
            debugRejectedBlocks.removeAll()
        }
        return OCRPipelineResult(
            rawBlocks: result.rawBlocks,
            resolvedBlocks: filtered,
            lineBlocks: segmentation.lines,
            bubbleBlocks: segmentation.bubbles,
            rejectedBlocks: result.rejectedBlocks + filteredOut,
            detectedLanguage: result.detectedLanguage,
            quality: result.quality
        )
    }

    private var preferredDecodeMaxPixelSize: CGFloat {
        imageFitMode == .fitWidth ? 8192 : 4096
    }

    private func startOCRMagnification() {
        guard isOCREnabled, isOCRMagnificationVisible, !isRecognizingOCR, let image = uiImage else { return }
        isRecognizingOCR = true
        let pageURL = url

        ocrMagnificationTask?.cancel()
        ocrMagnificationTask = Task {
            do {
                let recognizedResult = try await recognizedPipelineResult(for: image)
                let blocks = preparedOCRResult(from: recognizedResult).bubbleBlocks
                await MainActor.run {
                    self.isRecognizingOCR = false
                    // 识别期间翻了页：丢弃旧页结果，并为当前页重新识别
                    guard self.url == pageURL else {
                        if self.isOCRMagnificationVisible {
                            self.startOCRMagnification()
                        }
                        return
                    }
                    self.ocrTextBlocks = blocks
                }
            } catch {
                await MainActor.run {
                    self.isRecognizingOCR = false
                    if self.url == pageURL {
                        self.ocrTextBlocks.removeAll()
                    }
                }
            }
            await MainActor.run {
                self.ocrMagnificationTask = nil
            }
        }
    }
    
    // 触发 AI 流程
    private func startTranslation(force: Bool = false) {
        translationTask?.cancel()
        guard canTranslate, let image = uiImage else { return }
        guard force || !isOfflineTranslationDisplayed else { return }
        if force {
            isOfflineTranslationDisplayed = false
            textBlocks.removeAll()
        }
        let pageURL = url
        let generation = UUID()
        translationGeneration = generation
        // 新一轮翻译开始：让在途 Apple 桥接的旧结果失效，避免旧 generation 写回
        appleTranslationGeneration = UUID()
        appleTranslationRequests = []
        appleSourceLanguageCode = nil
        translationErrorMessage = nil
        isTranslating = true
        onTranslationStateChange(true)

        translationTask = Task {
            do {
                // 翻译执行路径只由模式 / 低延迟策略决定，调试开关不得参与选择（审查 #5）。
                if useAppleLowLatency, aiTranslationMode == .ocr {
                    try await startAppleLowLatencyTranslation(image: image, pageURL: pageURL, generation: generation)
                } else {
                    let request = try makeTranslationPageRequest(image: image)
                    let blocks = try await AITranslationPageCoordinator.shared.translatedBlocks(for: request)
                    try Task.checkCancellation()
                    await MainActor.run {
                        guard self.translationGeneration == generation, self.url == pageURL else { return }
                        self.textBlocks = blocks
                    }
                }
                // Debug 只负责“数据采集 / 渲染”：在真实 pipeline 之外独立抓取中间 blocks，
                // 既不影响调用哪条翻译路径，也不影响生产结果。
                if ocrShowDebugBoxes, aiTranslationMode == .ocr {
                    await captureOCRDebugBlocks(image: image, pageURL: pageURL, generation: generation)
                }
            } catch {
                if !Task.isCancelled {
                    MReaderLog.aiTranslation.error("translation failed reason=\(MReaderLog.describe(error), privacy: .public)")
                    await MainActor.run {
                        guard self.translationGeneration == generation else { return }
                        self.translationErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        HapticManager.shared.play(.error)
                    }
                }
            }
            // 无论任务是否被新任务取代，都要归还“进行中”计数，避免进度边框卡住；
            // 只有最新代际才允许清理翻译状态（isTranslating / translationTask）。
            await MainActor.run {
                self.onTranslationStateChange(false)
                guard self.translationGeneration == generation else { return }
                if self.translationErrorMessage == nil {
                    HapticManager.shared.play(.success)
                }
                self.isTranslating = false
                self.translationTask = nil
            }
        }
    }

    /// Apple 原生翻译路径：本地 OCR → 先显示未翻译气泡 → AppleTranslationBridge 批量翻译 → 云端兜底。
    ///
    /// 源语言不由 TranslationSession 猜测：用户手动指定优先，否则用整页文本 + OCR 线索
    /// 由 TranslationSourceResolver 判断；仍无法判断时不创建 `source = nil` 的会话，
    /// 直接交给云端文本模型兜底。
    private func startAppleLowLatencyTranslation(image: UIImage, pageURL: URL, generation: UUID) async throws {
        let recognizedResult = try await recognizedPipelineResult(for: image)
        try Task.checkCancellation()
        let blocks = preparedOCRResult(from: recognizedResult).bubbleBlocks

        let targetCode = TranslationTargetLanguage.migrateLegacyValue(targetLanguage).rawValue
        let decision = TranslationSourceResolver.resolve(
            preference: comicTranslationSourceLanguage,
            blocks: blocks,
            previousStableLanguage: stableSourceLanguage,
            ocrHint: recognizedResult.detectedLanguage
        )
        let bridgeGeneration = UUID()

        if let decision {
            // 只有 automatic 的高可信检测才允许写入 stable language；
            // 手动指定语言不污染 stable（审查 #9）
            if comicTranslationSourceLanguage == .automatic, decision.confidence >= 0.8 {
                persistStableSourceLanguage(decision.languageCode)
            }
            let cacheKey = AppleTranslationPageCache.key(
                pageURL: pageURL,
                sourceLanguage: decision.languageCode,
                targetLanguage: targetCode,
                segmentationRevision: AITranslationPageRequest.ocrGeometryRevision,
                ocrRecognitionMode: OCRRecognitionMode(rawValue: ocrRecognitionModeRaw) ?? .adaptive,
                usesVisualOCRVerification: ocrVisualVerificationEnabled,
                isRightToLeft: isRightToLeftReading,
                minimumTextHeight: ocrMinimumTextHeight,
                safeAreaInset: ocrSafeAreaInset
            )
            if let cached = await AppleTranslationPageCache.shared.cachedBlocks(key: cacheKey) {
                await MainActor.run {
                    guard self.translationGeneration == generation, self.url == pageURL else { return }
                    self.textBlocks = cached
                    self.appleTranslationRequests = []
                }
                return
            }
            await MainActor.run {
                guard self.translationGeneration == generation, self.url == pageURL else { return }
                self.textBlocks = blocks
                self.appleTranslationRequests = blocks.map { AppleTranslationBlockRequest(id: $0.id, text: $0.text) }
                self.appleTranslationGeneration = bridgeGeneration
                self.appleSourceLanguageCode = decision.languageCode
            }
        } else {
            // 无法可靠判断源语言：不创建 Apple 会话（避免 source=nil 被 Apple 误判），
            // 全部交给云端文本模型兜底。
            await MainActor.run {
                guard self.translationGeneration == generation, self.url == pageURL else { return }
                self.textBlocks = blocks
                self.appleTranslationRequests = []
                self.appleSourceLanguageCode = nil
            }
            await MainActor.run {
                self.cloudFallbackForMissing(
                    blocks.map(\.id),
                    generation: generation,
                    pageURL: pageURL,
                    targetLanguage: targetCode
                )
            }
        }
    }

    /// 这本漫画已稳定识别的原文语言（按 comicID 持久化到 UserDefaults）。
    private var stableSourceLanguage: String? {
        guard let comicID else { return nil }
        let key = "translation_stable_source_\(comicID.uuidString)"
        return UserDefaults.standard.string(forKey: key)
    }

    private func persistStableSourceLanguage(_ code: String) {
        guard let comicID else { return }
        UserDefaults.standard.set(code, forKey: "translation_stable_source_\(comicID.uuidString)")
    }

    private func clearStableSourceLanguage() {
        guard let comicID else { return }
        UserDefaults.standard.removeObject(forKey: "translation_stable_source_\(comicID.uuidString)")
    }

    /// Apple 桥接结果是否仍属于当前代际/页面/目标语言（防止旧结果写回新翻译）。
    private func isAppleBridgeCurrent(
        generation: UUID,
        pageURL: URL,
        targetLanguage: String
    ) -> Bool {
        appleTranslationGeneration == generation
            && self.url == pageURL
            && self.targetLanguage == targetLanguage
    }

    /// Apple 翻译缺失项 → 整页云端 AI 兜底（只翻译缺失的 id）。
    @MainActor
    private func cloudFallbackForMissing(
        _ missingIDs: [UUID],
        generation: UUID,
        pageURL: URL,
        targetLanguage targetCode: String
    ) {
        guard !missingIDs.isEmpty else { return }
        Task {
            let missingBlocks = textBlocks.filter {
                missingIDs.contains($0.id) &&
                ($0.translation ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            guard !missingBlocks.isEmpty,
                  let activeConfiguration = AIProviderStore.shared.activeConfiguration() else { return }
            let requestTarget = TranslationTargetLanguage.migrateLegacyValue(self.targetLanguage)
            let contextScopeID = TranslationContextBuilder.scopeID(comicID: self.comicID, target: requestTarget)
            let inheritedContext = await TranslationContextRegistry.shared.context(
                scopeID: contextScopeID,
                pageIndex: self.pageIndex
            )
            let pageSnapshot = self.textBlocks
            do {
                // 纯文本兜底：用文本模型而不是昂贵的视觉模型（审查 #14）
                let pageResult = try await TranslationRuntimeService.translatePage(
                    blocks: missingBlocks,
                    apiKey: activeConfiguration.apiKey,
                    baseURL: activeConfiguration.baseURL,
                    model: activeConfiguration.textModel,
                    target: requestTarget,
                    promptTemplate: translationStyleInstructions,
                    sourceLanguage: comicTranslationSourceLanguage,
                    previousContext: TranslationContextBuilder.promptContext(
                        previousContext: inheritedContext,
                        pageBlocks: pageSnapshot,
                        requestedIndexes: pageSnapshot.indices.filter { index in
                            missingIDs.contains(pageSnapshot[index].id)
                        }
                    ),
                    modelDescriptor: activeConfiguration.textModelDescriptor
                )
                try Task.checkCancellation()
                await MainActor.run {
                    guard (self.translationGeneration == generation || self.appleTranslationGeneration == generation),
                          self.url == pageURL,
                          self.targetLanguage == targetCode else { return }
                    // 线上 ID 是 b0/b1/...，顺序 = missingBlocks 中的位置
                    for (position, block) in missingBlocks.enumerated() {
                        guard let index = self.textBlocks.firstIndex(where: { $0.id == block.id }),
                              let value = pageResult.translation(for: "b\(position)") else { continue }
                        self.textBlocks[index].translation = value.translation
                        self.textBlocks[index].translationLines = value.translationLines
                    }
                }
                await TranslationContextRegistry.shared.record(
                    scopeID: contextScopeID,
                    pageIndex: self.pageIndex,
                    blocks: self.textBlocks
                )
            } catch {
                MReaderLog.aiTranslation.notice("Apple translation cloud fallback failed reason=\(MReaderLog.describe(error), privacy: .public)")
            }
        }
    }

    private func makeTranslationPageRequest(image: UIImage) throws -> AITranslationPageRequest {
        guard let activeConfiguration = AIProviderStore.shared.activeConfiguration() else {
            throw AIProviderStoreError.missingProfile
        }
        return AITranslationPageRequest(
            pageURL: url,
            image: image,
            mode: aiTranslationMode,
            configuration: activeConfiguration,
            target: TranslationTargetLanguage.migrateLegacyValue(targetLanguage),
            translationPromptTemplate: translationStyleInstructions,
            // 自定义模板缺少协议锚点时回退默认模板：坏协议不进请求，也进不了缓存 key。
            visionPromptTemplate: AITranslator.VisionPromptContract.effectiveTemplate(visionTranslationPromptTemplate),
            isRightToLeft: isRightToLeftReading,
            minimumTextHeight: ocrMinimumTextHeight,
            ocrRecognitionMode: OCRRecognitionMode(rawValue: ocrRecognitionModeRaw) ?? .adaptive,
            safeAreaInset: ocrSafeAreaInset,
            usesVisualOCRVerification: ocrVisualVerificationEnabled,
            viewportAspect: visionViewportAspect
                ?? max(viewportSize.height / max(viewportSize.width, 1), 1.25),
            sourceLanguagePreference: comicTranslationSourceLanguage,
            previousContext: "",
            contextScopeID: TranslationContextBuilder.scopeID(
                comicID: comicID,
                target: TranslationTargetLanguage.migrateLegacyValue(targetLanguage)
            ),
            pageIndex: pageIndex
        )
    }

    /// 调试数据采集：只在 `ocrShowDebugBoxes` 打开时额外抓取一次 OCR 中间结果，
    /// 用于渲染 raw / candidate / filtered / bubble 框。
    /// 它不参与翻译 pipeline 选择，也不写回 `textBlocks`，因此调试与生产结果一致。
    private func captureOCRDebugBlocks(image: UIImage, pageURL: URL, generation: UUID) async {
        guard ocrShowDebugBoxes, isOCREnabled else { return }
        guard let recognizedResult = try? await recognizedPipelineResult(for: image) else { return }
        guard !Task.isCancelled else { return }
        await MainActor.run {
            guard self.url == pageURL, self.translationGeneration == generation else { return }
            _ = self.preparedOCRResult(from: recognizedResult)
        }
    }

    private func recognizedPipelineResult(for image: UIImage) async throws -> OCRPipelineResult {
        let activeConfiguration = AIProviderStore.shared.activeConfiguration()
        let modelIdentity = "text=\(activeConfiguration?.textModel ?? "none")|text-protocol=\(activeConfiguration?.textModelDescriptor.apiProtocol.rawValue ?? "none")|vision=\(activeConfiguration?.visionModel ?? "none")|vision-protocol=\(activeConfiguration?.visionModelDescriptor.apiProtocol.rawValue ?? "none")"
        let key = "\(url.absoluteString)#ocr-revision=\(JapaneseVerticalOCRService.revision)#rtl=\(isRightToLeftReading)#min=\(ocrMinimumTextHeight)#localMode=\(ocrRecognitionModeRaw)#visual=\(ocrVisualVerificationEnabled)#source=\(translationSourceLanguageRaw)#model=\(modelIdentity)"
        if recognizedPipelineCacheKey == key, let recognizedPipelineCache {
            return recognizedPipelineCache
        }
        let options = OCRPreprocessor.Options(
            isRightToLeft: isRightToLeftReading,
            minimumTextHeight: ocrMinimumTextHeight,
            recognitionMode: OCRRecognitionMode(rawValue: ocrRecognitionModeRaw) ?? .adaptive,
            sourceLanguagePreference: comicTranslationSourceLanguage
        )
        let cacheRequest = OCRRecognitionCacheRequest(
            pageURL: url,
            fallbackImage: image,
            options: options
        )
        let localResult = try await OCRRuntimeService.recognize(for: cacheRequest)
        if let comicID, let pageIndex {
            await OCRRuntimeService.index(
                comicID: comicID,
                pageIndex: pageIndex,
                blocks: localResult.bubbleBlocks
            )
        }
        let result: OCRPipelineResult
        if ocrVisualVerificationEnabled, let activeConfiguration {
            let ocrImage = await OCRPreprocessor.highResolutionImage(from: url, fallback: image) ?? image
            let reviewBlocks = localResult.resolvedBlocks + localResult.rejectedBlocks
            let corrected = try await TranslationRuntimeService.visualVerifyOCRRegions(
                image: ocrImage,
                blocks: reviewBlocks,
                apiKey: activeConfiguration.apiKey,
                baseURL: activeConfiguration.baseURL,
                model: activeConfiguration.visionModel,
                isRightToLeft: isRightToLeftReading,
                modelDescriptor: activeConfiguration.visionModelDescriptor,
                sourceLanguagePreference: comicTranslationSourceLanguage,
                detectedLanguage: localResult.detectedLanguage,
                visualVerificationEnabled: ocrVisualVerificationEnabled,
                coverageRecoveryRequested: localResult.quality?.isSuspicious == true
                    || !localResult.rejectedBlocks.isEmpty
            )
            let usableCorrected = corrected.filter { !$0.isFiltered }
            let segmentation = MangaTextSegmenter.segment(
                usableCorrected,
                isRightToLeft: isRightToLeftReading
            )
            result = OCRPipelineResult(
                rawBlocks: localResult.rawBlocks,
                resolvedBlocks: usableCorrected,
                lineBlocks: segmentation.lines,
                bubbleBlocks: segmentation.bubbles,
                rejectedBlocks: corrected.filter(\.isFiltered),
                detectedLanguage: localResult.detectedLanguage,
                quality: localResult.quality
            )
        } else {
            result = localResult
        }
        await MainActor.run {
            self.recognizedPipelineCacheKey = key
            self.recognizedPipelineCache = result
        }
        return result
    }
}

private struct TranslationLayoutItem: Identifiable {
    let blocks: [TextBlock]
    let rect: CGRect
    /// Region inside which collision avoidance is allowed to move this item.
    let allowedBounds: CGRect
    let fontSize: CGFloat
    /// 与 OCRBubbleLayoutEngine 测量时完全一致的卡片内边距。
    let contentPadding: CGFloat
    /// 译文布局阶段选出的实际排版文本；OCR 放大气泡保持 nil。
    let displayText: String?
    let textOrientation: TextOrientation
    let layoutRole: TranslationLayoutRole
    let contentRole: TranslationContentRole
    let displayMode: TranslationDisplayMode
    /// 有可靠漫画气泡时为 detectedBubble；否则为 measuredText。两种表面都绘制
    /// RoundedRectangle 背景，只采用不同的卡片尺寸算法。
    let surfaceStyle: TranslationSurfaceStyle
    let layoutStatus: OCRBubbleLayoutEngine.TranslationLayoutStatus

    var id: UUID { blocks.first?.id ?? Self.emptyBlockIdentity }

    /// 空 blocks 是异常路径；仍必须返回稳定 id，否则 ForEach 每帧都会重建整页视图。
    private static let emptyBlockIdentity = UUID()
}

/// 翻译 / OCR 放大覆盖层的布局缓存层。
///
/// `translationLayoutItems` / `ocrLayoutItems` 内部对每个 block 跑 `nonOverlappingRect`
/// （48 个候选 × 遍历已占用矩形）与多次 CoreText 测量，整体是 O(n²)。它们原本由
/// `body` 直接调用，任何无关 State 变化、动画帧或手势都会重算整页布局（审查 #7）。
///
/// 缓存键只包含真正影响排版的输入：页面内容指纹、覆盖层尺寸、图片像素尺寸、目标语言、
/// 字体与布局样式。命中缓存时直接复用上一次的结果。
private final class TranslationLayoutStore {
    /// 排版算法版本。算法语义变化时必须 +1，避免旧布局被复用。
    static let layoutRevision = 1

    struct Key: Equatable {
        let scope: String
        let content: String
        let width: CGFloat
        let height: CGFloat
        let image: String
        let style: String
    }

    private var translationKey: Key?
    private var translationItems: [TranslationLayoutItem] = []
    private var ocrKey: Key?
    private var ocrItems: [TranslationLayoutItem] = []

    #if DEBUG
    private(set) var translationRecomputeCount = 0
    private(set) var ocrRecomputeCount = 0
    #endif

    func translationItems(for key: Key, build: () -> [TranslationLayoutItem]) -> [TranslationLayoutItem] {
        if translationKey == key { return translationItems }
        let built = build()
        translationKey = key
        translationItems = built
        #if DEBUG
        translationRecomputeCount += 1
        #endif
        return built
    }

    func ocrItems(for key: Key, build: () -> [TranslationLayoutItem]) -> [TranslationLayoutItem] {
        if ocrKey == key { return ocrItems }
        let built = build()
        ocrKey = key
        ocrItems = built
        #if DEBUG
        ocrRecomputeCount += 1
        #endif
        return built
    }
}

private struct OCRTranslationDebugItem: Identifiable {
    let block: TextBlock
    let sourceRect: CGRect
    let allowedBounds: CGRect
    let layoutRect: CGRect

    var id: UUID { block.id }
}

private enum TranslationColorStyle: String, CaseIterable {
    case contrast
    case coolWarm
    case jewel

    var title: String {
        switch self {
        case .contrast: return "ocr.colorStyle.contrast".localized
        case .coolWarm: return "ocr.colorStyle.coolWarm".localized
        case .jewel: return "ocr.colorStyle.jewel".localized
        }
    }

    var palettes: [[Color]] {
        switch self {
        case .contrast:
            return [
                [Color(red: 0.02, green: 0.22, blue: 0.72), Color(red: 0.52, green: 0.05, blue: 0.58)],
                [Color(red: 0.0, green: 0.42, blue: 0.48), Color(red: 0.72, green: 0.16, blue: 0.18)],
                [Color(red: 0.18, green: 0.15, blue: 0.62), Color(red: 0.65, green: 0.22, blue: 0.04)]
            ]
        case .coolWarm:
            return [
                [Color(red: 0.0, green: 0.32, blue: 0.82), Color(red: 0.0, green: 0.62, blue: 0.68)],
                [Color(red: 0.86, green: 0.10, blue: 0.28), Color(red: 0.76, green: 0.34, blue: 0.02)],
                [Color(red: 0.30, green: 0.12, blue: 0.72), Color(red: 0.74, green: 0.12, blue: 0.52)]
            ]
        case .jewel:
            return [
                [Color(red: 0.05, green: 0.30, blue: 0.66), Color(red: 0.36, green: 0.08, blue: 0.54)],
                [Color(red: 0.0, green: 0.46, blue: 0.36), Color(red: 0.64, green: 0.08, blue: 0.18)],
                [Color(red: 0.12, green: 0.20, blue: 0.58), Color(red: 0.58, green: 0.28, blue: 0.0)]
            ]
        }
    }

    var coreTextColor: UIColor {
        switch self {
        case .contrast:
            return UIColor(red: 0.02, green: 0.22, blue: 0.72, alpha: 1)
        case .coolWarm:
            return UIColor(red: 0.0, green: 0.32, blue: 0.82, alpha: 1)
        case .jewel:
            return UIColor(red: 0.05, green: 0.30, blue: 0.66, alpha: 1)
        }
    }
}

private struct TranslationSurfaceRenderer: View {
    let layoutSize: CGSize
    let surfaceStyle: TranslationSurfaceStyle
    let displayMode: TranslationDisplayMode
    let layoutStatus: OCRBubbleLayoutEngine.TranslationLayoutStatus

    @ViewBuilder
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
}

private struct TranslationTextRenderer: View {
    let segments: [String]
    let fontSize: CGFloat
    let layoutSize: CGSize
    let contentPadding: CGFloat
    let style: TranslationColorStyle
    let textOrientation: TextOrientation
    let displayMode: TranslationDisplayMode
    let layoutStatus: OCRBubbleLayoutEngine.TranslationLayoutStatus
    @State private var isExpansionPresented = false

    private var fullText: String {
        segments.joined(separator: "\n\n")
    }

    var body: some View {
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

    static let palette: [Color] = [
        Color(red: 0.10, green: 0.38, blue: 0.82),
        Color(red: 0.32, green: 0.22, blue: 0.78),
        Color(red: 0.55, green: 0.18, blue: 0.72),
        Color(red: 0.75, green: 0.20, blue: 0.55),
        Color(red: 0.12, green: 0.58, blue: 0.65),
        Color(red: 0.18, green: 0.50, blue: 0.78),
        Color(red: 0.72, green: 0.38, blue: 0.18).opacity(0.7)
    ]
}

private extension UIColor {
    var swiftUIColor: Color { Color(self) }
}

/// Measurement and drawing both use TranslationTypesetter. The renderer no
/// longer has a second line-breaking algorithm that can disagree with layout.
private struct CoreTextTranslationView: UIViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let color: UIColor
    let textOrientation: TextOrientation
    let lineSpacing: CGFloat

    func makeUIView(context: Context) -> TranslationTextUIView {
        TranslationTextUIView()
    }

    func updateUIView(_ uiView: TranslationTextUIView, context: Context) {
        uiView.text = text
        uiView.fontSize = fontSize
        uiView.color = color
        uiView.textOrientation = textOrientation
        uiView.lineSpacing = lineSpacing
        uiView.setNeedsDisplay()
    }
}

private final class TranslationTextUIView: UIView {
    var text = ""
    var fontSize: CGFloat = 16
    var color = UIColor.label
    var textOrientation: TextOrientation = .horizontal
    var lineSpacing: CGFloat = 2

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    override func draw(_ rect: CGRect) {
        guard !text.isEmpty, bounds.width > 0, bounds.height > 0,
              let context = UIGraphicsGetCurrentContext() else { return }
        TranslationTypesetter.draw(
            text: text,
            in: bounds,
            context: context,
            fontSize: fontSize,
            orientation: textOrientation,
            lineSpacing: lineSpacing,
            color: color
        )
    }
}

private struct AppleIntelligenceGlowBorder: View {
    let cornerRadius: CGFloat
    let lineWidth: CGFloat
    let blurRadius: CGFloat
    let animationDuration: TimeInterval
    let colors: [Color]

    var body: some View {
        TimelineView(.animation) { context in
            let duration = max(animationDuration, 0.1)
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: duration) / duration
            GeometryReader { proxy in
                let bandWidth = max(lineWidth, 1)
                let screenCornerRadius = adaptiveScreenCornerRadius(for: proxy.size)
                let outerCornerRadius = (screenCornerRadius > 0 ? screenCornerRadius : cornerRadius) + 5
                let layerCount = 36
                let layerWidth = bandWidth / CGFloat(layerCount)
                let outwardExpansion = max(layerWidth * 1.5, 1)
                let drawingSize = CGSize(
                    width: proxy.size.width + outwardExpansion * 2,
                    height: proxy.size.height + outwardExpansion * 2
                )
                ZStack {
                    ForEach(0..<layerCount, id: \.self) { index in
                        let progress = CGFloat(index) / CGFloat(max(layerCount - 1, 1))
                        let opacity = 1.0 - Double(progress) * 0.94
                        RoundedRectangle(
                            cornerRadius: max(outerCornerRadius - CGFloat(index) * layerWidth, 0),
                            style: .continuous
                        )
                        .inset(by: outwardExpansion + CGFloat(index) * layerWidth)
                        .strokeBorder(
                            flowingGradient(phase: phase + Double(index) * 0.004),
                            lineWidth: max(layerWidth + 0.12, 0.55),
                            antialiased: true
                        )
                        .opacity(opacity)
                    }

                    RoundedRectangle(cornerRadius: outerCornerRadius, style: .continuous)
                        .inset(by: outwardExpansion)
                        .strokeBorder(flowingGradient(phase: phase), lineWidth: max(layerWidth * 2.2, 1.2), antialiased: true)
                        .opacity(1)
                        .brightness(0.16)
                }
                .frame(width: drawingSize.width, height: drawingSize.height)
                .offset(x: -outwardExpansion, y: -outwardExpansion)
            }
            .drawingGroup()
        }
    }

    private func flowingGradient(phase: Double) -> AngularGradient {
        let palette = colors.isEmpty ? TranslationTextRenderer.palette : colors
        let normalizedPhase = phase.truncatingRemainder(dividingBy: 1)
        let gradientColors = palette + palette.prefix(2)
        return AngularGradient(
            colors: gradientColors,
            center: .center,
            angle: .degrees(normalizedPhase * 360)
        )
    }

    private func adaptiveScreenCornerRadius(for size: CGSize) -> CGFloat {
        let modelIdentifier = Self.deviceModelIdentifier
        if UIDevice.current.userInterfaceIdiom == .pad {
            if let exactRadius = Self.iPadCornerRadiusByIdentifier[modelIdentifier] {
                return exactRadius
            }
            let screen = Self.normalizedScreenSize(for: size)
            if screen.minSide >= 740 && screen.minSide <= 770 && screen.maxSide >= 1000 && screen.maxSide <= 1040 {
                return 22
            }
            return min(max(min(size.width, size.height) * 0.035, 20), 30)
        }
        if Self.squareScreenIPhoneIdentifiers.contains(modelIdentifier) {
            return 0
        }
        if let exactRadius = Self.iPhoneCornerRadiusByIdentifier[modelIdentifier] {
            return exactRadius
        }
        let screen = Self.normalizedScreenSize(for: size)
        if screen.minSide >= 400 && screen.minSide <= 405 && screen.maxSide >= 870 && screen.maxSide <= 878 {
            return 62
        }
        if screen.minSide >= 410 && screen.minSide <= 416 && screen.maxSide >= 890 && screen.maxSide <= 900 {
            return 46
        }
        let shortSide = min(size.width, size.height)
        guard shortSide > 0 else { return cornerRadius }
        switch shortSide {
        case ..<380:
            return 39
        case ..<395:
            return 47
        case ..<430:
            return 55
        default:
            return 62
        }
    }

    private static func normalizedScreenSize(for size: CGSize) -> (minSide: CGFloat, maxSide: CGFloat) {
        let width = min(size.width, size.height)
        let height = max(size.width, size.height)
        return (width, height)
    }

    private static var deviceModelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) { machinePointer in
                String(cString: machinePointer)
            }
        }
    }

    private static let squareScreenIPhoneIdentifiers: Set<String> = [
        "iPhone10,1", "iPhone10,4",
        "iPhone12,8",
        "iPhone14,6"
    ]

    private static let iPhoneCornerRadiusByIdentifier: [String: CGFloat] = [
        "iPhone10,3": 39,
        "iPhone10,6": 39,
        "iPhone11,2": 39,
        "iPhone11,4": 41,
        "iPhone11,6": 41,
        "iPhone11,8": 39,
        "iPhone12,1": 46,
        "iPhone12,3": 39,
        "iPhone12,5": 41,
        "iPhone13,1": 44,
        "iPhone13,2": 47,
        "iPhone13,3": 47,
        "iPhone13,4": 53,
        "iPhone14,2": 55,
        "iPhone14,3": 55,
        "iPhone14,4": 44,
        "iPhone14,5": 47,
        "iPhone14,7": 47,
        "iPhone14,8": 53,
        "iPhone15,2": 55,
        "iPhone15,3": 55,
        "iPhone15,4": 55,
        "iPhone15,5": 55,
        "iPhone16,1": 55,
        "iPhone16,2": 55,
        "iPhone17,1": 62,
        "iPhone17,2": 66,
        "iPhone17,3": 62,
        "iPhone17,4": 62,
        "iPhone17,5": 62,
        "iPhone18,1": 62,
        "iPhone18,2": 62,
        "iPhone18,3": 58,
        "iPhone18,4": 58
    ]

    private static let iPadCornerRadiusByIdentifier: [String: CGFloat] = [
        "iPad14,1": 22,
        "iPad14,2": 22,
        "iPad16,1": 22,
        "iPad16,2": 22
    ]
}
