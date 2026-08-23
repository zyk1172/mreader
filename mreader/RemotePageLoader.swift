import Foundation
import CryptoKit
import ImageIO
import UIKit

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
            print("MReader migrated legacy cover cache to Application Support")
        } catch {
            print("MReader cover cache migration failed: \(error.localizedDescription)")
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
            print("Komga 源已禁用，拒绝打开远程漫画: \(comic.title)")
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
            print("MReader offline page hit page=\(request.pageIndex) key=\(request.cacheKey.logDescription)")
            return offline
        }
        return await RemotePageCache.shared.data(for: request.cacheKey, priority: .current)
    }

    static func prefetchImageData(forRemotePageURL url: URL) async {
        guard let request = RemotePageRequest(url: url) else { return }
        _ = await RemotePageCache.shared.data(for: request.cacheKey, priority: .prefetch)
    }

    static func pruneDiskCache() async {
        await RemotePageCache.shared.pruneDiskCacheIfNeeded()
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

    private static func pageURL(sourceID: UUID, bookID: String, pageIndex: Int) -> URL {
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

enum RemotePagePriority: Sendable {
    case current
    case prefetch
}

nonisolated private func remoteCacheLimits() -> (memoryLimitMB: Int, diskLimitMB: Int) {
    let ramGB = Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)
    if ramGB >= 6 {
        return (450, 2_048)
    } else if ramGB >= 4 {
        return (240, 1_024)
    } else {
        return (120, 512)
    }
}

nonisolated private func remotePrefetchBudgetBytes() -> Int64 {
    let ramGB = Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)
    if ramGB >= 6 {
        return 500 * 1024 * 1024
    } else if ramGB >= 4 {
        return 300 * 1024 * 1024
    } else {
        return 160 * 1024 * 1024
    }
}

