import Foundation

/// Application Support 中的离线译文仓库。它不使用 ReaderImageCache/AITranslationPageCoordinator 的缓存目录。
actor OfflineTranslationStorageManager {
    static let shared = OfflineTranslationStorageManager()

    let rootURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.rootURL = rootURL ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MReaderTranslations", isDirectory: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func prepareRoot() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    func index(for comicID: UUID) -> OfflineTranslationIndex? {
        guard let data = try? Data(contentsOf: indexURL(for: comicID)) else { return nil }
        return try? decoder.decode(OfflineTranslationIndex.self, from: data)
    }

    func ensureIndex(for comicID: UUID) throws -> OfflineTranslationIndex {
        if let existing = index(for: comicID) { return existing }
        let value = OfflineTranslationIndex(comicID: comicID)
        try write(value, to: indexURL(for: comicID))
        return value
    }

    func manifest(comicID: UUID, setID: UUID) -> OfflineTranslationSetManifest? {
        guard let data = try? Data(contentsOf: manifestURL(comicID: comicID, setID: setID)) else { return nil }
        return try? decoder.decode(OfflineTranslationSetManifest.self, from: data)
    }

    func activeManifest(for comicID: UUID) -> OfflineTranslationSetManifest? {
        guard let activeID = index(for: comicID)?.activeSetID else { return nil }
        return manifest(comicID: comicID, setID: activeID)
    }

    func saveManifest(_ manifest: OfflineTranslationSetManifest, activate: Bool = false) throws {
        guard manifest.totalPages >= 0 else { throw OfflineTranslationStorageError.invalidSet }
        try write(manifest, to: manifestURL(comicID: manifest.comicID, setID: manifest.id))
        var indexValue = index(for: manifest.comicID) ?? OfflineTranslationIndex(comicID: manifest.comicID)
        if !indexValue.setIDs.contains(manifest.id) {
            indexValue.setIDs.append(manifest.id)
        }
        if activate { indexValue.activeSetID = manifest.id }
        try write(indexValue, to: indexURL(for: manifest.comicID))
    }

    func setActive(comicID: UUID, setID: UUID) throws {
        guard manifest(comicID: comicID, setID: setID) != nil else {
            throw OfflineTranslationStorageError.invalidSet
        }
        var indexValue = index(for: comicID) ?? OfflineTranslationIndex(comicID: comicID)
        guard indexValue.setIDs.contains(setID) else { throw OfflineTranslationStorageError.invalidSet }
        indexValue.activeSetID = setID
        try write(indexValue, to: indexURL(for: comicID))
    }

    func page(comicID: UUID, setID: UUID, pageIndex: Int) -> OfflineTranslatedPage? {
        guard pageIndex >= 0,
              let data = try? Data(contentsOf: pageURL(comicID: comicID, setID: setID, pageIndex: pageIndex)) else {
            return nil
        }
        return try? decoder.decode(OfflineTranslatedPage.self, from: data)
    }

    func pageStates(comicID: UUID, setID: UUID) -> [Int: OfflineTranslationPageState] {
        guard let manifest = manifest(comicID: comicID, setID: setID) else { return [:] }
        var result: [Int: OfflineTranslationPageState] = [:]
        for pageIndex in 0..<manifest.totalPages {
            if let page = page(comicID: comicID, setID: setID, pageIndex: pageIndex) {
                result[pageIndex] = page.state
            }
        }
        return result
    }

    /// 页面文件先原子落盘，再刷新 manifest。调用方随后再写 job checkpoint。
    func savePageAndUpdateManifest(_ page: OfflineTranslatedPage) throws {
        guard page.pageIndex >= 0 else { throw OfflineTranslationStorageError.invalidPage }
        guard var manifest = manifest(comicID: page.comicID, setID: page.setID),
              page.pageIndex < manifest.totalPages else {
            throw OfflineTranslationStorageError.invalidSet
        }
        try write(page, to: pageURL(comicID: page.comicID, setID: page.setID, pageIndex: page.pageIndex))
        manifest = recalculatedManifest(manifest)
        try write(manifest, to: manifestURL(comicID: page.comicID, setID: page.setID))
    }

    func markPageStale(comicID: UUID, setID: UUID, pageIndex: Int) {
        guard var page = page(comicID: comicID, setID: setID, pageIndex: pageIndex) else { return }
        page.state = .stale
        page.errorMessage = "原图指纹已变化"
        try? savePageAndUpdateManifest(page)
    }

    func saveJob(_ job: OfflineTranslationJobRecord) throws {
        try write(job, to: jobURL(comicID: job.comicID, jobID: job.id))
    }

    func job(comicID: UUID, jobID: UUID) -> OfflineTranslationJobRecord? {
        guard let data = try? Data(contentsOf: jobURL(comicID: comicID, jobID: jobID)) else { return nil }
        return try? decoder.decode(OfflineTranslationJobRecord.self, from: data)
    }

    func jobs(comicID: UUID) -> [OfflineTranslationJobRecord] {
        let directory = comicDirectory(comicID: comicID).appendingPathComponent("jobs", isDirectory: true)
        guard let urls = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return urls.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(OfflineTranslationJobRecord.self, from: data)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func markRunningJobsInterrupted() throws -> Int {
        var count = 0
        guard let comicDirectories = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        for comicDirectory in comicDirectories {
            guard let comicID = UUID(uuidString: comicDirectory.lastPathComponent) else { continue }
            for var job in jobs(comicID: comicID) where job.state == .running || job.state == .queued {
                job.state = .interrupted
                job.lastError = "应用在任务运行期间退出"
                job.updatedAt = Date()
                try write(job, to: jobURL(comicID: comicID, jobID: job.id))
                count += 1
            }
        }
        return count
    }

    func deleteJob(comicID: UUID, jobID: UUID) throws {
        try fileManager.removeItem(at: jobURL(comicID: comicID, jobID: jobID))
    }

    func copyValidPages(
        from sourceSetID: UUID,
        to targetManifest: OfflineTranslationSetManifest,
        excludingPageIndexes: Set<Int> = []
    ) throws -> Int {
        guard let sourceManifest = manifest(comicID: targetManifest.comicID, setID: sourceSetID) else { return 0 }
        try saveManifest(targetManifest)
        var copied = 0
        for pageIndex in 0..<min(sourceManifest.totalPages, targetManifest.totalPages) {
            guard !excludingPageIndexes.contains(pageIndex) else { continue }
            guard let page = page(comicID: targetManifest.comicID, setID: sourceSetID, pageIndex: pageIndex),
                  page.state.isUsableOverlay else { continue }
            let copiedPage = OfflineTranslatedPage(
                comicID: page.comicID,
                setID: targetManifest.id,
                pageIndex: page.pageIndex,
                sourceFingerprint: page.sourceFingerprint,
                pixelWidth: page.pixelWidth,
                pixelHeight: page.pixelHeight,
                blocks: page.blocks,
                state: page.state,
                savedAt: Date(),
                providerID: targetManifest.providerID,
                visionModel: targetManifest.visionModel,
                resolvedSourceLanguage: targetManifest.resolvedSourceLanguage ?? page.resolvedSourceLanguage,
                errorMessage: page.errorMessage
            )
            try savePageAndUpdateManifest(copiedPage)
            copied += 1
        }
        return copied
    }

    func summaries(for comicID: UUID) -> [OfflineTranslationSetSummary] {
        guard let indexValue = index(for: comicID) else { return [] }
        return indexValue.setIDs.compactMap { setID in
            guard let manifestValue = manifest(comicID: comicID, setID: setID) else { return nil }
            return OfflineTranslationSetSummary(
                manifest: manifestValue,
                isActive: indexValue.activeSetID == setID,
                jobs: jobs(comicID: comicID).filter { $0.setID == setID }
            )
        }.sorted { $0.manifest.updatedAt > $1.manifest.updatedAt }
    }

    func deleteSet(comicID: UUID, setID: UUID) throws {
        guard var indexValue = index(for: comicID) else { return }
        try? fileManager.removeItem(at: setDirectory(comicID: comicID, setID: setID))
        for job in jobs(comicID: comicID) where job.setID == setID {
            try? fileManager.removeItem(at: jobURL(comicID: comicID, jobID: job.id))
        }
        indexValue.setIDs.removeAll { $0 == setID }
        if indexValue.activeSetID == setID {
            indexValue.activeSetID = indexValue.setIDs.last
        }
        if indexValue.setIDs.isEmpty {
            try? fileManager.removeItem(at: comicDirectory(comicID: comicID))
        } else {
            try write(indexValue, to: indexURL(for: comicID))
        }
    }

    func deleteComicTranslations(comicID: UUID) throws {
        try? fileManager.removeItem(at: comicDirectory(comicID: comicID))
    }

    func sizeInBytes() -> Int64 {
        size(of: rootURL)
    }

    /// 离线任务每页至少要有可写余量；容量不足时由协调器暂停并保留已完成页面。
    func ensureSufficientDiskSpace(minimumBytes: Int64 = 50 * 1024 * 1024) throws {
        let probeURL = rootURL.deletingLastPathComponent()
        let values = try probeURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values.volumeAvailableCapacityForImportantUsage,
           available < minimumBytes {
            throw OfflineTranslationStorageError.lowDiskSpace
        }
    }

    func maintenance(validComicIDs: Set<UUID>) throws -> Int {
        guard let directories = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var removed = 0
        for directory in directories {
            guard let comicID = UUID(uuidString: directory.lastPathComponent), !validComicIDs.contains(comicID) else { continue }
            try? fileManager.removeItem(at: directory)
            removed += 1
        }
        return removed
    }

    private func recalculatedManifest(_ manifest: OfflineTranslationSetManifest) -> OfflineTranslationSetManifest {
        var updated = manifest
        var counts: [OfflineTranslationPageState: Int] = [:]
        var failures = manifest.failureMessages
        for pageIndex in 0..<manifest.totalPages {
            guard let page = page(comicID: manifest.comicID, setID: manifest.id, pageIndex: pageIndex) else { continue }
            counts[page.state, default: 0] += 1
            if let error = page.errorMessage, !error.isEmpty {
                failures[String(pageIndex)] = error
            } else if page.state != .failed && page.state != .stale {
                failures[String(pageIndex)] = nil
            }
        }
        updated.completedPageCount = counts[.completed, default: 0]
        updated.noTextPageCount = counts[.noText, default: 0]
        updated.partialPageCount = counts[.partial, default: 0]
        updated.failedPageCount = counts[.failed, default: 0]
        updated.stalePageCount = counts[.stale, default: 0]
        updated.coverage = manifest.totalPages == 0
            ? 0
            : Double(updated.coveredPageCount) / Double(manifest.totalPages)
        updated.failureMessages = failures
        updated.updatedAt = Date()
        return updated
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try encoder.encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            throw OfflineTranslationStorageError.writeFailed(error.localizedDescription)
        }
    }

    private func comicDirectory(comicID: UUID) -> URL {
        rootURL.appendingPathComponent(comicID.uuidString, isDirectory: true)
    }

    private func setDirectory(comicID: UUID, setID: UUID) -> URL {
        comicDirectory(comicID: comicID).appendingPathComponent("sets", isDirectory: true)
            .appendingPathComponent(setID.uuidString, isDirectory: true)
    }

    private func indexURL(for comicID: UUID) -> URL {
        comicDirectory(comicID: comicID).appendingPathComponent("index.json")
    }

    private func manifestURL(comicID: UUID, setID: UUID) -> URL {
        setDirectory(comicID: comicID, setID: setID).appendingPathComponent("manifest.json")
    }

    private func pageURL(comicID: UUID, setID: UUID, pageIndex: Int) -> URL {
        setDirectory(comicID: comicID, setID: setID).appendingPathComponent("pages", isDirectory: true)
            .appendingPathComponent(String(format: "%06d.json", pageIndex))
    }

    private func jobURL(comicID: UUID, jobID: UUID) -> URL {
        comicDirectory(comicID: comicID).appendingPathComponent("jobs", isDirectory: true)
            .appendingPathComponent("\(jobID.uuidString).json")
    }

    private func size(of url: URL) -> Int64 {
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

/// 对 Job Store 暴露独立接口，实际文件仍由同一个 actor 保证顺序写入。
actor OfflineTranslationJobStore {
    static let shared = OfflineTranslationJobStore(storage: .shared)

    private let storage: OfflineTranslationStorageManager

    init(storage: OfflineTranslationStorageManager) {
        self.storage = storage
    }

    func save(_ job: OfflineTranslationJobRecord) async throws {
        try await storage.saveJob(job)
    }

    func load(comicID: UUID, jobID: UUID) async -> OfflineTranslationJobRecord? {
        await storage.job(comicID: comicID, jobID: jobID)
    }

    func list(comicID: UUID) async -> [OfflineTranslationJobRecord] {
        await storage.jobs(comicID: comicID)
    }

    func markRunningJobsInterrupted() async throws -> Int {
        try await storage.markRunningJobsInterrupted()
    }
}
