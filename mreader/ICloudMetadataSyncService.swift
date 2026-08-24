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
    let metadataUpdatedAt: Date
    let readingDirectionRaw: String
    let readingModeRaw: String
    let pageTurnAnimationRaw: String
    let imageFitModeRaw: String
    let scrollSpeedRaw: String
    let bookmarks: [ComicBookmark]

    init(
        identity: String,
        currentPageIndex: Int = 0,
        furthestPageIndex: Int = 0,
        progressUpdatedAt: Date = .distantPast,
        lastReadAt: Date = .distantPast,
        hasBeenOpened: Bool = false,
        scrollProgress: Double = 0,
        scrollPageProgress: Double = 0,
        metadataUpdatedAt: Date = .distantPast,
        readingDirectionRaw: String = "leftToRight",
        readingModeRaw: String = "horizontalPage",
        pageTurnAnimationRaw: String = "slide",
        imageFitModeRaw: String = "fitScreen",
        scrollSpeedRaw: String = "standard",
        bookmarks: [ComicBookmark] = []
    ) {
        self.identity = identity
        self.currentPageIndex = currentPageIndex
        self.furthestPageIndex = furthestPageIndex
        self.progressUpdatedAt = progressUpdatedAt
        self.lastReadAt = lastReadAt
        self.hasBeenOpened = hasBeenOpened
        self.scrollProgress = scrollProgress
        self.scrollPageProgress = scrollPageProgress
        self.metadataUpdatedAt = metadataUpdatedAt
        self.readingDirectionRaw = readingDirectionRaw
        self.readingModeRaw = readingModeRaw
        self.pageTurnAnimationRaw = pageTurnAnimationRaw
        self.imageFitModeRaw = imageFitModeRaw
        self.scrollSpeedRaw = scrollSpeedRaw
        self.bookmarks = bookmarks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let progressDate = try container.decodeIfPresent(Date.self, forKey: .progressUpdatedAt) ?? .distantPast
        identity = try container.decode(String.self, forKey: .identity)
        currentPageIndex = try container.decodeIfPresent(Int.self, forKey: .currentPageIndex) ?? 0
        furthestPageIndex = max(currentPageIndex, try container.decodeIfPresent(Int.self, forKey: .furthestPageIndex) ?? currentPageIndex)
        progressUpdatedAt = progressDate
        lastReadAt = try container.decodeIfPresent(Date.self, forKey: .lastReadAt) ?? .distantPast
        hasBeenOpened = try container.decodeIfPresent(Bool.self, forKey: .hasBeenOpened) ?? (currentPageIndex > 0)
        scrollProgress = try container.decodeIfPresent(Double.self, forKey: .scrollProgress) ?? 0
        scrollPageProgress = try container.decodeIfPresent(Double.self, forKey: .scrollPageProgress) ?? 0
        metadataUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .metadataUpdatedAt) ?? progressDate
        readingDirectionRaw = try container.decodeIfPresent(String.self, forKey: .readingDirectionRaw) ?? "leftToRight"
        readingModeRaw = try container.decodeIfPresent(String.self, forKey: .readingModeRaw) ?? "horizontalPage"
        pageTurnAnimationRaw = try container.decodeIfPresent(String.self, forKey: .pageTurnAnimationRaw) ?? "slide"
        imageFitModeRaw = try container.decodeIfPresent(String.self, forKey: .imageFitModeRaw) ?? "fitScreen"
        scrollSpeedRaw = try container.decodeIfPresent(String.self, forKey: .scrollSpeedRaw) ?? "standard"
        bookmarks = try container.decodeIfPresent([ComicBookmark].self, forKey: .bookmarks) ?? []
    }

    func replacingIdentity(_ newIdentity: String, metadataUpdatedAt: Date? = nil) -> SyncedComicMetadata {
        SyncedComicMetadata(
            identity: newIdentity,
            currentPageIndex: currentPageIndex,
            furthestPageIndex: furthestPageIndex,
            progressUpdatedAt: progressUpdatedAt,
            lastReadAt: lastReadAt,
            hasBeenOpened: hasBeenOpened,
            scrollProgress: scrollProgress,
            scrollPageProgress: scrollPageProgress,
            metadataUpdatedAt: metadataUpdatedAt ?? self.metadataUpdatedAt,
            readingDirectionRaw: readingDirectionRaw,
            readingModeRaw: readingModeRaw,
            pageTurnAnimationRaw: pageTurnAnimationRaw,
            imageFitModeRaw: imageFitModeRaw,
            scrollSpeedRaw: scrollSpeedRaw,
            bookmarks: bookmarks
        )
    }
}

