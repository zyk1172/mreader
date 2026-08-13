import Combine
import Foundation

nonisolated struct SyncedComicMetadata: Codable, Sendable {
    let identity: String
    let currentPageIndex: Int
    let furthestPageIndex: Int
    let progressUpdatedAt: Date
    let lastReadAt: Date
    let hasBeenOpened: Bool
    let scrollProgress: Double
    let scrollPageProgress: Double
    let readingDirectionRaw: String
    let readingModeRaw: String
    let pageTurnAnimationRaw: String
    let imageFitModeRaw: String
    let scrollSpeedRaw: String
    let bookmarks: [ComicBookmark]
}

nonisolated struct ICloudMetadataPayload: Codable, Sendable {
    let version: Int
    let updatedAt: Date
    let comics: [SyncedComicMetadata]
    let activityDays: [ReadingActivityDay]
}

nonisolated enum ComicSyncIdentity {
    static func value(for comic: ComicBook) -> String {
        switch comic.sourceType {
        case .local:
            let path = comic.libraryPath ?? comic.chapterPath ?? comic.title
            let components = URL(fileURLWithPath: path).pathComponents
            if let libraryIndex = components.lastIndex(where: { $0.caseInsensitiveCompare("MReader") == .orderedSame }),
               libraryIndex + 1 < components.count {
                return "local:" + components[(libraryIndex + 1)...].joined(separator: "/")
            }
            return "local:" + components.suffix(3).joined(separator: "/")
        case .komga:
            return "komga:\(comic.mediaSourceID?.uuidString ?? ""):\(comic.komgaBookID ?? "")"
        case .opds:
            return "opds:\(comic.mediaSourceID?.uuidString ?? ""):\(comic.remoteCoverID ?? comic.sourceURL ?? "")"
        }
    }
}

private actor MetadataSidecarStore {
    private let fileName = ".mreader-metadata.json"

    func read() -> ICloudMetadataPayload? {
        guard let root = ComicManager.selectedLibraryRootURL() else { return nil }
        let token = SecurityScopedResource(url: root)
        defer { token.stop() }
        guard let data = try? Data(contentsOf: root.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode(ICloudMetadataPayload.self, from: data)
    }

    func write(_ payload: ICloudMetadataPayload) throws {
        guard let root = ComicManager.selectedLibraryRootURL() else { throw CocoaError(.fileNoSuchFile) }
        let token = SecurityScopedResource(url: root)
        defer { token.stop() }
        let data = try JSONEncoder().encode(payload)
        try data.write(to: root.appendingPathComponent(fileName), options: .atomic)
    }

    func isUbiquitousRoot() -> Bool {
        guard let root = ComicManager.selectedLibraryRootURL() else { return false }
        return FileManager.default.isUbiquitousItem(at: root)
    }
}

@MainActor
final class ICloudMetadataSyncService: ObservableObject {
    static let shared = ICloudMetadataSyncService()
    static let enabledKey = "mreader.icloudMetadataSyncEnabled"

    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var usesICloudDrive = false

    private let sidecar = MetadataSidecarStore()
    private var monitorTask: Task<Void, Never>?

    private init() {}

    deinit { monitorTask?.cancel() }

    func start(onExternalChange: @escaping @MainActor (ICloudMetadataPayload) -> Void) {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            guard let self else { return }
            usesICloudDrive = await sidecar.isUbiquitousRoot()
            while !Task.isCancelled {
                if UserDefaults.standard.bool(forKey: Self.enabledKey),
                   let payload = await sidecar.read(),
                   payload.updatedAt > (lastSyncAt ?? .distantPast) {
                    lastSyncAt = payload.updatedAt
                    onExternalChange(payload)
                }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func push(comics: [ComicBook], activityDays: [ReadingActivityDay]) {
        guard UserDefaults.standard.bool(forKey: Self.enabledKey), !isSyncing else { return }
        isSyncing = true
        lastError = nil
        let localPayload = Self.payload(comics: comics, activityDays: activityDays)
        Task {
            do {
                let remotePayload = await sidecar.read()
                let merged = Self.merge(local: localPayload, remote: remotePayload)
                try await sidecar.write(merged)
                lastSyncAt = merged.updatedAt
                usesICloudDrive = await sidecar.isUbiquitousRoot()
            } catch {
                lastError = error.localizedDescription
            }
            isSyncing = false
        }
    }

    func pull() async -> ICloudMetadataPayload? {
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else { return nil }
        let payload = await sidecar.read()
        lastSyncAt = payload?.updatedAt
        usesICloudDrive = await sidecar.isUbiquitousRoot()
        return payload
    }

    private static func payload(comics: [ComicBook], activityDays: [ReadingActivityDay]) -> ICloudMetadataPayload {
        let metadata = comics.prefix(2_000).map { comic in
            SyncedComicMetadata(
                identity: ComicSyncIdentity.value(for: comic),
                currentPageIndex: comic.currentPageIndex,
                furthestPageIndex: comic.furthestPageIndex,
                progressUpdatedAt: comic.progressUpdatedAt,
                lastReadAt: comic.lastReadAt,
                hasBeenOpened: comic.hasBeenOpened,
                scrollProgress: comic.scrollProgress,
                scrollPageProgress: comic.scrollPageProgress,
                readingDirectionRaw: comic.readingDirectionRaw,
                readingModeRaw: comic.readingModeRaw,
                pageTurnAnimationRaw: comic.pageTurnAnimationRaw,
                imageFitModeRaw: comic.imageFitModeRaw,
                scrollSpeedRaw: comic.scrollSpeedRaw,
                bookmarks: Array(comic.bookmarks.suffix(50))
            )
        }
        return ICloudMetadataPayload(version: 1, updatedAt: Date(), comics: metadata, activityDays: Array(activityDays.suffix(366)))
    }

    private static func merge(local: ICloudMetadataPayload, remote: ICloudMetadataPayload?) -> ICloudMetadataPayload {
        guard let remote else { return local }
        var comics = Dictionary(uniqueKeysWithValues: remote.comics.map { ($0.identity, $0) })
        for item in local.comics where item.progressUpdatedAt >= (comics[item.identity]?.progressUpdatedAt ?? .distantPast) {
            comics[item.identity] = item
        }
        var days = Dictionary(uniqueKeysWithValues: remote.activityDays.map { ($0.dateKey, $0) })
        for localDay in local.activityDays {
            guard var existing = days[localDay.dateKey] else {
                days[localDay.dateKey] = localDay
                continue
            }
            existing.seconds = max(existing.seconds, localDay.seconds)
            existing.pages = max(existing.pages, localDay.pages)
            existing.completedComicIDs.formUnion(localDay.completedComicIDs)
            for (id, value) in localDay.comicSeconds { existing.comicSeconds[id] = max(existing.comicSeconds[id] ?? 0, value) }
            for (id, value) in localDay.comicPages { existing.comicPages[id] = max(existing.comicPages[id] ?? 0, value) }
            days[localDay.dateKey] = existing
        }
        return ICloudMetadataPayload(
            version: 1,
            updatedAt: Date(),
            comics: comics.values.sorted { $0.identity < $1.identity },
            activityDays: days.values.sorted { $0.dateKey < $1.dateKey }
        )
    }
}
