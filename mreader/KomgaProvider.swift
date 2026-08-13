import Foundation
import Security

nonisolated struct HiddenKomgaComic: Codable, Identifiable, Hashable, Sendable {
    let key: String
    var mediaSourceID: UUID
    var komgaBookID: String
    var komgaSeriesID: String?
    var title: String
    var sourceName: String
    var hiddenAt: Date

    var id: String { key }
}

nonisolated struct KomgaSourceSyncResult: Sendable {
    let source: MediaSource
    let comics: [ComicBook]
    let isAuthoritative: Bool
    let error: Error?
}

nonisolated private struct KomgaSourceSyncPayload: Sendable {
    let comics: [ComicBook]
    let isAuthoritative: Bool
}

nonisolated enum KomgaProvider {
    private static let sourcesLock = NSLock()
    nonisolated(unsafe) private static var sourcesCache: [MediaSource]?
    private static let hiddenComicsLock = NSLock()
    nonisolated(unsafe) private static var hiddenComicsCache: [HiddenKomgaComic]?

    private static var sourcesURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("media_sources.json")
    }

    private static var hiddenComicsURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("hidden_komga_comics.json")
    }

    static func loadSources() -> [MediaSource] {
        sourcesLock.lock()
        if let sourcesCache {
            sourcesLock.unlock()
            return sourcesCache
        }
        sourcesLock.unlock()

        do {
            let data = try Data(contentsOf: sourcesURL)
            let sources = try JSONDecoder().decode([MediaSource].self, from: data)
                .sorted { lhs, rhs in
                    let nameCompare = lhs.name.localizedStandardCompare(rhs.name)
                    if nameCompare != .orderedSame {
                        return nameCompare == .orderedAscending
                    }
                    return lhs.id.uuidString < rhs.id.uuidString
                }
            sourcesLock.lock()
            sourcesCache = sources
            sourcesLock.unlock()
            return sources
        } catch {
            sourcesLock.lock()
            sourcesCache = []
            sourcesLock.unlock()
            return []
        }
    }

    static func saveSources(_ sources: [MediaSource]) throws {
        let sortedSources = sources.sorted { lhs, rhs in
            let nameCompare = lhs.name.localizedStandardCompare(rhs.name)
            if nameCompare != .orderedSame {
                return nameCompare == .orderedAscending
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        sourcesLock.lock()
        sourcesCache = sortedSources
        sourcesLock.unlock()

        let folderURL = sourcesURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(sortedSources)
        try data.write(to: sourcesURL, options: .atomic)
    }

    static func addKomgaSource(name: String, baseURL: String, apiKey: String, lanURL: String? = nil) async throws -> MediaSource {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmedName.isEmpty ? "Komga" : trimmedName
        let client = try KomgaAPIClient(baseURLString: baseURL, apiKey: apiKey)
        _ = try await client.testConnection()
        var sources = loadSources()
        var source = MediaSource(name: displayName, type: .komga, baseURL: client.baseURL.absoluteString, lanURL: lanURL, lastSyncAt: nil, isEnabled: true)
        source.lastSyncAt = Date()
        try saveAPIKey(apiKey, for: source.id)
        sources.removeAll { $0.type == .komga && $0.baseURL == source.baseURL }
        sources.append(source)
        try saveSources(sources)
        return source
    }

    static func updateSource(_ source: MediaSource) throws {
        var sources = loadSources()
        if let index = sources.firstIndex(where: { $0.id == source.id }) {
            sources[index] = source
        } else {
            sources.append(source)
        }
        try saveSources(sources)
    }

    static func removeSource(id: UUID) throws {
        var sources = loadSources()
        sources.removeAll { $0.id == id }
        try saveSources(sources)
        deleteAPIKey(for: id)
        RemoteImageLoader.removeCachedImages(sourceID: id)
        RemotePageLoader.removeCachedPages(sourceID: id)
    }

    static func hiddenKomgaComics() -> [HiddenKomgaComic] {
        hiddenComicsLock.lock()
        if let hiddenComicsCache {
            hiddenComicsLock.unlock()
            return hiddenComicsCache
        }
        hiddenComicsLock.unlock()

        do {
            let data = try Data(contentsOf: hiddenComicsURL)
            let hidden = try JSONDecoder().decode([HiddenKomgaComic].self, from: data)
                .sorted { lhs, rhs in
                    let titleCompare = lhs.title.localizedStandardCompare(rhs.title)
                    if titleCompare != .orderedSame {
                        return titleCompare == .orderedAscending
                    }
                    return lhs.key < rhs.key
                }
            hiddenComicsLock.lock()
            hiddenComicsCache = hidden
            hiddenComicsLock.unlock()
            return hidden
        } catch {
            hiddenComicsLock.lock()
            hiddenComicsCache = []
            hiddenComicsLock.unlock()
            return []
        }
    }

    static func hiddenKomgaComicKeys() -> Set<String> {
        Set(hiddenKomgaComics().map(\.key))
    }

    static func hideComic(_ comic: ComicBook, sourceName: String? = nil) {
        guard comic.sourceType == .komga,
              let sourceID = comic.mediaSourceID,
              let bookID = comic.komgaBookID else {
            return
        }
        var hidden = hiddenKomgaComics()
        let key = hiddenKey(mediaSourceID: sourceID, komgaBookID: bookID)
        let resolvedSourceName = sourceName ?? loadSources().first(where: { $0.id == sourceID })?.name ?? "Komga"
        let record = HiddenKomgaComic(
            key: key,
            mediaSourceID: sourceID,
            komgaBookID: bookID,
            komgaSeriesID: comic.komgaSeriesID,
            title: comic.title,
            sourceName: resolvedSourceName,
            hiddenAt: Date()
        )
        if let index = hidden.firstIndex(where: { $0.key == key }) {
            hidden[index] = record
        } else {
            hidden.append(record)
        }
        saveHiddenKomgaComics(hidden)
    }

    static func unhideComic(key: String) {
        var hidden = hiddenKomgaComics()
        hidden.removeAll { $0.key == key }
        saveHiddenKomgaComics(hidden)
    }

    static func isHidden(_ comic: ComicBook) -> Bool {
        guard let key = hiddenKey(for: comic) else { return false }
        return hiddenKomgaComics().contains { $0.key == key }
    }

    static func hiddenKey(for comic: ComicBook) -> String? {
        guard comic.sourceType == .komga,
              let sourceID = comic.mediaSourceID,
              let bookID = comic.komgaBookID else {
            return nil
        }
        return hiddenKey(mediaSourceID: sourceID, komgaBookID: bookID)
    }

    static func sourceName(for comic: ComicBook) -> String {
        guard let sourceID = comic.mediaSourceID else { return "Komga" }
        return loadSources().first(where: { $0.id == sourceID })?.name ?? "Komga"
    }

    private static func hiddenKey(mediaSourceID: UUID, komgaBookID: String) -> String {
        "\(mediaSourceID.uuidString):\(komgaBookID)"
    }

    private static func saveHiddenKomgaComics(_ hidden: [HiddenKomgaComic]) {
        let sortedHidden = hidden.sorted { lhs, rhs in
            let titleCompare = lhs.title.localizedStandardCompare(rhs.title)
            if titleCompare != .orderedSame {
                return titleCompare == .orderedAscending
            }
            return lhs.key < rhs.key
        }
        hiddenComicsLock.lock()
        hiddenComicsCache = sortedHidden
        hiddenComicsLock.unlock()

        do {
            try FileManager.default.createDirectory(at: hiddenComicsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(sortedHidden)
            try data.write(to: hiddenComicsURL, options: .atomic)
        } catch {
            print("保存 Komga 隐藏列表失败: \(error.localizedDescription)")
        }
    }

    static func testConnection(baseURL: String, apiKey: String) async throws -> [KomgaLibraryDTO] {
        let client = try KomgaAPIClient(baseURLString: baseURL, apiKey: apiKey)
        return try await client.testConnection()
    }

    private static var resolvedURLCache: [UUID: (url: String, timestamp: Date)] = [:]
    private static let resolvedURLCacheTTL: TimeInterval = 600

    static func resolveBestURL(source: MediaSource, timeout: TimeInterval = 4) async -> String {
        if let cached = resolvedURLCache[source.id],
           Date().timeIntervalSince(cached.timestamp) < resolvedURLCacheTTL {
            return cached.url
        }
        if let persisted = UserDefaults.standard.string(forKey: "resolvedURL_\(source.id.uuidString)") {
            resolvedURLCache[source.id] = (url: persisted, timestamp: Date())
            _ = Task { @MainActor in
                let resolved = await resolveBestURLUncached(source: source, timeout: timeout)
                resolvedURLCache[source.id] = (url: resolved, timestamp: Date())
                UserDefaults.standard.set(resolved, forKey: "resolvedURL_\(source.id.uuidString)")
            }
            return persisted
        }
        let resolved = await resolveBestURLUncached(source: source, timeout: timeout)
        resolvedURLCache[source.id] = (url: resolved, timestamp: Date())
        UserDefaults.standard.set(resolved, forKey: "resolvedURL_\(source.id.uuidString)")
        return resolved
    }

    static func invalidateResolvedURL(for sourceID: UUID) {
        resolvedURLCache[sourceID] = nil
        UserDefaults.standard.removeObject(forKey: "resolvedURL_\(sourceID.uuidString)")
    }

    static func forceRefreshAllURLs() {
        resolvedURLCache.removeAll()
        let sources = loadSources()
        for source in sources {
            UserDefaults.standard.removeObject(forKey: "resolvedURL_\(source.id.uuidString)")
        }
    }

    static func prewarmResolvedURLs() async {
        let sources = loadSources().filter { $0.isEnabled && ($0.type == .komga || $0.type == .opds) }
        await withTaskGroup(of: Void.self) { group in
            for source in sources {
                group.addTask {
                    let url = await resolveBestURL(source: source, timeout: 4)
                    let isLan = source.lanURL == url
                    print("MReader URL resolved source=\(source.name) url=\(url) isLAN=\(isLan)")
                }
            }
        }
    }

    private static func resolveBestURLUncached(source: MediaSource, timeout: TimeInterval) async -> String {
        guard let lanURLString = source.lanURL,
              let lanURL = URL(string: lanURLString),
              let wanURL = URL(string: source.baseURL) else {
            return source.baseURL
        }
        let lanReachable = await isReachable(lanURL, timeout: timeout)
        if lanReachable {
            return lanURLString
        }
        let wanReachable = await isReachable(wanURL, timeout: timeout)
        if wanReachable {
            return source.baseURL
        }
        return source.baseURL
    }

    static func resolvedBaseURL(for source: MediaSource) async -> String {
        await resolveBestURL(source: source)
    }

    private static func isReachable(_ url: URL, timeout: TimeInterval) async -> Bool {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }
            let reachable = (200..<500).contains(httpResponse.statusCode)
            return reachable
        } catch {
            return false
        }
    }

    static func remoteReadProgress(for comic: ComicBook) async throws -> Int? {
        try await remoteReadingProgressSnapshot(for: comic)?.pageIndex
    }

    static func remoteReadingProgressSnapshot(for comic: ComicBook) async throws -> RemoteReadingProgressSnapshot? {
        guard comic.sourceType == .komga,
              let sourceID = comic.mediaSourceID,
              let bookID = comic.komgaBookID,
              let source = loadSources().first(where: { $0.id == sourceID && $0.type == .komga && $0.isEnabled }) else {
            return nil
        }
        guard let apiKey = apiKey(for: source.id) else { throw MediaSourceError.apiKeyMissing }
        let resolvedURL = await resolveBestURL(source: source)
        let client = try KomgaAPIClient(baseURLString: resolvedURL, apiKey: apiKey)
        guard let progress = try await client.book(bookID: bookID).readProgress,
              let pageIndex = progress.resolvedPageIndex else {
            return nil
        }
        return RemoteReadingProgressSnapshot(pageIndex: pageIndex, updatedAt: progress.resolvedUpdatedAt)
    }

    static func updateReadProgress(for comic: ComicBook) async throws {
        guard comic.sourceType == .komga,
              let sourceID = comic.mediaSourceID,
              let bookID = comic.komgaBookID,
              let source = loadSources().first(where: { $0.id == sourceID && $0.type == .komga && $0.isEnabled }) else {
            return
        }
        guard let apiKey = apiKey(for: source.id) else { throw MediaSourceError.apiKeyMissing }
        let resolvedURL = await resolveBestURL(source: source)
        let client = try KomgaAPIClient(baseURLString: resolvedURL, apiKey: apiKey)
        try await client.updateReadProgress(
            bookID: bookID,
            pageIndex: ReadingProgressMergePolicy.serverPageIndex(for: comic),
            totalPages: comic.totalPages
        )
    }

    static func deleteBook(_ comic: ComicBook) async throws {
        guard comic.sourceType == .komga,
              let sourceID = comic.mediaSourceID,
              let bookID = comic.komgaBookID,
              let source = loadSources().first(where: { $0.id == sourceID && $0.type == .komga && $0.isEnabled }) else {
            throw MediaSourceError.notFound
        }
        guard let apiKey = apiKey(for: source.id) else { throw MediaSourceError.apiKeyMissing }
        let resolvedURL = await resolveBestURL(source: source)
        let client = try KomgaAPIClient(baseURLString: resolvedURL, apiKey: apiKey)
        try await client.deleteBook(bookID: bookID)
    }

    static func syncEnabledSources(sourceIDs: Set<UUID>? = nil) async -> [KomgaSourceSyncResult] {
        var results: [KomgaSourceSyncResult] = []
        var sources = loadSources().filter { $0.type == .komga && $0.isEnabled }
        if let sourceIDs {
            sources = sources.filter { sourceIDs.contains($0.id) }
        }
        for source in sources {
            do {
                let payload = try await syncSource(source)
                var updatedSource = source
                updatedSource.lastSyncAt = Date()
                try? updateSource(updatedSource)
                results.append(KomgaSourceSyncResult(
                    source: updatedSource,
                    comics: payload.comics,
                    isAuthoritative: payload.isAuthoritative,
                    error: nil
                ))
            } catch {
                results.append(KomgaSourceSyncResult(
                    source: source,
                    comics: [],
                    isAuthoritative: false,
                    error: error
                ))
            }
        }
        return results
    }

    private static func syncSource(_ source: MediaSource) async throws -> KomgaSourceSyncPayload {
        guard source.type == .komga else {
            return KomgaSourceSyncPayload(comics: [], isAuthoritative: true)
        }
        guard let apiKey = apiKey(for: source.id) else { throw MediaSourceError.apiKeyMissing }
        let resolvedURL = await resolveBestURL(source: source)
        let client = try KomgaAPIClient(baseURLString: resolvedURL, apiKey: apiKey)
        let libraries = try await client.libraries()
        var comics: [ComicBook] = []
        var seenBookIDs = Set<String>()
        var hadPartialFailure = false

        for library in libraries {
            let seriesList: [KomgaSeriesDTO]
            do {
                seriesList = try await client.series(libraryID: library.id)
            } catch {
                print("Komga 书库 \(library.name) 拉取 series 失败: \(error.localizedDescription)")
                hadPartialFailure = true
                continue
            }
            var libraryComicCount = 0
            var libraryBookCount = 0
            for series in seriesList {
                let books: [KomgaBookDTO]
                do {
                    books = try await client.books(seriesID: series.id)
                    print("Komga series \(series.displayTitle) books=\(books.count)")
                } catch {
                    print("Komga series \(series.displayTitle) 拉取 books 失败: \(error.localizedDescription)")
                    hadPartialFailure = true
                    continue
                }
                libraryBookCount += books.count
                for book in books {
                    guard !seenBookIDs.contains(book.id) else { continue }
                    let pageCount: Int
                    do {
                        pageCount = try await resolvedPageCount(book: book, client: client)
                    } catch {
                        print("Komga book \(book.displayTitle) pageCount 解析失败: \(error.localizedDescription)")
                        hadPartialFailure = true
                        continue
                    }
                    guard pageCount > 0 else {
                        print("Komga book \(book.displayTitle) pageCount=0，已跳过")
                        continue
                    }
                    seenBookIDs.insert(book.id)
                    let coverPath = try? await cachedCoverPath(sourceID: source.id, bookID: book.id, client: client)
                    let title = mergedTitle(series: series, book: book)
                    var comic = makeComic(source: source, libraryID: library.id, seriesID: series.id, book: book, title: title, pageCount: pageCount, coverPath: coverPath)
                    applyRemoteProgress(from: book, pageCount: pageCount, to: &comic)
                    comics.append(comic)
                    libraryComicCount += 1
                }
            }

            if libraryComicCount == 0 {
                let books: [KomgaBookDTO]
                do {
                    books = try await client.books(libraryID: library.id)
                    print("Komga 书库 \(library.name) fallback libraryBooks=\(books.count)")
                } catch {
                    print("Komga 书库 \(library.name) fallback books 失败: \(error.localizedDescription)")
                    print("Komga 同步书库 \(library.name): series=\(seriesList.count), books=\(libraryBookCount), comics=\(libraryComicCount)")
                    hadPartialFailure = true
                    continue
                }
                libraryBookCount += books.count
                for book in books {
                    guard !seenBookIDs.contains(book.id) else { continue }
                    let pageCount: Int
                    do {
                        pageCount = try await resolvedPageCount(book: book, client: client)
                    } catch {
                        print("Komga book \(book.displayTitle) pageCount 解析失败: \(error.localizedDescription)")
                        hadPartialFailure = true
                        continue
                    }
                    guard pageCount > 0 else {
                        print("Komga book \(book.displayTitle) pageCount=0，已跳过")
                        continue
                    }
                    seenBookIDs.insert(book.id)
                    let coverPath = try? await cachedCoverPath(sourceID: source.id, bookID: book.id, client: client)
                    let title = directBookTitle(library: library, book: book)
                    var comic = makeComic(source: source, libraryID: library.id, seriesID: book.seriesId, book: book, title: title, pageCount: pageCount, coverPath: coverPath)
                    applyRemoteProgress(from: book, pageCount: pageCount, to: &comic)
                    comics.append(comic)
                    libraryComicCount += 1
                }
            }
            print("Komga 同步书库 \(library.name): series=\(seriesList.count), books=\(libraryBookCount), comics=\(libraryComicCount)")
        }
        return KomgaSourceSyncPayload(comics: comics, isAuthoritative: !hadPartialFailure)
    }

    private static func resolvedPageCount(book: KomgaBookDTO, client: KomgaAPIClient) async throws -> Int {
        if let pageCount = book.pageCount, pageCount > 0 {
            return pageCount
        }
        return try await client.pages(bookID: book.id).count
    }

    private static func applyRemoteProgress(from book: KomgaBookDTO, pageCount: Int, to comic: inout ComicBook) {
        guard let progress = book.readProgress else { return }
        comic.currentPageIndex = remotePageIndex(book: book, pageCount: pageCount)
        comic.furthestPageIndex = comic.currentPageIndex
        comic.progressUpdatedAt = progress.resolvedUpdatedAt
        comic.lastReadAt = max(comic.lastReadAt, progress.resolvedUpdatedAt)
        comic.hasBeenOpened = true
    }

    private static func remotePageIndex(book: KomgaBookDTO, pageCount: Int) -> Int {
        guard let remotePage = book.readProgress?.resolvedPageIndex else { return 0 }
        return min(max(remotePage, 0), max(0, pageCount - 1))
    }

    private static func cachedCoverPath(sourceID: UUID, bookID: String, client: KomgaAPIClient) async throws -> String? {
        if let cached = RemoteImageLoader.cachedCoverPath(sourceID: sourceID, bookID: bookID) {
            return cached
        }
        let data = try await client.thumbnailData(bookID: bookID)
        return RemoteImageLoader.cacheCoverData(data, sourceID: sourceID, bookID: bookID)
    }

    private static func mergedTitle(series: KomgaSeriesDTO, book: KomgaBookDTO) -> String {
        let bookTitle = book.displayTitle
        let seriesTitle = series.displayTitle
        if bookTitle == book.id || bookTitle == seriesTitle {
            return seriesTitle
        }
        return "\(seriesTitle) - \(bookTitle)"
    }

    private static func directBookTitle(library: KomgaLibraryDTO, book: KomgaBookDTO) -> String {
        if let seriesTitle = book.seriesTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !seriesTitle.isEmpty {
            let bookTitle = book.displayTitle
            return bookTitle == book.id || bookTitle == seriesTitle ? seriesTitle : "\(seriesTitle) - \(bookTitle)"
        }
        let bookTitle = book.displayTitle
        return bookTitle == book.id ? library.name : bookTitle
    }

    private static func makeComic(source: MediaSource, libraryID: String, seriesID: String?, book: KomgaBookDTO, title: String, pageCount: Int, coverPath: String?) -> ComicBook {
        let stableKey = "komga:\(source.id.uuidString):\(book.id)"
        return ComicBook(
            id: stableUUID(for: stableKey),
            title: title,
            bookmarkData: Data(),
            totalPages: pageCount,
            coverImagePath: coverPath,
            fileSize: 0,
            libraryPath: nil,
            sourceTypeRaw: ComicSourceType.komga.rawValue,
            sourceURL: source.baseURL,
            mediaSourceID: source.id,
            komgaLibraryID: book.libraryId ?? libraryID,
            komgaSeriesID: book.seriesId ?? seriesID,
            komgaBookID: book.id,
            remoteCoverID: book.id,
            remoteCoverURL: nil,
            remotePageCount: pageCount
        )
    }

    private static func stableUUID(for key: String) -> UUID {
        var first = fnv1a64(key.utf8, seed: 0xcbf29ce484222325)
        var second = fnv1a64(String(key.reversed()).utf8, seed: 0x9e3779b185ebca87)
        var bytes: [UInt8] = []
        for _ in 0..<8 {
            bytes.append(UInt8(truncatingIfNeeded: first))
            first >>= 8
        }
        for _ in 0..<8 {
            bytes.append(UInt8(truncatingIfNeeded: second))
            second >>= 8
        }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5],
            bytes[6], bytes[7],
            bytes[8], bytes[9],
            bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func fnv1a64<S: Sequence>(_ bytes: S, seed: UInt64) -> UInt64 where S.Element == UInt8 {
        var hash = seed
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return hash
    }

    static func apiKey(for sourceID: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: sourceID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func saveAPIKey(_ apiKey: String, for sourceID: UUID) throws {
        let data = Data(apiKey.utf8)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: sourceID.uuidString
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, [
            kSecValueData as String: data
        ] as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            throw MediaSourceError.keychainFailed(String(updateStatus))
        }
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw MediaSourceError.keychainFailed(String(addStatus))
        }
    }

    private static func deleteAPIKey(for sourceID: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: sourceID.uuidString
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static var keychainService: String {
        "mreader.komga.api-key"
    }
}