nonisolated enum ICloudActivityIdentity {
    static func key(deviceID: String, comicIdentity: String) -> String {
        "\(deviceID)#\(comicIdentity)"
    }

    static func comicIdentity(from key: String) -> String? {
        guard let separator = key.firstIndex(of: "#") else { return nil }
        return String(key[key.index(after: separator)...])
    }

    static func deviceID(from key: String) -> String? {
        guard let separator = key.firstIndex(of: "#") else { return nil }
        return String(key[..<separator])
    }
}

nonisolated struct ICloudReadingActivityDay: Codable, Sendable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case dateKey
        case seconds
        case pages
        case completedComicKeys
        case comicSeconds
        case comicPages
        case deviceSeconds
        case devicePages
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case completedComicIDs
    }

    var dateKey: String
    var seconds: Int
    var pages: Int
    var completedComicKeys: Set<String>
    var comicSeconds: [String: Int]
    var comicPages: [String: Int]
    var deviceSeconds: [String: Int]
    var devicePages: [String: Int]

    init(
        dateKey: String,
        seconds: Int = 0,
        pages: Int = 0,
        completedComicKeys: Set<String> = [],
        comicSeconds: [String: Int] = [:],
        comicPages: [String: Int] = [:],
        deviceSeconds: [String: Int] = [:],
        devicePages: [String: Int] = [:]
    ) {
        self.dateKey = dateKey
        self.seconds = seconds
        self.pages = pages
        self.completedComicKeys = completedComicKeys
        self.comicSeconds = comicSeconds
        self.comicPages = comicPages
        self.deviceSeconds = deviceSeconds
        self.devicePages = devicePages
    }

    init(local day: ReadingActivityDay, deviceID: String, comicIdentities: [UUID: String]) {
        var syncedComicSeconds = day.syncedComicSeconds
        var syncedComicPages = day.syncedComicPages
        var syncedCompleted = day.syncedCompletedComicKeys
        for (comicID, seconds) in day.localDeviceComicSeconds {
            let identity = comicIdentities[comicID] ?? "local-id:\(comicID.uuidString)"
            let key = ICloudActivityIdentity.key(deviceID: deviceID, comicIdentity: identity)
            syncedComicSeconds[key] = max(syncedComicSeconds[key] ?? 0, seconds)
        }
        for (comicID, pages) in day.localDeviceComicPages {
            let identity = comicIdentities[comicID] ?? "local-id:\(comicID.uuidString)"
            let key = ICloudActivityIdentity.key(deviceID: deviceID, comicIdentity: identity)
            syncedComicPages[key] = max(syncedComicPages[key] ?? 0, pages)
        }
        for (comicID, seconds) in day.comicSeconds {
            guard !Self.hasPerDeviceCounter(
                for: comicID,
                in: syncedComicSeconds,
                stableIdentity: comicIdentities[comicID]
            ) else { continue }
            let key = ICloudActivityIdentity.key(
                deviceID: ICloudSyncDeviceIdentity.legacyDeviceID,
                comicIdentity: "legacy-comic:\(comicID.uuidString)"
            )
            syncedComicSeconds[key] = max(syncedComicSeconds[key] ?? 0, seconds)
        }
        for (comicID, pages) in day.comicPages {
            guard !Self.hasPerDeviceCounter(
                for: comicID,
                in: syncedComicPages,
                stableIdentity: comicIdentities[comicID]
            ) else { continue }
            let key = ICloudActivityIdentity.key(
                deviceID: ICloudSyncDeviceIdentity.legacyDeviceID,
                comicIdentity: "legacy-comic:\(comicID.uuidString)"
            )
            syncedComicPages[key] = max(syncedComicPages[key] ?? 0, pages)
        }
        for comicID in day.completedComicIDs {
            guard let identity = comicIdentities[comicID] else { continue }
            syncedCompleted.insert(ICloudActivityIdentity.key(deviceID: deviceID, comicIdentity: identity))
        }

        var syncedDeviceSeconds = day.syncedDeviceSeconds
        var syncedDevicePages = day.syncedDevicePages
        if syncedDeviceSeconds.isEmpty, day.seconds > 0 {
            syncedDeviceSeconds[ICloudSyncDeviceIdentity.legacyDeviceID] = day.seconds
        }
        if syncedDevicePages.isEmpty, day.pages > 0 {
            syncedDevicePages[ICloudSyncDeviceIdentity.legacyDeviceID] = day.pages
        }
        self.init(
            dateKey: day.dateKey,
            seconds: syncedDeviceSeconds.values.reduce(0, +),
            pages: syncedDevicePages.values.reduce(0, +),
            completedComicKeys: syncedCompleted,
            comicSeconds: syncedComicSeconds,
            comicPages: syncedComicPages,
            deviceSeconds: syncedDeviceSeconds,
            devicePages: syncedDevicePages
        )
    }

    private static func hasPerDeviceCounter(
        for comicID: UUID,
        in counters: [String: Int],
        stableIdentity: String?
    ) -> Bool {
        let legacyIdentity = "legacy-comic:\(comicID.uuidString)"
        let localIdentity = "local-id:\(comicID.uuidString)"
        return counters.keys.contains { key in
            guard let identity = ICloudActivityIdentity.comicIdentity(from: key) else { return false }
            return identity == stableIdentity || identity == legacyIdentity || identity == localIdentity
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
        dateKey = try container.decode(String.self, forKey: .dateKey)
        seconds = try container.decodeIfPresent(Int.self, forKey: .seconds) ?? 0
        pages = try container.decodeIfPresent(Int.self, forKey: .pages) ?? 0

        let rawCompleted = try container.decodeIfPresent(Set<String>.self, forKey: .completedComicKeys)
            ?? (try legacyContainer.decodeIfPresent(Set<String>.self, forKey: .completedComicIDs))
            ?? []
        let rawSeconds = try container.decodeIfPresent([String: Int].self, forKey: .comicSeconds) ?? [:]
        let rawPages = try container.decodeIfPresent([String: Int].self, forKey: .comicPages) ?? [:]
        let legacyDeviceID = ICloudSyncDeviceIdentity.legacyDeviceID
        completedComicKeys = Set(rawCompleted.map { key in
            UUID(uuidString: key).map { ICloudActivityIdentity.key(deviceID: legacyDeviceID, comicIdentity: "legacy-comic:\($0.uuidString)") } ?? key
        })
        comicSeconds = Dictionary(uniqueKeysWithValues: rawSeconds.map { key, value in
            if let uuid = UUID(uuidString: key) {
                return (ICloudActivityIdentity.key(deviceID: legacyDeviceID, comicIdentity: "legacy-comic:\(uuid.uuidString)"), value)
            }
            return (key, value)
        })
        comicPages = Dictionary(uniqueKeysWithValues: rawPages.map { key, value in
            if let uuid = UUID(uuidString: key) {
                return (ICloudActivityIdentity.key(deviceID: legacyDeviceID, comicIdentity: "legacy-comic:\(uuid.uuidString)"), value)
            }
            return (key, value)
        })
        deviceSeconds = try container.decodeIfPresent([String: Int].self, forKey: .deviceSeconds)
            ?? [legacyDeviceID: seconds]
        devicePages = try container.decodeIfPresent([String: Int].self, forKey: .devicePages)
            ?? [legacyDeviceID: pages]
    }
}

