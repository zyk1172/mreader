import Foundation

nonisolated struct CacheStorageSnapshot: Sendable {
    var remotePages: Int64
    var generatedAssets: Int64
    var offlineComics: Int64
    var temporaryFiles: Int64

    static let zero = CacheStorageSnapshot(remotePages: 0, generatedAssets: 0, offlineComics: 0, temporaryFiles: 0)

    var readerCacheTotal: Int64 {
        remotePages + generatedAssets + temporaryFiles
    }
}

nonisolated enum CacheStorageManager {
    private static let fileManager = FileManager.default

    static func snapshot() -> CacheStorageSnapshot {
        CacheStorageSnapshot(
            remotePages: size(of: cacheURL("MReaderRemotePageCache")),
            generatedAssets: generatedCacheURLs.reduce(0) { $0 + size(of: $1) },
            offlineComics: size(of: cacheURL("MReaderOfflineComics")),
            temporaryFiles: ComicManager.temporaryImportCacheSize()
        )
    }

    static func clearReaderCaches() {
        try? fileManager.removeItem(at: cacheURL("MReaderRemotePageCache"))
        for url in generatedCacheURLs {
            try? fileManager.removeItem(at: url)
        }
        ComicManager.clearTemporaryImportCache()
    }

    private static var generatedCacheURLs: [URL] {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return [
            cacheURL("AITranslationPages"),
            cacheURL("LocalOCR"),
            cacheURL("PanelLayouts"),
            cacheURL("ArchiveCompatibility"),
            cacheURL("MReaderOPDSCache"),
            support.appendingPathComponent("MReaderCoverCache", isDirectory: true),
            support.appendingPathComponent("MReaderRemoteCovers", isDirectory: true)
        ]
    }

    private static func cacheURL(_ component: String) -> URL {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(component, isDirectory: true)
    }

    private static func size(of url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}

extension Notification.Name {
    static let mreaderClearReaderMemoryCaches = Notification.Name("mreader.clearReaderMemoryCaches")
}
