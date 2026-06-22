import Foundation
import ImageIO
import UIKit

nonisolated enum RemoteImageLoader {
    private static var cacheRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MReaderRemoteImageCache", isDirectory: true)
    }

    static func cachedCoverPath(sourceID: UUID, bookID: String) -> String? {
        let url = coverURL(sourceID: sourceID, bookID: bookID)
        return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
    }

    static func cacheCoverData(_ data: Data, sourceID: UUID, bookID: String) -> String? {
        let url = coverURL(sourceID: sourceID, bookID: bookID)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url.path
        } catch {
            return nil
        }
    }

    static func removeCachedImages(sourceID: UUID) {
        let url = cacheRoot.appendingPathComponent(sourceID.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: url)
    }

    private static func coverURL(sourceID: UUID, bookID: String) -> URL {
        cacheRoot
            .appendingPathComponent(sourceID.uuidString, isDirectory: true)
            .appendingPathComponent("covers", isDirectory: true)
            .appendingPathComponent(safeFileName(bookID))
            .appendingPathExtension("img")
    }

    static func safeFileName(_ rawValue: String) -> String {
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
        return await RemotePageCache.shared.data(for: request.cacheKey, priority: .current)
    }

    static func prefetchImageData(forRemotePageURL url: URL) async {
        guard let request = RemotePageRequest(url: url) else { return }
        _ = await RemotePageCache.shared.data(for: request.cacheKey, priority: .prefetch)
    }

    static func pruneDiskCache() async {
        await RemotePageCache.shared.pruneDiskCacheIfNeeded()
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
        cacheRoot
            .appendingPathComponent(sourceID.uuidString, isDirectory: true)
            .appendingPathComponent(RemoteImageLoader.safeFileName(bookID), isDirectory: true)
            .appendingPathComponent("\(pageIndex)")
            .appendingPathExtension("img")
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

actor RemotePageCache {
    static let shared = RemotePageCache()

    private let memoryCache = NSCache<NSString, NSData>()
    private let diskLimitBytes: Int64 = 200 * 1024 * 1024
    private var activeDownloads: [PageCacheKey: Task<Data?, Never>] = [:]

    private init() {
        memoryCache.countLimit = 0
        memoryCache.totalCostLimit = 180 * 1024 * 1024
    }

    func data(for key: PageCacheKey, priority: RemotePagePriority) async -> Data? {
        let cacheKey = memoryKey(for: key)
        if let cached = memoryCache.object(forKey: cacheKey as NSString) {
            print("MReader remote cache memory hit page=\(key.pageIndex) key=\(key.logDescription) memoryLimitMB=180")
            return cached as Data
        }

        let diskURL = RemotePageLoader.pageCacheURL(sourceID: key.sourceID, bookID: key.bookID, pageIndex: key.pageIndex)
        if let data = try? Data(contentsOf: diskURL), !data.isEmpty {
            memoryCache.setObject(data as NSData, forKey: cacheKey as NSString, cost: data.count)
            print("MReader remote cache disk hit page=\(key.pageIndex) bytes=\(data.count) key=\(key.logDescription)")
            return data
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
            print("MReader remote cache stored page=\(key.pageIndex) bytes=\(data.count) key=\(key.logDescription)")
        }
        return data
    }

    func clearMemoryCache() {
        memoryCache.removeAllObjects()
        print("MReader remote cache memory cleared")
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
            guard let source = KomgaProvider.loadSources().first(where: { $0.id == key.sourceID && $0.type == .komga }),
                  let apiKey = KomgaProvider.apiKey(for: key.sourceID) else {
                return nil
            }
            print("MReader remote cache network request page=\(key.pageIndex) key=\(key.logDescription)")
            let client = try KomgaAPIClient(baseURLString: source.baseURL, apiKey: apiKey)
            let data = try await client.pageData(bookID: key.bookID, pageIndex: key.pageIndex)
            if Task.isCancelled { return nil }
            try FileManager.default.createDirectory(at: diskURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: diskURL, options: .atomic)
            return data
        } catch {
            print("Komga 页面加载失败 page=\(key.pageIndex): \(error.localizedDescription)")
            return nil
        }
    }
}

@MainActor
final class RemotePagePrefetcher {
    static let shared = RemotePagePrefetcher()

    private var tasks: [URL: Task<Void, Never>] = [:]
    private var lastDiskPruneDate = Date.distantPast
    private let prefetchBudgetBytes: Int64 = 120 * 1024 * 1024
    private let unknownPageEstimateBytes: Int64 = 24 * 1024 * 1024

    private init() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task {
                await RemotePageCache.shared.clearMemoryCache()
            }
        }
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
        guard !tasks.isEmpty else { return }
        let pages = tasks.keys.compactMap { RemotePageLoader.pageIndex(forRemotePageURL: $0) }.sorted()
        for task in tasks.values {
            task.cancel()
        }
        tasks.removeAll()
        print("MReader remote prefetch cancelAll pages=\(pages)")
    }

    private func windowIndices(currentPageIndex: Int, pageCount: Int, readingDirection: ReadingDirection, readingMode: ReadingMode, scrollDirection: Int) -> [Int] {
        let forwardStep: Int
        if readingMode == .continuousScroll || readingMode == .infiniteScroll {
            forwardStep = scrollDirection >= 0 ? 1 : -1
        } else {
            forwardStep = readingDirection == .rightToLeft ? -1 : 1
        }
        let backwardStep = -forwardStep
        let offsets = [0, backwardStep, backwardStep * 2, forwardStep, forwardStep * 2, forwardStep * 3, forwardStep * 4, forwardStep * 5]
        var seen = Set<Int>()
        return offsets.compactMap { offset in
            let index = currentPageIndex + offset
            guard index >= 0, index < pageCount, !seen.contains(index) else { return nil }
            seen.insert(index)
            return index
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
