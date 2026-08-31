import Foundation

nonisolated struct ResolvedURLLookup: Sendable {
    let url: String
    let shouldRefresh: Bool
}

/// Serializes all mutable media-source state that can be touched by startup,
/// refresh, reader and settings tasks at the same time.
actor MediaSourceRepository {
    static let shared = MediaSourceRepository()

    private struct ResolvedURLEntry {
        let url: String
        let timestamp: Date
    }

    private var sourcesCache: [MediaSource]?
    private var hiddenComicsCache: [HiddenKomgaComic]?
    private var resolvedURLCache: [UUID: ResolvedURLEntry] = [:]
    private var resolvedURLGenerations: [UUID: Int] = [:]

    private let fileManager: FileManager
    private let userDefaults: UserDefaults
    private let sourcesURL: URL
    private let hiddenComicsURL: URL

    init(
        fileManager: FileManager = .default,
        directoryURL: URL? = nil,
        userDefaults: UserDefaults = .standard
    ) {
        self.fileManager = fileManager
        self.userDefaults = userDefaults
        let support = directoryURL ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        sourcesURL = support.appendingPathComponent("media_sources.json")
        hiddenComicsURL = support.appendingPathComponent("hidden_komga_comics.json")
    }

    func loadSources() -> [MediaSource] {
        if let sourcesCache {
            return sourcesCache
        }

        let loaded: [MediaSource]
        do {
            let data = try Data(contentsOf: sourcesURL)
            loaded = try JSONDecoder().decode([MediaSource].self, from: data)
        } catch {
            loaded = []
        }
        let sorted = Self.sortedSources(loaded)
        sourcesCache = sorted
        return sorted
    }

    func saveSources(_ sources: [MediaSource]) throws {
        let sorted = Self.sortedSources(sources)
        try persistSources(sorted)
    }

    /// Performs a read/modify/write under the same actor turn so concurrent settings,
    /// startup-sync and refresh tasks cannot overwrite one another with stale snapshots.
    func addSource(_ source: MediaSource, replacingType type: MediaSourceType, baseURL: String) throws {
        var sources = loadSources()
        sources.removeAll { $0.type == type && $0.baseURL == baseURL }
        sources.append(source)
        try persistSources(Self.sortedSources(sources))
    }

    func updateSource(_ source: MediaSource) throws {
        var sources = loadSources()
        if let index = sources.firstIndex(where: { $0.id == source.id }) {
            sources[index] = source
        } else {
            sources.append(source)
        }
        try persistSources(Self.sortedSources(sources))
    }

    func removeSource(id: UUID) throws {
        var sources = loadSources()
        sources.removeAll { $0.id == id }
        try persistSources(Self.sortedSources(sources))
    }

    func mergeSources(_ replacements: [MediaSource]) throws {
        var sources = loadSources()
        for replacement in replacements {
            sources.removeAll { existing in
                existing.id == replacement.id
                    || (existing.type == replacement.type && existing.baseURL == replacement.baseURL)
            }
            sources.append(replacement)
        }
        try persistSources(Self.sortedSources(sources))
    }

    func hiddenKomgaComics() -> [HiddenKomgaComic] {
        if let hiddenComicsCache {
            return hiddenComicsCache
        }

        let loaded: [HiddenKomgaComic]
        do {
            let data = try Data(contentsOf: hiddenComicsURL)
            loaded = try JSONDecoder().decode([HiddenKomgaComic].self, from: data)
        } catch {
            loaded = []
        }
        let sorted = Self.sortedHiddenComics(loaded)
        hiddenComicsCache = sorted
        return sorted
    }

    func saveHiddenKomgaComics(_ hidden: [HiddenKomgaComic]) {
        let sorted = Self.sortedHiddenComics(hidden)
        do {
            try persistHiddenComics(sorted)
        } catch {
            print("保存 Komga 隐藏列表失败: \(error.localizedDescription)")
        }
    }

    func upsertHiddenComic(_ record: HiddenKomgaComic) {
        var hidden = hiddenKomgaComics()
        if let index = hidden.firstIndex(where: { $0.key == record.key }) {
            hidden[index] = record
        } else {
            hidden.append(record)
        }
        saveHiddenKomgaComics(hidden)
    }

    func removeHiddenComic(key: String) {
        var hidden = hiddenKomgaComics()
        hidden.removeAll { $0.key == key }
        saveHiddenKomgaComics(hidden)
    }

    func hiddenComicKeys() -> Set<String> {
        Set(hiddenKomgaComics().map(\.key))
    }

    func resolvedURL(for sourceID: UUID, ttl: TimeInterval, now: Date = Date()) -> ResolvedURLLookup? {
        if let entry = resolvedURLCache[sourceID] {
            if now.timeIntervalSince(entry.timestamp) < ttl {
                return ResolvedURLLookup(url: entry.url, shouldRefresh: false)
            }
        }

        guard let persisted = userDefaults.string(forKey: Self.resolvedURLKey(for: sourceID)) else {
            return nil
        }
        resolvedURLCache[sourceID] = ResolvedURLEntry(url: persisted, timestamp: now)
        return ResolvedURLLookup(url: persisted, shouldRefresh: true)
    }

    func beginResolvedURLRefresh(for sourceID: UUID) -> Int {
        let nextGeneration = (resolvedURLGenerations[sourceID] ?? 0) &+ 1
        resolvedURLGenerations[sourceID] = nextGeneration
        return nextGeneration
    }

    func storeResolvedURL(
        _ url: String,
        for sourceID: UUID,
        refreshGeneration: Int? = nil,
        at date: Date = Date()
    ) {
        if let refreshGeneration,
           resolvedURLGenerations[sourceID] != refreshGeneration {
            return
        }
        resolvedURLCache[sourceID] = ResolvedURLEntry(url: url, timestamp: date)
        userDefaults.set(url, forKey: Self.resolvedURLKey(for: sourceID))
    }

    func invalidateResolvedURL(for sourceID: UUID) {
        _ = beginResolvedURLRefresh(for: sourceID)
        resolvedURLCache[sourceID] = nil
        userDefaults.removeObject(forKey: Self.resolvedURLKey(for: sourceID))
    }

    func forceRefreshAllURLs() {
        resolvedURLCache.removeAll()
        for source in loadSources() {
            _ = beginResolvedURLRefresh(for: source.id)
            userDefaults.removeObject(forKey: Self.resolvedURLKey(for: source.id))
        }
    }

    private func persistSources(_ sortedSources: [MediaSource]) throws {
        let folderURL = sourcesURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(sortedSources)
        try data.write(to: sourcesURL, options: .atomic)
        sourcesCache = sortedSources
    }

    private func persistHiddenComics(_ sortedHidden: [HiddenKomgaComic]) throws {
        try fileManager.createDirectory(
            at: hiddenComicsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(sortedHidden)
        try data.write(to: hiddenComicsURL, options: .atomic)
        hiddenComicsCache = sortedHidden
    }

    private static func resolvedURLKey(for sourceID: UUID) -> String {
        "resolvedURL_\(sourceID.uuidString)"
    }

    private static func sortedSources(_ sources: [MediaSource]) -> [MediaSource] {
        sources.sorted { lhs, rhs in
            let nameCompare = lhs.name.localizedStandardCompare(rhs.name)
            if nameCompare != .orderedSame {
                return nameCompare == .orderedAscending
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private static func sortedHiddenComics(_ hidden: [HiddenKomgaComic]) -> [HiddenKomgaComic] {
        hidden.sorted { lhs, rhs in
            let titleCompare = lhs.title.localizedStandardCompare(rhs.title)
            if titleCompare != .orderedSame {
                return titleCompare == .orderedAscending
            }
            return lhs.key < rhs.key
        }
    }
}
