import Foundation
import Security

nonisolated enum KomgaProvider {
    private static var sourcesURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("media_sources.json")
    }

    static func loadSources() -> [MediaSource] {
        do {
            let data = try Data(contentsOf: sourcesURL)
            return try JSONDecoder().decode([MediaSource].self, from: data)
        } catch {
            return []
        }
    }

    static func saveSources(_ sources: [MediaSource]) throws {
        let folderURL = sourcesURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(sources)
        try data.write(to: sourcesURL, options: .atomic)
    }

    static func addKomgaSource(name: String, baseURL: String, apiKey: String) async throws -> MediaSource {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmedName.isEmpty ? "Komga" : trimmedName
        let client = try KomgaAPIClient(baseURLString: baseURL, apiKey: apiKey)
        _ = try await client.testConnection()
        var sources = loadSources()
        var source = MediaSource(name: displayName, type: .komga, baseURL: client.baseURL.absoluteString, lastSyncAt: nil, isEnabled: true)
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
    }

    static func testConnection(baseURL: String, apiKey: String) async throws -> [KomgaLibraryDTO] {
        let client = try KomgaAPIClient(baseURLString: baseURL, apiKey: apiKey)
        return try await client.testConnection()
    }

    static func syncEnabledSources() async -> [(source: MediaSource, comics: [ComicBook], error: Error?)] {
        var results: [(MediaSource, [ComicBook], Error?)] = []
        for source in loadSources().filter({ $0.type == .komga && $0.isEnabled }) {
            do {
                let comics = try await syncSource(source)
                var updatedSource = source
                updatedSource.lastSyncAt = Date()
                try? updateSource(updatedSource)
                results.append((updatedSource, comics, nil))
            } catch {
                results.append((source, [], error))
            }
        }
        return results
    }

    static func syncSource(_ source: MediaSource) async throws -> [ComicBook] {
        guard source.type == .komga else { return [] }
        guard let apiKey = apiKey(for: source.id) else { throw MediaSourceError.apiKeyMissing }
        let client = try KomgaAPIClient(baseURLString: source.baseURL, apiKey: apiKey)
        let libraries = try await client.libraries()
        var comics: [ComicBook] = []
        var seenBookIDs = Set<String>()

        for library in libraries {
            let seriesList: [KomgaSeriesDTO]
            do {
                seriesList = try await client.series(libraryID: library.id)
            } catch {
                print("Komga 书库 \(library.name) 拉取 series 失败: \(error.localizedDescription)")
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
                        continue
                    }
                    guard pageCount > 0 else {
                        print("Komga book \(book.displayTitle) pageCount=0，已跳过")
                        continue
                    }
                    seenBookIDs.insert(book.id)
                    let coverPath = try? await cachedCoverPath(sourceID: source.id, bookID: book.id, client: client)
                    let title = mergedTitle(series: series, book: book)
                    comics.append(makeComic(source: source, libraryID: library.id, seriesID: series.id, book: book, title: title, pageCount: pageCount, coverPath: coverPath))
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
                        continue
                    }
                    guard pageCount > 0 else {
                        print("Komga book \(book.displayTitle) pageCount=0，已跳过")
                        continue
                    }
                    seenBookIDs.insert(book.id)
                    let coverPath = try? await cachedCoverPath(sourceID: source.id, bookID: book.id, client: client)
                    let title = directBookTitle(library: library, book: book)
                    comics.append(makeComic(source: source, libraryID: library.id, seriesID: book.seriesId, book: book, title: title, pageCount: pageCount, coverPath: coverPath))
                    libraryComicCount += 1
                }
            }
            print("Komga 同步书库 \(library.name): series=\(seriesList.count), books=\(libraryBookCount), comics=\(libraryComicCount)")
        }
        return comics
    }

    private static func resolvedPageCount(book: KomgaBookDTO, client: KomgaAPIClient) async throws -> Int {
        if let pageCount = book.pageCount, pageCount > 0 {
            return pageCount
        }
        return try await client.pages(bookID: book.id).count
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