actor RemotePageCache {
    static let shared = RemotePageCache()

    private let memoryCache = NSCache<NSString, NSData>()
    private var cachedKeys: Set<String> = []
    private let diskLimitBytes: Int64
    private let memoryLimitMB: Int
    private var activeDownloads: [PageCacheKey: Task<Data?, Never>] = [:]

    private init() {
        let limits = remoteCacheLimits()
        memoryLimitMB = limits.memoryLimitMB
        diskLimitBytes = Int64(limits.diskLimitMB) * 1024 * 1024
        memoryCache.countLimit = 0
        memoryCache.totalCostLimit = limits.memoryLimitMB * 1024 * 1024
    }

    func data(for key: PageCacheKey, priority: RemotePagePriority) async -> Data? {
        let cacheKey = memoryKey(for: key)
        if let cached = memoryCache.object(forKey: cacheKey as NSString) {
            print("MReader remote cache memory hit page=\(key.pageIndex) key=\(key.logDescription) memoryLimitMB=\(memoryLimitMB)")
            return cached as Data
        }

        let diskURL = RemotePageLoader.pageCacheURL(sourceID: key.sourceID, bookID: key.bookID, pageIndex: key.pageIndex)
        let legacyDiskURL = RemotePageLoader.legacyPageCacheURL(sourceID: key.sourceID, bookID: key.bookID, pageIndex: key.pageIndex)
        for candidate in [diskURL, legacyDiskURL] {
            if let data = try? Data(contentsOf: candidate), !data.isEmpty {
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: candidate.path)
                memoryCache.setObject(data as NSData, forKey: cacheKey as NSString, cost: data.count)
                cachedKeys.insert(cacheKey)
                print("MReader remote cache disk hit page=\(key.pageIndex) bytes=\(data.count) key=\(key.logDescription)")
                return data
            }
        }

        if let task = activeDownloads[key] {
            print("MReader remote cache join request page=\(key.pageIndex) priority=\(priority)")
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
            print("MReader remote cache stored page=\(key.pageIndex) bytes=\(data.count) key=\(key.logDescription)")
        }
        return data
    }

    func clearMemoryCache() {
        memoryCache.removeAllObjects()
        cachedKeys.removeAll()
        print("MReader remote cache memory cleared")
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
            print("MReader remote cache evicted \(evictedCount) old pages from memory")
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
            print("MReader remote cache cancelled downloads pages=\(cancelling.map { $0.pageIndex }.sorted())")
        }
    }

    func pruneDiskCacheIfNeeded() {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MReaderRemotePageCache", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var entries: [(url: URL, size: Int64, date: Date)] = []
        for sourceFolder in files {
            guard let pageFiles = try? FileManager.default.contentsOfDirectory(
                at: sourceFolder,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for bookFolder in pageFiles {
                guard let images = try? FileManager.default.contentsOfDirectory(
                    at: bookFolder,
                    includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for imageURL in images {
                    let values = try? imageURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                    let size = Int64(values?.fileSize ?? 0)
                    entries.append((imageURL, size, values?.contentModificationDate ?? .distantPast))
                }
            }
        }

        var total = entries.reduce(Int64(0)) { $0 + $1.size }
        guard total > diskLimitBytes else {
            print("MReader remote cache disk size=\(total)")
            return
        }
        for entry in entries.sorted(by: { $0.date < $1.date }) {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
            if total <= diskLimitBytes { break }
        }
        print("MReader remote cache pruned disk size=\(total)")
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
            print("MReader remote cache network request page=\(key.pageIndex) key=\(key.logDescription)")
            let resolvedURL = await KomgaProvider.resolveBestURL(source: source)
            let client = try KomgaAPIClient(baseURLString: resolvedURL, apiKey: apiKey)
            let data = try await client.pageData(bookID: key.bookID, pageIndex: key.pageIndex)
            if Task.isCancelled { return nil }
            try FileManager.default.createDirectory(at: diskURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: diskURL, options: .atomic)
            return data
        } catch MediaSourceError.notFound {
            print("Komga 页面不存在 book=\(key.bookID) page=\(key.pageIndex)")
            return nil
        } catch {
            await KomgaProvider.invalidateResolvedURL(for: key.sourceID)
            print("Komga 页面加载失败 page=\(key.pageIndex): \(error.localizedDescription)")
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
        print("MReader memory warning: cancelled in-flight preloads and cleared memory cache")
    }

    func previewPrefetch(comics: [ComicBook]) {
        cancelAllPreview()
        let remoteComics = comics.prefix(3).filter { $0.sourceType == .komga || $0.sourceType == .opds }
        previewComicIDs = remoteComics.map(\.id)
        for comic in remoteComics {
            prefetchPreviewPages(for: comic)
        }
        print("MReader preview prefetch started for \(previewComicIDs.count) comics")
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
        print("MReader preview prefetch cancelled non-opened, kept comicID=\(comicID)")
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
            print("MReader remote prefetch cancel pages=\(cancelledPages)")
        }

        Task {
            await RemotePageCache.shared.cancelDownloadsOutside(keepKeys)
            await RemotePageCache.shared.retainMemoryPages(keepKeys)
        }

        print("MReader remote prefetch current=\(currentPageIndex) candidatePages=\(candidateIndices) budgetedPages=\(budgetedIndices) budgetBytes=\(prefetchBudgetBytes) mode=\(readingMode.rawValue) direction=\(readingDirection.rawValue)")
        for url in urls where RemotePageLoader.pageIndex(forRemotePageURL: url) != currentPageIndex {
            guard tasks[url] == nil else { continue }
            tasks[url] = Task(priority: .utility) { [url] in
                await RemotePageLoader.prefetchImageData(forRemotePageURL: url)
                await MainActor.run {
                    self.tasks[url] = nil
                }
            }
        }
        if Date().timeIntervalSince(lastDiskPruneDate) > 60 {
            lastDiskPruneDate = Date()
            Task(priority: .background) {
                await RemotePageLoader.pruneDiskCache()
            }
        }
    }

    func cancelAll() {
        cancelAllPreview()
        guard !tasks.isEmpty else { return }
        let pages = tasks.keys.compactMap { RemotePageLoader.pageIndex(forRemotePageURL: $0) }.sorted()
        for task in tasks.values {
            task.cancel()
        }
        tasks.removeAll()
        print("MReader remote prefetch cancelAll pages=\(pages)")
    }

    private func windowIndices(currentPageIndex: Int, pageCount: Int, readingDirection: ReadingDirection, readingMode: ReadingMode, scrollDirection: Int) -> [Int] {
        let isContinuous = readingMode == .continuousScroll || readingMode == .infiniteScroll
        return ReaderPrefetchPolicy.pageIndices(
            currentPageIndex: currentPageIndex,
            pageCount: pageCount,
            readingDirection: readingDirection,
            readingMode: readingMode,
            scrollDirection: scrollDirection,
            forwardCount: isContinuous ? 10 : 7,
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