nonisolated struct ICloudMetadataPayload: Codable, Sendable {
    let version: Int
    let updatedAt: Date
    let deviceID: String
    let comics: [SyncedComicMetadata]
    let activityDays: [ICloudReadingActivityDay]

    init(
        version: Int = 2,
        updatedAt: Date = Date(),
        deviceID: String,
        comics: [SyncedComicMetadata],
        activityDays: [ICloudReadingActivityDay]
    ) {
        self.version = version
        self.updatedAt = updatedAt
        self.deviceID = deviceID
        self.comics = comics
        self.activityDays = activityDays
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID) ?? "legacy-v1"
        comics = try container.decodeIfPresent([SyncedComicMetadata].self, forKey: .comics) ?? []
        activityDays = try container.decodeIfPresent([ICloudReadingActivityDay].self, forKey: .activityDays) ?? []
    }
}

nonisolated enum ICloudSyncDeviceIdentity {
    static let legacyDeviceID = "legacy-v1"
    private static let defaultsKey = "mreader.icloudSync.deviceID"

    static var current: String {
        if let existing = UserDefaults.standard.string(forKey: defaultsKey), !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString.lowercased()
        UserDefaults.standard.set(generated, forKey: defaultsKey)
        return generated
    }
}

nonisolated enum ComicSyncIdentity {
    static func value(for comic: ComicBook) -> String {
        if comic.sourceType == .local, let relative = normalizedRelativePath(comic.libraryRelativePath) {
            return "local:\(relative)"
        }
        return legacyV1Value(for: comic)
    }

    static func v2Value(for comic: ComicBook, sourcesByID: [UUID: MediaSource]) -> String? {
        switch comic.sourceType {
        case .local:
            guard let relative = normalizedRelativePath(comic.libraryRelativePath) else { return nil }
            return "local:\(relative)"
        case .komga:
            guard let sourceID = comic.mediaSourceID,
                  let bookID = comic.komgaBookID,
                  let source = sourcesByID[sourceID],
                  source.type == .komga else { return nil }
            return "komga:\(source.stableSyncSourceIdentity):book:\(bookID)"
        case .opds:
            guard let sourceID = comic.mediaSourceID,
                  let source = sourcesByID[sourceID],
                  source.type == .opds,
                  let publicationID = comic.remoteCoverID ?? comic.sourceURL ?? comic.chapterPath,
                  !publicationID.isEmpty else { return nil }
            return "opds:\(source.stableSyncSourceIdentity):publication:\(publicationID)"
        }
    }

    static func legacyV1Value(for comic: ComicBook) -> String {
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

    private static func normalizedRelativePath(_ value: String?) -> String? {
        guard let value else { return nil }
        let components = value
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty else { return nil }
        return components.joined(separator: "/")
    }
}

nonisolated enum ICloudMetadataMergePolicy {
    static func migrateLegacyV1(
        _ payload: ICloudMetadataPayload,
        comics: [ComicBook],
        sourcesByID: [UUID: MediaSource]
    ) -> ICloudMetadataPayload {
        guard payload.version < 2 else { return payload }
        var migrated: [SyncedComicMetadata] = []
        for item in payload.comics {
            let matches = comics.filter { ComicSyncIdentity.legacyV1Value(for: $0) == item.identity }
            guard matches.count == 1,
                  let identity = ComicSyncIdentity.v2Value(for: matches[0], sourcesByID: sourcesByID) else {
                continue
            }
            migrated.append(item.replacingIdentity(identity, metadataUpdatedAt: item.progressUpdatedAt))
        }
        return ICloudMetadataPayload(
            version: 2,
            updatedAt: payload.updatedAt,
            deviceID: payload.deviceID,
            comics: migrated,
            activityDays: payload.activityDays
        )
    }

    static func merge(local: ICloudMetadataPayload, remote: ICloudMetadataPayload?) -> ICloudMetadataPayload {
        var comics: [String: SyncedComicMetadata] = [:]
        for item in remote?.comics ?? [] where !item.identity.isEmpty {
            comics[item.identity] = item
        }
        for item in local.comics where !item.identity.isEmpty {
            if let existing = comics[item.identity] {
                comics[item.identity] = mergeComic(local: item, remote: existing)
            } else {
                comics[item.identity] = item
            }
        }

        var days: [String: ICloudReadingActivityDay] = [:]
        for day in remote?.activityDays ?? [] {
            days[day.dateKey] = day
        }
        for day in local.activityDays {
            if let existing = days[day.dateKey] {
                days[day.dateKey] = mergeActivity(local: day, remote: existing)
            } else {
                days[day.dateKey] = day
            }
        }
        return ICloudMetadataPayload(
            version: 2,
            updatedAt: Date(),
            deviceID: local.deviceID,
            comics: comics.values.sorted { $0.identity < $1.identity },
            activityDays: days.values.sorted { $0.dateKey < $1.dateKey }
        )
    }

    private static func mergeComic(local: SyncedComicMetadata, remote: SyncedComicMetadata) -> SyncedComicMetadata {
        let usesLocalProgress = local.progressUpdatedAt >= remote.progressUpdatedAt
        let usesLocalMetadata = local.metadataUpdatedAt >= remote.metadataUpdatedAt
        return SyncedComicMetadata(
            identity: local.identity,
            currentPageIndex: usesLocalProgress ? local.currentPageIndex : remote.currentPageIndex,
            furthestPageIndex: max(local.furthestPageIndex, remote.furthestPageIndex),
            progressUpdatedAt: max(local.progressUpdatedAt, remote.progressUpdatedAt),
            lastReadAt: max(local.lastReadAt, remote.lastReadAt),
            hasBeenOpened: local.hasBeenOpened || remote.hasBeenOpened,
            scrollProgress: usesLocalProgress ? local.scrollProgress : remote.scrollProgress,
            scrollPageProgress: usesLocalProgress ? local.scrollPageProgress : remote.scrollPageProgress,
            metadataUpdatedAt: max(local.metadataUpdatedAt, remote.metadataUpdatedAt),
            readingDirectionRaw: usesLocalMetadata ? local.readingDirectionRaw : remote.readingDirectionRaw,
            readingModeRaw: usesLocalMetadata ? local.readingModeRaw : remote.readingModeRaw,
            pageTurnAnimationRaw: usesLocalMetadata ? local.pageTurnAnimationRaw : remote.pageTurnAnimationRaw,
            imageFitModeRaw: usesLocalMetadata ? local.imageFitModeRaw : remote.imageFitModeRaw,
            scrollSpeedRaw: usesLocalMetadata ? local.scrollSpeedRaw : remote.scrollSpeedRaw,
            bookmarks: usesLocalMetadata ? local.bookmarks : remote.bookmarks
        )
    }

    private static func mergeActivity(local: ICloudReadingActivityDay, remote: ICloudReadingActivityDay) -> ICloudReadingActivityDay {
        var merged = remote
        merged.completedComicKeys.formUnion(local.completedComicKeys)
        for (key, value) in local.comicSeconds {
            merged.comicSeconds[key] = max(merged.comicSeconds[key] ?? 0, value)
        }
        for (key, value) in local.comicPages {
            merged.comicPages[key] = max(merged.comicPages[key] ?? 0, value)
        }
        for (key, value) in local.deviceSeconds {
            merged.deviceSeconds[key] = max(merged.deviceSeconds[key] ?? 0, value)
        }
        for (key, value) in local.devicePages {
            merged.devicePages[key] = max(merged.devicePages[key] ?? 0, value)
        }
        merged.seconds = merged.deviceSeconds.values.reduce(0, +)
        merged.pages = merged.devicePages.values.reduce(0, +)
        return merged
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

    private struct SyncSnapshot: Sendable {
        let comics: [ComicBook]
        let activityDays: [ReadingActivityDay]
    }

    private let sidecar = MetadataSidecarStore()
    private let deviceID = ICloudSyncDeviceIdentity.current
    private var monitorTask: Task<Void, Never>?
    private var pushTask: Task<Void, Never>?
    private var pendingSnapshot: SyncSnapshot?

    private init() {}

    deinit {
        monitorTask?.cancel()
        pushTask?.cancel()
    }

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
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else { return }
        pendingSnapshot = SyncSnapshot(comics: comics, activityDays: activityDays)
        guard pushTask == nil else { return }
        pushTask = Task { [weak self] in
            await self?.drainPushes()
        }
    }

    func pull() async -> ICloudMetadataPayload? {
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else { return nil }
        let payload = await sidecar.read()
        lastSyncAt = payload?.updatedAt
        usesICloudDrive = await sidecar.isUbiquitousRoot()
        return payload
    }

    private func drainPushes() async {
        while let snapshot = pendingSnapshot {
            pendingSnapshot = nil
            guard UserDefaults.standard.bool(forKey: Self.enabledKey) else { continue }
            isSyncing = true
            lastError = nil
            do {
                let sources = await KomgaProvider.loadSources()
                let sourcesByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
                let local = Self.payload(
                    comics: snapshot.comics,
                    activityDays: snapshot.activityDays,
                    deviceID: deviceID,
                    sourcesByID: sourcesByID
                )
                let rawRemote = await sidecar.read()
                let remote = rawRemote.map {
                    ICloudMetadataMergePolicy.migrateLegacyV1(
                        $0,
                        comics: snapshot.comics,
                        sourcesByID: sourcesByID
                    )
                }
                let merged = ICloudMetadataMergePolicy.merge(local: local, remote: remote)
                try await sidecar.write(merged)
                lastSyncAt = merged.updatedAt
                usesICloudDrive = await sidecar.isUbiquitousRoot()
            } catch {
                lastError = error.localizedDescription
            }
            isSyncing = false
        }
        pushTask = nil
    }

    private static func payload(
        comics: [ComicBook],
        activityDays: [ReadingActivityDay],
        deviceID: String,
        sourcesByID: [UUID: MediaSource]
    ) -> ICloudMetadataPayload {
        let metadata = comics.compactMap { comic -> SyncedComicMetadata? in
            guard let identity = ComicSyncIdentity.v2Value(for: comic, sourcesByID: sourcesByID) else {
                return nil
            }
            return SyncedComicMetadata(
                identity: identity,
                currentPageIndex: comic.currentPageIndex,
                furthestPageIndex: comic.furthestPageIndex,
                progressUpdatedAt: comic.progressUpdatedAt,
                lastReadAt: comic.lastReadAt,
                hasBeenOpened: comic.hasBeenOpened,
                scrollProgress: comic.scrollProgress,
                scrollPageProgress: comic.scrollPageProgress,
                metadataUpdatedAt: comic.metadataUpdatedAt,
                readingDirectionRaw: comic.readingDirectionRaw,
                readingModeRaw: comic.readingModeRaw,
                pageTurnAnimationRaw: comic.pageTurnAnimationRaw,
                imageFitModeRaw: comic.imageFitModeRaw,
                scrollSpeedRaw: comic.scrollSpeedRaw,
                bookmarks: Array(comic.bookmarks.suffix(50))
            )
        }
        let identitiesByID: [UUID: String] = Dictionary(uniqueKeysWithValues: comics.compactMap { comic in
            guard let identity = ComicSyncIdentity.v2Value(for: comic, sourcesByID: sourcesByID) else { return nil }
            return (comic.id, identity)
        })
        let activity = activityDays.map {
            ICloudReadingActivityDay(local: $0, deviceID: deviceID, comicIdentities: identitiesByID)
        }
        return ICloudMetadataPayload(
            version: 2,
            updatedAt: Date(),
            deviceID: deviceID,
            comics: metadata,
            activityDays: Array(activity.suffix(366))
        )
    }
}
