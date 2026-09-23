import Foundation
import CryptoKit
import ImageIO
import UIKit
import os

nonisolated enum RemoteImageLoader {
    nonisolated struct CoverCacheResult: Sendable, Equatable {
        let path: String
        let didWrite: Bool
    }

    private static var cacheRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MReaderRemoteCovers", isDirectory: true)
    }

    private static var legacyCacheRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MReaderRemoteImageCache", isDirectory: true)
    }

    static func migrateLegacyCoversIfNeeded() {
        let legacyRoot = legacyCacheRoot
        let newRoot = cacheRoot
        guard FileManager.default.fileExists(atPath: legacyRoot.path) else { return }
        do {
            try FileManager.default.moveItem(at: legacyRoot, to: newRoot)
            MReaderLog.reader.notice("migrated legacy cover cache to Application Support")
        } catch {
            MReaderLog.reader.error("cover cache migration failed reason=\(MReaderLog.describe(error), privacy: .public)")
        }
    }

    static func cachedCoverPath(sourceID: UUID, bookID: String) -> String? {
        let candidates = [
            coverURL(sourceID: sourceID, bookID: bookID),
            legacyCoverURL(sourceID: sourceID, bookID: bookID, root: cacheRoot),
            legacyCoverURL(sourceID: sourceID, bookID: bookID, root: legacyCacheRoot)
        ]
        return candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })?.path
    }

    /// 优先使用当前容器中按稳定远程身份计算出的缓存路径，避免依赖 library.json
    /// 中可能已经过期的绝对沙盒路径。没有缓存时保留传入路径，交给调用方决定是否
    /// 继续使用远程引用或显示占位图。
    static func resolvedCoverPath(
        persistedPath: String?,
        sourceID: UUID?,
        bookID: String?
    ) -> String? {
        if let sourceID,
           let bookID,
           let cachedPath = cachedCoverPath(sourceID: sourceID, bookID: bookID) {
            return cachedPath
        }
        return persistedPath
    }

    static func cacheCoverData(_ data: Data, sourceID: UUID, bookID: String) -> String? {
        cacheCoverDataWithResult(data, sourceID: sourceID, bookID: bookID)?.path
    }

    static func cacheCoverDataWithResult(
        _ data: Data,
        sourceID: UUID,
        bookID: String
    ) -> CoverCacheResult? {
        let url = coverURL(sourceID: sourceID, bookID: bookID)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return CoverCacheResult(path: url.path, didWrite: true)
        } catch {
            return nil
        }
    }

    static func removeCachedImages(sourceID: UUID) {
        for root in [cacheRoot, legacyCacheRoot] {
            let url = root.appendingPathComponent(sourceID.uuidString, isDirectory: true)
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func removeCachedImages(sourceID: UUID, bookID: String) {
        for root in [cacheRoot, legacyCacheRoot] {
            for url in [
                coverURL(sourceID: sourceID, bookID: bookID, root: root),
                legacyCoverURL(sourceID: sourceID, bookID: bookID, root: root)
            ] {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func coverURL(sourceID: UUID, bookID: String) -> URL {
        coverURL(sourceID: sourceID, bookID: safeFileName(bookID), root: cacheRoot)
    }

    private static func coverURL(sourceID: UUID, bookID: String, root: URL) -> URL {
        root
            .appendingPathComponent(sourceID.uuidString, isDirectory: true)
            .appendingPathComponent("covers", isDirectory: true)
            .appendingPathComponent(bookID)
            .appendingPathExtension("img")
    }

    private static func legacyCoverURL(sourceID: UUID, bookID: String, root: URL) -> URL {
        coverURL(sourceID: sourceID, bookID: legacySafeFileName(bookID), root: root)
    }

    static func safeFileName(_ rawValue: String) -> String {
        let digest = SHA256.hash(data: Data(rawValue.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func legacySafeFileName(_ rawValue: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = rawValue.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let sanitized = String(scalars)
        return sanitized.isEmpty ? UUID().uuidString : sanitized
    }
}

nonisolated enum RemotePageLoader {
    private static let scheme = "mreader-komga-page"

    private static var cacheRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MReaderRemotePageCache", isDirectory: true)
    }

    static func loadPages(for comic: ComicBook) async -> ComicManager.LoadResult? {
        guard comic.sourceType == .komga,
              let sourceID = comic.mediaSourceID,
              let bookID = comic.komgaBookID else {
            return nil
        }
        guard await KomgaProvider.loadSources().contains(where: { $0.id == sourceID && $0.type == .komga && $0.isEnabled }) else {
            MReaderLog.reader.notice(
                "Komga source disabled; refused to open remote comic source=\(sourceID.uuidString, privacy: .public) comic=\(comic.id.uuidString, privacy: .public)"
            )
            return nil
        }
        let totalPages = max(comic.remotePageCount ?? comic.totalPages, 0)
        guard totalPages > 0 else { return nil }
        let pages = (0..<totalPages).map { index in
            ComicPage(index: index, url: pageURL(sourceID: sourceID, bookID: bookID, pageIndex: index))
        }
        let rootURL = URL(string: "\(scheme)://\(sourceID.uuidString)/\(RemoteImageLoader.safeFileName(bookID))")!
        return ComicManager.LoadResult(url: rootURL, accessToken: nil, pages: pages)
    }

    static func isRemotePageURL(_ url: URL) -> Bool {
        url.scheme == scheme
    }

    static func pageIndex(forRemotePageURL url: URL) -> Int? {
        RemotePageRequest(url: url)?.pageIndex
    }

    static func imageData(forRemotePageURL url: URL) async -> Data? {
        guard let request = RemotePageRequest(url: url) else { return nil }
        if let offline = OfflinePageStore.data(for: request.cacheKey), !offline.isEmpty {
            await registerPageGeometryIfAvailable(offline, for: request.cacheKey)
            MReaderLog.reader.debug(
                "offline page cache hit page=\(request.pageIndex, privacy: .public) key=\(request.cacheKey.logDescription, privacy: .public)"
            )
            return offline
        }
        return await RemotePageCache.shared.data(for: request.cacheKey, priority: .current)
    }

    static func prefetchImageData(forRemotePageURL url: URL) async {
        guard let request = RemotePageRequest(url: url) else { return }
        _ = await RemotePageCache.shared.data(for: request.cacheKey, priority: .prefetch)
    }

    static func pruneDiskCache() async {
        let limitBytes = Int64(remoteCacheLimits().diskLimitMB) * 1024 * 1024
        await Task.detached(priority: .background) {
            pruneRemotePageDiskCache(limitBytes: limitBytes)
        }.value
    }

    static func removeCachedPages(sourceID: UUID, bookID: String) {
        for url in [
            pageBookDirectory(sourceID: sourceID, fileName: RemoteImageLoader.safeFileName(bookID)),
            pageBookDirectory(sourceID: sourceID, fileName: RemoteImageLoader.legacySafeFileName(bookID))
        ] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func removeCachedPages(sourceID: UUID) {
        let url = cacheRoot.appendingPathComponent(sourceID.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: url)
    }

    nonisolated static func pageURL(sourceID: UUID, bookID: String, pageIndex: Int) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = sourceID.uuidString
        components.path = "/\(RemoteImageLoader.safeFileName(bookID))/\(pageIndex)"
        components.queryItems = [
            URLQueryItem(name: "bookID", value: bookID)
        ]
        return components.url!
    }

    nonisolated static func pageCacheURL(sourceID: UUID, bookID: String, pageIndex: Int) -> URL {
        pageBookDirectory(sourceID: sourceID, fileName: RemoteImageLoader.safeFileName(bookID))
            .appendingPathComponent("\(pageIndex)")
            .appendingPathExtension("img")
    }

    static func registerPageGeometryIfAvailable(_ data: Data, for key: PageCacheKey) async {
        guard let size = RemotePageGeometry.pixelSize(from: data) else { return }
        let url = pageURL(sourceID: key.sourceID, bookID: key.bookID, pageIndex: key.pageIndex)
        await MainActor.run {
            PageGeometryStore.shared.setSize(size, for: url)
        }
    }

    nonisolated static func legacyPageCacheURL(sourceID: UUID, bookID: String, pageIndex: Int) -> URL {
        pageBookDirectory(sourceID: sourceID, fileName: RemoteImageLoader.legacySafeFileName(bookID))
            .appendingPathComponent("\(pageIndex)")
            .appendingPathExtension("img")
    }

    private static func pageBookDirectory(sourceID: UUID, fileName: String) -> URL {
        cacheRoot
            .appendingPathComponent(sourceID.uuidString, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: true)
    }

    struct RemotePageRequest: Sendable {
        let sourceID: UUID
        let bookID: String
        let pageIndex: Int

        var cacheKey: PageCacheKey {
            PageCacheKey(sourceID: sourceID, bookID: bookID, pageIndex: pageIndex)
        }

        init?(url: URL) {
            guard let host = url.host,
                  let sourceID = UUID(uuidString: host),
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let bookID = components.queryItems?.first(where: { $0.name == "bookID" })?.value,
                  let lastPathComponent = url.pathComponents.last,
                  let pageIndex = Int(lastPathComponent) else {
                return nil
            }
            self.sourceID = sourceID
            self.bookID = bookID
            self.pageIndex = pageIndex
        }
    }
}

nonisolated struct PageCacheKey: Hashable, Sendable {
    let sourceID: UUID
    let bookID: String
    let pageIndex: Int

    var logDescription: String {
        "\(sourceID.uuidString.prefix(8)):\(bookID):\(pageIndex)"
    }
}

/// 只读压缩图片 header 获取像素尺寸，不触发整页 bitmap 解码。
/// Komga 预取拿到 Data 后立即登记几何，LazyVStack 在页面真正出现前就能预留正确高度。
nonisolated enum RemotePageGeometry {
    static func pixelSize(from data: Data) -> CGSize? {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              let properties = CGImageSourceCopyPropertiesAtIndex(
                source,
                0,
                [kCGImageSourceShouldCache: false] as CFDictionary
              ) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
              width > 0,
              height > 0 else {
            return nil
        }
        return CGSize(width: width, height: height)
    }
}

enum RemotePagePriority: Sendable {
    case current
    case prefetch
}

nonisolated private func remoteCacheLimits() -> (memoryLimitMB: Int, diskLimitMB: Int) {
    // 与解码位图缓存共用同一张分档表（`ReaderMemoryBudgetPlanner`）：两处各自维护分档
    // 曾经让同一台机器上的两条缓存差一个数量级（≥6GB 档只有 180MB）。
    let budget = ReaderMemoryBudgetPlanner.budget()
    return (budget.remotePageDataCacheMB, budget.remotePageDataDiskMB)
}

nonisolated private func remotePrefetchBudgetBytes() -> Int64 {
    Int64(ReaderMemoryBudgetPlanner.budget().remotePrefetchMB) * 1024 * 1024
}

nonisolated private func pruneRemotePageDiskCache(limitBytes: Int64) {
    let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MReaderRemotePageCache", isDirectory: true)
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else { return }

    var entries: [(url: URL, size: Int64, date: Date)] = []
    for case let url as URL in enumerator {
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isRegularFile == true else { continue }
        entries.append((
            url,
            Int64(values.fileSize ?? 0),
            values.contentModificationDate ?? .distantPast
        ))
    }

    var total = entries.reduce(Int64(0)) { $0 + $1.size }
    guard total > limitBytes else {
        MReaderLog.reader.debug("remote cache disk size=\(total, privacy: .public)")
        return
    }
    for entry in entries.sorted(by: { $0.date < $1.date }) {
        try? FileManager.default.removeItem(at: entry.url)
        total -= entry.size
        if total <= limitBytes { break }
    }
    MReaderLog.reader.notice("remote cache pruned disk size=\(total, privacy: .public)")
}

actor RemotePageCache {
    static let shared = RemotePageCache()

    private let memoryCache = NSCache<NSString, NSData>()
    private var cachedKeys: Set<String> = []
    private let memoryLimitMB: Int
    private var activeDownloads: [PageCacheKey: Task<Data?, Never>] = [:]
    private var geometryRegisteredKeys: Set<PageCacheKey> = []

    private init() {
        let limits = remoteCacheLimits()
        memoryLimitMB = limits.memoryLimitMB
        memoryCache.countLimit = 0
        memoryCache.totalCostLimit = limits.memoryLimitMB * 1024 * 1024
        registerMemoryWarningObserver()
    }

    private nonisolated func registerMemoryWarningObserver() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.reduceMemoryPressure() }
        }
    }

    /// NSCache 自身的回收时机不可控，收到系统内存警告时主动清空压缩页缓存，
    /// 把内存让给正在显示的页面。磁盘缓存不受影响，重新翻回时不会重新走网络。
    ///
    /// 必须复用 `clearMemoryCache()`：它同时清掉 `cachedKeys`，否则这个集合会
    /// 继续认为一堆已不在 NSCache 里的 key 仍处于缓存管理之下，多次内存警告后
    /// 会持续积累 stale keys。
    func reduceMemoryPressure() {
        clearMemoryCache()
        MReaderLog.reader.notice(
            "remote cache cleared by memory warning memoryLimitMB=\(self.memoryLimitMB, privacy: .public)"
        )
    }

    func data(for key: PageCacheKey, priority: RemotePagePriority) async -> Data? {
        let cacheKey = memoryKey(for: key)
        if let cached = memoryCache.object(forKey: cacheKey as NSString) {
            let data = cached as Data
            await registerGeometryIfNeeded(data, for: key)
            MReaderLog.reader.debug(
                "remote cache memory hit page=\(key.pageIndex, privacy: .public) key=\(key.logDescription, privacy: .public) memoryLimitMB=\(self.memoryLimitMB, privacy: .public)"
            )
            return data
        }

        let diskURL = RemotePageLoader.pageCacheURL(sourceID: key.sourceID, bookID: key.bookID, pageIndex: key.pageIndex)
        let legacyDiskURL = RemotePageLoader.legacyPageCacheURL(sourceID: key.sourceID, bookID: key.bookID, pageIndex: key.pageIndex)
        if let diskHit = await Self.readDiskCache(
            candidates: [diskURL, legacyDiskURL],
            priority: priority
        ) {
            let data = diskHit.data
            memoryCache.setObject(data as NSData, forKey: cacheKey as NSString, cost: data.count)
            cachedKeys.insert(cacheKey)
            await registerGeometryIfNeeded(data, for: key)
            MReaderLog.reader.debug(
                "remote cache disk hit page=\(key.pageIndex, privacy: .public) bytes=\(data.count, privacy: .public) key=\(key.logDescription, privacy: .public)"
            )
            return data
        }

        if let task = activeDownloads[key] {
            MReaderLog.reader.debug(
                "remote cache joined request page=\(key.pageIndex, privacy: .public) priority=\(String(describing: priority), privacy: .public)"
            )
            return await task.value
        }

        let taskPriority: TaskPriority
        switch priority {
        case .current:
            taskPriority = .userInitiated
        case .prefetch:
            taskPriority = .utility
        }
        let task = Task(priority: taskPriority) { [diskURL] in
            await Self.download(key: key, diskURL: diskURL)
        }
        activeDownloads[key] = task
        let data = await task.value
        activeDownloads[key] = nil
        if let data {
            memoryCache.setObject(data as NSData, forKey: cacheKey as NSString, cost: data.count)
            cachedKeys.insert(cacheKey)
            await registerGeometryIfNeeded(data, for: key)
            MReaderLog.reader.debug(
                "remote cache stored page=\(key.pageIndex, privacy: .public) bytes=\(data.count, privacy: .public) key=\(key.logDescription, privacy: .public)"
            )
        }
        return data
    }

    private func registerGeometryIfNeeded(_ data: Data, for key: PageCacheKey) async {
        guard !geometryRegisteredKeys.contains(key) else { return }
        let size = await Task.detached(priority: .utility) {
            RemotePageGeometry.pixelSize(from: data)
        }.value
        guard let size else { return }
        geometryRegisteredKeys.insert(key)
        let url = RemotePageLoader.pageURL(
            sourceID: key.sourceID,
            bookID: key.bookID,
            pageIndex: key.pageIndex
        )
        await MainActor.run {
            PageGeometryStore.shared.setSize(size, for: url)
        }
    }

    nonisolated private static func readDiskCache(
        candidates: [URL],
        priority: RemotePagePriority
    ) async -> (data: Data, url: URL)? {
        let taskPriority: TaskPriority = priority == .current ? .userInitiated : .utility
        return await Task.detached(priority: taskPriority) {
            for candidate in candidates {
                guard !Task.isCancelled else { return nil }
                if let data = try? Data(contentsOf: candidate, options: [.mappedIfSafe]),
                   !data.isEmpty {
                    try? FileManager.default.setAttributes(
                        [.modificationDate: Date()],
                        ofItemAtPath: candidate.path
                    )
                    return (data, candidate)
                }
            }
            return nil
        }.value
    }

    func clearMemoryCache() {
        memoryCache.removeAllObjects()
        cachedKeys.removeAll()
        MReaderLog.reader.debug("remote cache memory cleared")
    }

    func retainMemoryPages(_ keysToKeep: Set<PageCacheKey>) {
        let memoryKeysToKeep = Set(keysToKeep.map(memoryKey(for:)))
        let keysToRemove = cachedKeys.subtracting(memoryKeysToKeep)
        var evictedCount = 0
        for key in keysToRemove {
            memoryCache.removeObject(forKey: key as NSString)
            cachedKeys.remove(key)
            evictedCount += 1
        }
        if evictedCount > 0 {
            MReaderLog.reader.debug(
                "remote cache evicted old pages count=\(evictedCount, privacy: .public)"
            )
        }
    }

    func storeForDiagnostics(_ data: Data, for key: PageCacheKey) {
        let cacheKey = memoryKey(for: key)
        memoryCache.setObject(data as NSData, forKey: cacheKey as NSString, cost: data.count)
        cachedKeys.insert(cacheKey)
    }

    func containsInMemoryForDiagnostics(_ key: PageCacheKey) -> Bool {
        memoryCache.object(forKey: memoryKey(for: key) as NSString) != nil
    }

    func cancelDownloadsOutside(_ keys: Set<PageCacheKey>) {
        let cancelling = activeDownloads.keys.filter { !keys.contains($0) }
        for key in cancelling {
            activeDownloads[key]?.cancel()
            activeDownloads[key] = nil
        }
        if !cancelling.isEmpty {
            MReaderLog.reader.debug(
                "remote cache cancelled downloads pages=\(String(describing: cancelling.map { $0.pageIndex }.sorted()), privacy: .public)"
            )
        }
    }

    private func memoryKey(for key: PageCacheKey) -> String {
        "\(key.sourceID.uuidString)#\(key.bookID)#\(key.pageIndex)"
    }

    nonisolated private static func download(key: PageCacheKey, diskURL: URL) async -> Data? {
        if Task.isCancelled { return nil }
        do {
            guard let source = await KomgaProvider.loadSources().first(where: { $0.id == key.sourceID && $0.type == .komga && $0.isEnabled }),
                  let apiKey = KomgaProvider.apiKey(for: key.sourceID) else {
                return nil
            }
            MReaderLog.aiTransport.debug(
                "remote cache network request page=\(key.pageIndex, privacy: .public) key=\(key.logDescription, privacy: .public)"
            )
            let resolvedURL = await KomgaProvider.resolveBestURL(source: source)
            let client = try KomgaAPIClient(baseURLString: resolvedURL, apiKey: apiKey)
            let data = try await client.pageData(bookID: key.bookID, pageIndex: key.pageIndex)
            if Task.isCancelled { return nil }
            try FileManager.default.createDirectory(at: diskURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: diskURL, options: .atomic)
            return data
        } catch MediaSourceError.notFound {
            MReaderLog.aiTransport.notice(
                "Komga page not found book=\(key.bookID, privacy: .public) page=\(key.pageIndex, privacy: .public)"
            )
            return nil
        } catch {
            await KomgaProvider.invalidateResolvedURL(for: key.sourceID)
            MReaderLog.reader.error("remote page load failed page=\(key.pageIndex, privacy: .public) reason=\(MReaderLog.describe(error), privacy: .public)")
            return nil
        }
    }
}

@MainActor
final class RemotePagePrefetcher {
    static let shared = RemotePagePrefetcher()

    private var tasks: [URL: Task<Void, Never>] = [:]
    private var previewTasks: [UUID: [URL: Task<Void, Never>]] = [:]
    private var previewComicIDs: [UUID] = []
    private var lastDiskPruneDate = Date.distantPast
    private var diskPruneTask: Task<Void, Never>?
    private let prefetchBudgetBytes: Int64 = remotePrefetchBudgetBytes()
    private let previewBudgetBytes: Int64 = 60 * 1024 * 1024
    private let unknownPageEstimateBytes: Int64 = 24 * 1024 * 1024

    private init() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.handleMemoryWarning()
            }
        }
    }

    /// Handles a system memory warning. Besides clearing the decoded-page memory
    /// cache, it cancels every in-flight preload/prefetch task (the current reader
    /// window in `tasks` plus all `previewTasks`) and empties those dictionaries, so
    /// a stale preload cannot repopulate the cache right after it was just cleared.
    private func handleMemoryWarning() {
        for task in tasks.values {
            task.cancel()
        }
        tasks.removeAll()
        cancelAllPreview()
        Task {
            await RemotePageCache.shared.clearMemoryCache()
        }
        MReaderLog.reader.notice("memory warning: cancelled in-flight preloads and cleared memory cache")
    }

    func previewPrefetch(comics: [ComicBook]) {
        cancelAllPreview()
        let remoteComics = comics.prefix(3).filter { $0.sourceType == .komga || $0.sourceType == .opds }
        previewComicIDs = remoteComics.map(\.id)
        for comic in remoteComics {
            prefetchPreviewPages(for: comic)
        }
        MReaderLog.reader.debug(
            "preview prefetch started comics=\(self.previewComicIDs.count, privacy: .public)"
        )
    }

    private func prefetchPreviewPages(for comic: ComicBook) {
        guard let sourceID = comic.mediaSourceID,
              let bookID = comic.komgaBookID ?? (comic.sourceType == .opds ? comic.remoteCoverID : nil) else { return }
        let currentPage = comic.currentPageIndex
        let indices = [currentPage - 1, currentPage, currentPage + 1, currentPage + 2, currentPage + 3].filter { $0 >= 0 && $0 < comic.totalPages }
        var estimatedBytes: Int64 = 0
        var comicTasks: [URL: Task<Void, Never>] = [:]
        for pageIndex in indices {
            let key = PageCacheKey(sourceID: sourceID, bookID: bookID, pageIndex: pageIndex)
            let cost = unknownPageEstimateBytes
            guard estimatedBytes + cost <= previewBudgetBytes / 3 else { break }
            estimatedBytes += cost
            let task = Task(priority: .utility) { [key] in
                _ = await RemotePageCache.shared.data(for: key, priority: .prefetch)
            }
            let pageURL = URL(string: "mreader-komga-page://\(sourceID.uuidString)/\(RemoteImageLoader.safeFileName(bookID))/\(pageIndex)")!
            comicTasks[pageURL] = task
        }
        previewTasks[comic.id] = comicTasks
    }

    func cancelPreviewForNonOpened(comicID: UUID) {
        for id in previewComicIDs where id != comicID {
            cancelPreview(comicID: id)
        }
        previewComicIDs = previewComicIDs.filter { $0 == comicID }
        MReaderLog.reader.debug(
            "preview prefetch cancelled non-opened keptComic=\(comicID.uuidString, privacy: .public)"
        )
    }

    func cancelAllPreview() {
        for (_, comicTasks) in previewTasks {
            for task in comicTasks.values {
                task.cancel()
            }
        }
        previewTasks.removeAll()
        previewComicIDs.removeAll()
    }

    private func cancelPreview(comicID: UUID) {
        guard let comicTasks = previewTasks[comicID] else { return }
        for task in comicTasks.values {
            task.cancel()
        }
        previewTasks.removeValue(forKey: comicID)
    }

    func updateWindow(currentPageIndex: Int, pages: [ComicPage], readingDirection: ReadingDirection, readingMode: ReadingMode, scrollDirection: Int = 1) {
        guard pages.indices.contains(currentPageIndex),
              RemotePageLoader.isRemotePageURL(pages[currentPageIndex].url) else {
            cancelAll()
            return
        }

        let candidateIndices = windowIndices(currentPageIndex: currentPageIndex, pageCount: pages.count, readingDirection: readingDirection, readingMode: readingMode, scrollDirection: scrollDirection)
        let budgetedIndices = budgetedWindowIndices(candidateIndices, currentPageIndex: currentPageIndex, pages: pages)
        let urls = budgetedIndices.map { pages[$0].url }
        let keepURLs = Set(urls)
        let keepKeys = Set(urls.compactMap { RemotePageLoader.RemotePageRequest(url: $0)?.cacheKey })
        let cancelled = tasks.keys.filter { !keepURLs.contains($0) }
        for url in cancelled {
            tasks[url]?.cancel()
            tasks[url] = nil
        }
        if !cancelled.isEmpty {
            let cancelledPages = cancelled.compactMap { RemotePageLoader.pageIndex(forRemotePageURL: $0) }.sorted()
            MReaderLog.reader.debug(
                "remote prefetch cancelled pages=\(String(describing: cancelledPages), privacy: .public)"
            )
        }

        Task {
            await RemotePageCache.shared.cancelDownloadsOutside(keepKeys)
            await RemotePageCache.shared.retainMemoryPages(keepKeys)
        }

        MReaderLog.reader.debug(
            "remote prefetch current=\(currentPageIndex, privacy: .public) candidatePages=\(String(describing: candidateIndices), privacy: .public) budgetedPages=\(String(describing: budgetedIndices), privacy: .public) budgetBytes=\(self.prefetchBudgetBytes, privacy: .public) mode=\(readingMode.rawValue, privacy: .public) direction=\(readingDirection.rawValue, privacy: .public)"
        )
        for url in urls where RemotePageLoader.pageIndex(forRemotePageURL: url) != currentPageIndex {
            guard tasks[url] == nil else { continue }
            tasks[url] = Task(priority: .utility) { [url] in
                await RemotePageLoader.prefetchImageData(forRemotePageURL: url)
                await MainActor.run {
                    self.tasks[url] = nil
                }
            }
        }
    }

    func cancelAll() {
        cancelAllPreview()
        let pages = tasks.keys.compactMap { RemotePageLoader.pageIndex(forRemotePageURL: $0) }.sorted()
        for task in tasks.values {
            task.cancel()
        }
        tasks.removeAll()
        if !pages.isEmpty {
            MReaderLog.reader.debug(
                "remote prefetch cancelAll pages=\(String(describing: pages), privacy: .public)"
            )
        }
        scheduleDiskPruneAfterReaderExit()
    }

    private func scheduleDiskPruneAfterReaderExit() {
        guard Date().timeIntervalSince(lastDiskPruneDate) > 60 else { return }
        lastDiskPruneDate = Date()
        diskPruneTask?.cancel()
        diskPruneTask = Task(priority: .background) { [weak self] in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await RemotePageLoader.pruneDiskCache()
            await MainActor.run {
                self?.diskPruneTask = nil
            }
        }
    }

    private func windowIndices(currentPageIndex: Int, pageCount: Int, readingDirection: ReadingDirection, readingMode: ReadingMode, scrollDirection: Int) -> [Int] {
        let isContinuous = readingMode == .continuousScroll || readingMode == .infiniteScroll
        return ReaderPrefetchPolicy.pageIndices(
            currentPageIndex: currentPageIndex,
            pageCount: pageCount,
            readingDirection: readingDirection,
            readingMode: readingMode,
            scrollDirection: scrollDirection,
            forwardCount: isContinuous ? 3 : 7,
            backwardCount: isContinuous ? 1 : 2,
            includesCurrentPage: true
        )
    }

    func prewarm(pages: [ComicPage], currentPageIndex: Int, readingDirection: ReadingDirection, readingMode: ReadingMode) {
        guard pages.indices.contains(currentPageIndex),
              RemotePageLoader.isRemotePageURL(pages[currentPageIndex].url) else { return }
        let candidateIndices = windowIndices(currentPageIndex: currentPageIndex, pageCount: pages.count, readingDirection: readingDirection, readingMode: readingMode, scrollDirection: 1)
        let urls = candidateIndices.prefix(5).map { pages[$0].url }
        for url in urls {
            guard tasks[url] == nil else { continue }
            tasks[url] = Task(priority: .userInitiated) { [url] in
                await RemotePageLoader.prefetchImageData(forRemotePageURL: url)
                await MainActor.run {
                    self.tasks[url] = nil
                }
            }
        }
    }

    private func budgetedWindowIndices(_ indices: [Int], currentPageIndex: Int, pages: [ComicPage]) -> [Int] {
        var selected: [Int] = []
        var estimatedBytes: Int64 = 0
        for index in indices {
            guard pages.indices.contains(index) else { continue }
            if index == currentPageIndex {
                selected.append(index)
                continue
            }
            let cost = estimatedRemotePageBytes(for: pages[index].url)
            let shouldSelect = estimatedBytes == 0 || estimatedBytes + cost <= prefetchBudgetBytes
            guard shouldSelect else { continue }
            estimatedBytes += cost
            selected.append(index)
        }
        return selected
    }

    private func estimatedRemotePageBytes(for url: URL) -> Int64 {
        guard let request = RemotePageLoader.RemotePageRequest(url: url) else {
            return unknownPageEstimateBytes
        }
        let cachedURL = RemotePageLoader.pageCacheURL(sourceID: request.sourceID, bookID: request.bookID, pageIndex: request.pageIndex)
        if let values = try? cachedURL.resourceValues(forKeys: [.fileSizeKey]),
           let fileSize = values.fileSize,
           fileSize > 0 {
            return Int64(fileSize)
        }
        return unknownPageEstimateBytes
    }
}
