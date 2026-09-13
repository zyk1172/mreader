import Foundation
import Combine
import os

nonisolated enum StartupRemoteSyncOutcome: Equatable {
    case noRemoteSources
    case success
    case partialFailure
    case failure

    static func resolve(expectedSourceCount: Int, failedSourceCount: Int) -> Self {
        let expected = max(expectedSourceCount, 0)
        let failed = min(max(failedSourceCount, 0), expected)
        guard expected > 0 else { return .noRemoteSources }
        guard failed == 0 else { return failed == expected ? .failure : .partialFailure }
        return .success
    }

    var hapticLevel: HapticLevel? {
        switch self {
        case .noRemoteSources:
            return nil
        case .success:
            return .success
        case .partialFailure:
            return .warning
        case .failure:
            return .error
        }
    }
}

nonisolated private enum ComicLibraryLoadIssue: Sendable {
    /// library.json 解码/读取失败，未能从轮换备份恢复，当前以空书架启动。
    case comicsCorrupted
    /// library.json 解码/读取失败，已从轮换备份恢复可用快照。
    case comicsRecoveredFromBackup
    /// series.json 解码/读取失败，未能从轮换备份恢复，当前以空系列启动。
    case seriesCorrupted
    /// series.json 解码/读取失败，已从轮换备份恢复可用快照。
    case seriesRecoveredFromBackup

    var userMessage: String {
        switch self {
        case .comicsCorrupted:
            return "书架数据（library.json）已损坏，损坏文件已备份；当前以空书架启动。"
        case .comicsRecoveredFromBackup:
            return "书架数据（library.json）已损坏，已从轮换备份恢复。"
        case .seriesCorrupted:
            return "系列数据（series.json）已损坏，损坏文件已备份；当前以空系列启动。"
        case .seriesRecoveredFromBackup:
            return "系列数据（series.json）已损坏，已从轮换备份恢复。"
        }
    }
}

nonisolated private struct ComicLibrarySnapshot: Sendable {
    let comics: [ComicBook]
    let series: [ComicSeries]
    let loadIssues: [ComicLibraryLoadIssue]
}

private actor ComicLibraryDiskStore {
    private var latestComicsRevision = 0

    func load(libraryURL: URL, seriesURL: URL) -> ComicLibrarySnapshot {
        var loadIssues: [ComicLibraryLoadIssue] = []

        let comics: [ComicBook]
        do {
            if let decoded = try decodeIfPresent([ComicBook].self, at: libraryURL) {
                comics = sortedComics(decoded)
            } else {
                // 文件不存在：正常首次启动，返回空书架。
                comics = []
            }
        } catch {
            // 解码/读取失败：备份损坏文件，尝试从轮换备份恢复，并标记错误供上层感知。
            backUpCorruptFile(at: libraryURL)
            if let recovered = recoverFromRotation([ComicBook].self, primaryURL: libraryURL) {
                comics = sortedComics(recovered)
                loadIssues.append(.comicsRecoveredFromBackup)
            } else {
                comics = []
                loadIssues.append(.comicsCorrupted)
            }
        }

        let series: [ComicSeries]
        do {
            if let decoded = try decodeIfPresent([ComicSeries].self, at: seriesURL) {
                series = sortedSeries(decoded)
            } else {
                // 文件不存在：正常首次启动，返回空系列。
                series = []
            }
        } catch {
            backUpCorruptFile(at: seriesURL)
            if let recovered = recoverFromRotation([ComicSeries].self, primaryURL: seriesURL) {
                series = sortedSeries(recovered)
                loadIssues.append(.seriesRecoveredFromBackup)
            } else {
                series = []
                loadIssues.append(.seriesCorrupted)
            }
        }

        return ComicLibrarySnapshot(comics: comics, series: series, loadIssues: loadIssues)
    }

    func saveComics(_ comics: [ComicBook], revision: Int, to url: URL) {
        guard revision >= latestComicsRevision else { return }
        latestComicsRevision = revision
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(comics)
            rotateBackups(beforeWriting: url)
            try data.write(to: url, options: .atomic)
        } catch {
            MReaderLog.reader.error("save library failed reason=\(MReaderLog.describe(error), privacy: .public)")
        }
    }

    func saveSeries(_ series: [ComicSeries], to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(series)
            rotateBackups(beforeWriting: url)
            try data.write(to: url, options: .atomic)
        } catch {
            MReaderLog.reader.error("save series failed reason=\(MReaderLog.describe(error), privacy: .public)")
        }
    }

    // MARK: - 损坏处理与备份轮换

    /// 读取并解码文件；文件不存在（首次启动）返回 nil，解码/读取失败抛错。
    private func decodeIfPresent<T: Decodable>(_ type: T.Type, at url: URL) throws -> T? {
        guard isRegularFile(at: url) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(type, from: data)
    }

    /// 尝试从轮换备份（previous → backup）恢复可用的快照。
    private func recoverFromRotation<T: Decodable>(_ type: T.Type, primaryURL: URL) -> T? {
        let (previousURL, backupURL) = rotatedBackupURLs(for: primaryURL)
        for candidate in [previousURL, backupURL] {
            if let value = try? decodeIfPresent(type, at: candidate) {
                return value
            }
        }
        return nil
    }

    /// 把损坏文件复制为 <basename>.corrupt-<时间戳>.json，保留现场供人工恢复/排查。
    private func backUpCorruptFile(at url: URL) {
        guard isRegularFile(at: url) else { return }
        let destination = corruptBackupURL(for: url)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
            MReaderLog.reader.notice("corrupt library file backed up path=\(destination.path, privacy: .public)")
        } catch {
            MReaderLog.reader.error("corrupt library file backup failed reason=\(MReaderLog.describe(error), privacy: .public)")
        }
    }

    /// 写入前轮换旧文件：主文件 → previous → backup，确保损坏时可从最近的成功版本恢复。
    private func rotateBackups(beforeWriting url: URL) {
        let (previousURL, backupURL) = rotatedBackupURLs(for: url)
        // 之前的 previous 下移到 backup 槽位
        if isRegularFile(at: previousURL) {
            replaceFile(at: backupURL, withContentsOf: previousURL)
        }
        // 当前主文件上移到 previous 槽位
        if isRegularFile(at: url) {
            replaceFile(at: previousURL, withContentsOf: url)
        }
    }

    private func replaceFile(at destination: URL, withContentsOf source: URL) {
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            MReaderLog.reader.error("library backup rotation failed reason=\(MReaderLog.describe(error), privacy: .public)")
        }
    }

    private func rotatedBackupURLs(for primaryURL: URL) -> (previous: URL, backup: URL) {
        let directory = primaryURL.deletingLastPathComponent()
        let baseName = primaryURL.deletingPathExtension().lastPathComponent
        return (
            directory.appendingPathComponent("\(baseName).previous.json"),
            directory.appendingPathComponent("\(baseName).backup.json")
        )
    }

    private func corruptBackupURL(for primaryURL: URL) -> URL {
        let directory = primaryURL.deletingLastPathComponent()
        let baseName = primaryURL.deletingPathExtension().lastPathComponent
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return directory.appendingPathComponent("\(baseName).corrupt-\(formatter.string(from: Date())).json")
    }

    private func isRegularFile(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    private func sortedComics(_ comics: [ComicBook]) -> [ComicBook] {
        comics.sorted { lhs, rhs in
            let lhsFinished = ComicReadingProgress.isFinished(lhs)
            let rhsFinished = ComicReadingProgress.isFinished(rhs)
            if lhsFinished != rhsFinished { return !lhsFinished }
            return lhs.lastReadAt > rhs.lastReadAt
        }
    }

    private func sortedSeries(_ series: [ComicSeries]) -> [ComicSeries] {
        series.sorted { $0.createdAt > $1.createdAt }
    }
}

@MainActor
final class ComicLibraryStore: ObservableObject {
    @Published private(set) var comics: [ComicBook] = []
    @Published private(set) var series: [ComicSeries] = []
    @Published private(set) var mediaSyncErrors: [MediaSourceType: String] = [:]
    @Published private(set) var libraryLoadIssues: [String] = []
    @Published private(set) var isLoaded = false

    private let libraryURL: URL
    private let seriesURL: URL
    private let diskStore = ComicLibraryDiskStore()
    private let syncCoordinator = LibrarySyncCoordinator()
    private var pendingKomgaProgressTasks: [UUID: Task<Void, Never>] = [:]
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    private var comicsSaveRevision = 0
    private var lastKomgaSyncCount = 0
    private var lastOPDSSyncCount = 0
    private var lastKomgaStartupSourceCount = 0
    private var lastKomgaStartupFailureCount = 0
    private var lastOPDSStartupSourceCount = 0
    private var lastOPDSStartupFailureCount = 0
    private var didStartStartupRemoteMaintenance = false

    static func shouldPublishRemoteComicUpdate(
        existing: ComicBook,
        merged: ComicBook,
        coverWasRefreshed: Bool
    ) -> Bool {
        merged != existing || coverWasRefreshed
    }

    private static func syncMetadataChanged(existing: ComicBook, incoming: ComicBook) -> Bool {
        existing.readingDirectionRaw != incoming.readingDirectionRaw
            || existing.readingModeRaw != incoming.readingModeRaw
            || existing.pageTurnAnimationRaw != incoming.pageTurnAnimationRaw
            || existing.imageFitModeRaw != incoming.imageFitModeRaw
            || existing.scrollSpeedRaw != incoming.scrollSpeedRaw
            || existing.bookmarks != incoming.bookmarks
    }

    init() {
        let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        libraryURL = applicationSupportURL.appendingPathComponent("library.json")
        seriesURL = applicationSupportURL.appendingPathComponent("series.json")
        ComicManager.ensureLocalLibraryExists()
        Task {
            await load()
            purgeNetworkLibraryState()
            restoreCachedRemoteCoverPaths()
            finishInitialLoad()
        }
    }

    /// Waits for the local shelf snapshot and its synchronous normalization to
    /// be ready. This is intentionally narrower than remote synchronization so
    /// the launch mask protects the first usable shelf without blocking on LAN
    /// or internet work.
    func waitUntilLoaded() async {
        if isLoaded { return }

        await withCheckedContinuation { continuation in
            if isLoaded {
                continuation.resume()
            } else {
                loadWaiters.append(continuation)
            }
        }
    }

    private func finishInitialLoad() {
        isLoaded = true
        let waiters = loadWaiters
        loadWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func add(_ comic: ComicBook) {
        if let index = comics.firstIndex(where: { matchesExistingComic($0, comic) }) {
            let existing = comics[index]
            var merged = comic
            merged.id = existing.id
            merged.title = existing.title.isEmpty ? comic.title : existing.title
            merged.currentPageIndex = min(max(existing.currentPageIndex, 0), max(0, comic.totalPages - 1))
            merged.furthestPageIndex = min(
                max(existing.furthestPageIndex, max(comic.furthestPageIndex, merged.currentPageIndex)),
                max(0, comic.totalPages - 1)
            )
            merged.progressUpdatedAt = existing.progressUpdatedAt
            merged.metadataUpdatedAt = existing.metadataUpdatedAt
            merged.hasBeenOpened = existing.hasBeenOpened
            merged.scrollProgress = existing.scrollProgress
            merged.scrollPageProgress = existing.scrollPageProgress
            merged.lastReadAt = existing.lastReadAt
            merged.isLocked = existing.isLocked
            merged.isOCREnabled = existing.isOCREnabled
            merged.isAITranslationEnabled = existing.isAITranslationEnabled
            merged.isAutoTranslationEnabled = existing.isAutoTranslationEnabled
            merged.isOfflineTranslationOverlayEnabled = existing.isOfflineTranslationOverlayEnabled
            merged.isAutoOCRMagnificationEnabled = existing.isAutoOCRMagnificationEnabled
            merged.ocrTextScale = existing.ocrTextScale
            merged.ocrSafeAreaInset = existing.ocrSafeAreaInset
            merged.ocrMinimumTextHeight = existing.ocrMinimumTextHeight
            merged.borderlessTranslationFontSize = existing.borderlessTranslationFontSize
            merged.aiTranslationModeRaw = existing.aiTranslationModeRaw
            merged.hasInitializedReadingPreset = existing.hasInitializedReadingPreset
            merged.readingDirectionRaw = existing.readingDirectionRaw
            merged.readingModeRaw = existing.readingModeRaw
            merged.pageTurnAnimationRaw = existing.pageTurnAnimationRaw
            merged.imageFitModeRaw = existing.imageFitModeRaw
            merged.scrollSpeedRaw = existing.scrollSpeedRaw
            merged.bookmarks = existing.bookmarks
            merged.libraryRelativePath = existing.libraryRelativePath ?? comic.libraryRelativePath
            // 本地系列归属优先，避免扫描或远端同步把用户手动移动结果覆盖掉。
            merged.seriesID = existing.seriesID ?? comic.seriesID
            comics[index] = merged
        } else {
            comics.insert(comic, at: 0)
        }
        sortAndSave()
    }

    func addImported(_ result: ComicManager.ImportResult, seriesID: UUID? = nil) {
        let comic = ComicBook(
            title: result.title,
            bookmarkData: result.bookmarkData,
            totalPages: result.pagesCount,
            coverImagePath: result.coverImagePath,
            fileSize: result.fileSize,
            libraryPath: result.libraryPath,
            libraryRelativePath: ComicManager.libraryRelativePath(for: URL(fileURLWithPath: result.libraryPath)),
            sourceTypeRaw: result.sourceTypeRaw,
            sourceURL: result.sourceURL,
            chapterTypeRaw: result.chapterTypeRaw,
            chapterPath: result.chapterPath,
            seriesID: seriesID
        )
        add(comic)
    }

    func delete(id: UUID) {
        if let comic = comics.first(where: { $0.id == id }) {
            if OfflineTranslationCoordinator.shared.job?.comicID == comic.id {
                OfflineTranslationCoordinator.shared.cancel()
            }
            Task {
                try? await OfflineTranslationStorageManager.shared.deleteComicTranslations(comicID: comic.id)
            }
            OfflineDownloadManager.shared.remove(comic)
            Task { await OCRRuntimeService.remove(comicID: comic.id) }
            if comic.sourceType == .local {
                ComicManager.deleteLibraryPath(comic.libraryPath)
            } else if comic.sourceType == .komga {
                Task {
                    await deleteKomgaComic(comic)
                }
                return
            }
        }
        comics.removeAll { $0.id == id }
        save()
    }

    func update(_ comic: ComicBook) {
        guard let index = comics.firstIndex(where: { $0.id == comic.id }) else { return }
        let existing = comics[index]
        var merged = comic
        merged.currentPageIndex = min(max(comic.currentPageIndex, 0), max(0, comic.totalPages - 1))
        merged.furthestPageIndex = min(
            max(existing.furthestPageIndex, max(comic.furthestPageIndex, merged.currentPageIndex)),
            max(0, comic.totalPages - 1)
        )
        merged.progressUpdatedAt = max(existing.progressUpdatedAt, comic.progressUpdatedAt)
        merged.metadataUpdatedAt = max(existing.metadataUpdatedAt, comic.metadataUpdatedAt)
        if Self.syncMetadataChanged(existing: existing, incoming: comic),
           comic.metadataUpdatedAt <= existing.metadataUpdatedAt {
            merged.metadataUpdatedAt = Date()
        }
        merged.hasBeenOpened = existing.hasBeenOpened || comic.hasBeenOpened
        comics[index] = merged
        sortAndSave()
        if merged.sourceType == .komga {
            scheduleKomgaProgressSync(for: merged)
        }
    }

    func applySyncedMetadata(_ payload: ICloudMetadataPayload, mediaSources: [MediaSource] = []) {
        let sourcesByID = Dictionary(uniqueKeysWithValues: mediaSources.map { ($0.id, $0) })
        let migratedPayload = ICloudMetadataMergePolicy.migrateLegacyV1(
            payload,
            comics: comics,
            sourcesByID: sourcesByID
        )
        var incoming: [String: SyncedComicMetadata] = [:]
        for item in migratedPayload.comics where !item.identity.isEmpty {
            guard incoming[item.identity] == nil else { continue }
            incoming[item.identity] = item
        }
        var changed = false
        for index in comics.indices {
            guard let identity = ComicSyncIdentity.v2Value(for: comics[index], sourcesByID: sourcesByID),
                  let remote = incoming[identity] else { continue }

            if remote.progressUpdatedAt > comics[index].progressUpdatedAt {
                comics[index].currentPageIndex = min(max(remote.currentPageIndex, 0), max(0, comics[index].totalPages - 1))
                comics[index].furthestPageIndex = min(
                    max(remote.furthestPageIndex, comics[index].currentPageIndex),
                    max(0, comics[index].totalPages - 1)
                )
                comics[index].progressUpdatedAt = remote.progressUpdatedAt
                comics[index].lastReadAt = max(comics[index].lastReadAt, remote.lastReadAt)
                comics[index].hasBeenOpened = comics[index].hasBeenOpened || remote.hasBeenOpened
                comics[index].scrollProgress = remote.scrollProgress
                comics[index].scrollPageProgress = remote.scrollPageProgress
                changed = true
            }

            if remote.metadataUpdatedAt > comics[index].metadataUpdatedAt {
                comics[index].metadataUpdatedAt = remote.metadataUpdatedAt
                comics[index].readingDirectionRaw = remote.readingDirectionRaw
                comics[index].readingModeRaw = remote.readingModeRaw
                comics[index].pageTurnAnimationRaw = remote.pageTurnAnimationRaw
                comics[index].imageFitModeRaw = remote.imageFitModeRaw
                comics[index].scrollSpeedRaw = remote.scrollSpeedRaw
                comics[index].bookmarks = remote.bookmarks
                changed = true
            }
        }
        if changed { sortAndSave() }
    }

    @discardableResult
    func addSeries(title: String, libraryPath: String? = nil) -> ComicSeries? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return nil }
        let folderPath = libraryPath ?? LibraryImportService.createSeriesFolder(title: trimmedTitle)?.path
        let newSeries = ComicSeries(title: trimmedTitle, libraryPath: folderPath)
        series.insert(newSeries, at: 0)
        saveSeries()
        return newSeries
    }

    func addComic(_ comicID: UUID, toSeries seriesID: UUID?) {
        guard let index = comics.firstIndex(where: { $0.id == comicID }) else { return }
        comics[index].seriesID = seriesID
        save()
    }

    /// 移动漫画到系列（本地漫画会物理移动文件，Komga 漫画只改 seriesID）
    func moveComicToSeries(_ comicID: UUID, toSeries seriesID: UUID?) -> Bool {
        guard let index = comics.firstIndex(where: { $0.id == comicID }) else { return false }
        let comic = comics[index]

        // 远程漫画：只改 seriesID
        if comic.sourceType != .local {
            comics[index].seriesID = seriesID
            save()
            return true
        }

        // 本地漫画：加入系列时移动到系列目录，移出系列时移动回漫画根目录。
        let targetPath: String
        if let targetSeriesID = seriesID {
            guard let seriesIndex = self.series.firstIndex(where: { $0.id == targetSeriesID }),
                  let path = self.series[seriesIndex].libraryPath else {
                return false
            }
            targetPath = path
        } else {
            guard let path = ComicManager.selectedLibraryRootURL()?.path else { return false }
            targetPath = path
        }
        guard !comic.bookmarkData.isEmpty else { return false }

        // 执行文件移动
        guard let newBookmark = LibraryImportService.moveComicFile(bookmarkData: comic.bookmarkData, to: URL(fileURLWithPath: targetPath, isDirectory: true)) else {
            return false
        }

        comics[index].seriesID = seriesID
        comics[index].bookmarkData = newBookmark
        if let newLibraryPath = LibraryImportService.libraryPathOfMovedFile(oldBookmark: comic.bookmarkData, newBookmark: newBookmark) {
            comics[index].libraryPath = newLibraryPath
            comics[index].libraryRelativePath = ComicManager.libraryRelativePath(for: URL(fileURLWithPath: newLibraryPath))
        }
        save()
        return true
    }

    func rebuildThumbnail(for id: UUID) {
        guard let index = comics.firstIndex(where: { $0.id == id }) else { return }
        if comics[index].sourceType == .komga {
            Task {
                await syncKomgaSources()
            }
            return
        }
        guard comics[index].sourceType == .local else { return }
        let bookmarkData = comics[index].bookmarkData
        Task.detached(priority: .utility) {
            let coverPath = ComicManager.rebuildCoverImage(bookmarkData: bookmarkData)
            let fileSize = ComicManager.librarySize(bookmarkData: bookmarkData)
            await MainActor.run {
                guard let currentIndex = self.comics.firstIndex(where: { $0.id == id }) else { return }
                if let coverPath {
                    self.comics[currentIndex].coverImagePath = coverPath
                }
                self.comics[currentIndex].fileSize = fileSize
                self.save()
            }
        }
    }

    func syncLocalLibrary() {
        Task {
            await syncLocalLibraryAsync()
        }
    }

    func syncLocalLibraryAsync() async {
        await syncCoordinator.perform(scope: .local) { [weak self] scope in
            guard let self else { return }
            await self.performLibrarySync(scope: scope)
        }
    }

    private func performLocalLibrarySync() async {
        let scanned = await Task.detached(priority: .utility) {
            LibraryImportService.scanLocalLibraryHierarchy()
        }.value
        applyScan(scanned)
    }

    func syncAllLibrariesAsync(skipPrewarm: Bool = false) async {
        var scope = LibrarySyncScope.all
        if !skipPrewarm {
            scope.insert(.prewarmKomga)
        }
        await syncCoordinator.perform(scope: scope) { [weak self] requestedScope in
            guard let self else { return }
            await self.performLibrarySync(scope: requestedScope)
        }
        HapticManager.shared.play(.success)
    }

    /// 启动时只恢复远程媒体源，不重新扫描本地漫画目录；所有远程源完成后
    /// 只产生一次与整体结果一致的反馈，不在每个服务器完成时分别震动。
    /// 本地库仍然先使用磁盘快照显示；Komga/OPDS 同步在后台增量更新书架。
    func syncStartupRemoteLibrariesAsync() async {
        lastKomgaStartupSourceCount = 0
        lastKomgaStartupFailureCount = 0
        lastOPDSStartupSourceCount = 0
        lastOPDSStartupFailureCount = 0
        await syncCoordinator.perform(scope: .startupRemote) { [weak self] requestedScope in
            guard let self else { return }
            await self.performLibrarySync(scope: requestedScope)
        }

        let outcome = StartupRemoteSyncOutcome.resolve(
            expectedSourceCount: lastKomgaStartupSourceCount + lastOPDSStartupSourceCount,
            failedSourceCount: lastKomgaStartupFailureCount + lastOPDSStartupFailureCount
        )
        if let hapticLevel = outcome.hapticLevel {
            HapticManager.shared.play(hapticLevel)
        }
    }

    private func performLibrarySync(scope: LibrarySyncScope) async {
        if scope.contains(.prewarmKomga) {
            await KomgaProvider.prewarmResolvedURLs()
        }
        if scope.contains(.local) {
            await performLocalLibrarySync()
        }
        if scope.contains(.komga) {
            lastKomgaSyncCount = await performKomgaSourcesSync()
        }
        if scope.contains(.opds) {
            lastOPDSSyncCount = await performOPDSSourcesSync()
        }
    }

    @discardableResult
    func syncKomgaSources() async -> Int {
        await syncCoordinator.perform(scope: .komga) { [weak self] scope in
            guard let self else { return }
            await self.performLibrarySync(scope: scope)
        }
        return lastKomgaSyncCount
    }

    /// 只刷新单个 Komga 源，避免“点 A 的刷新把同类型所有源都刷一遍”。
    func syncKomgaSource(id: UUID) async -> Int {
        await syncCoordinator.perform(scope: .komga) { [weak self] _ in
            guard let self else { return }
            _ = await self.performKomgaSourcesSync(sourceIDs: [id])
        }
        return lastKomgaSyncCount
    }

    private func performKomgaSourcesSync(sourceIDs: Set<UUID>? = nil) async -> Int {
        let loadedSources = await KomgaProvider.loadSources().filter { $0.type == .komga }
        let enabledSourceIDs = Set(
            loadedSources
                .filter { source in
                    source.isEnabled && (sourceIDs?.contains(source.id) ?? true)
                }
                .map(\.id)
        )
        lastKomgaStartupSourceCount = enabledSourceIDs.count
        let disabledSourceIDs = Set(loadedSources.filter { !$0.isEnabled }.map(\.id))
        let oldDisabledCount = comics.count
        comics.removeAll { comic in
            guard comic.sourceType == .komga, let sourceID = comic.mediaSourceID else { return false }
            return disabledSourceIDs.contains(sourceID)
        }
        let results = await KomgaProvider.syncEnabledSources(sourceIDs: sourceIDs)
        var changed = comics.count != oldDisabledCount
        var syncedCount = 0
        var errors: [String] = []
        for result in results {
            if let error = result.error {
                errors.append("\(result.source.name): \(error.localizedDescription)")
                MReaderLog.reader.error(
                    "Komga sync failed source=\(result.source.id.uuidString, privacy: .public) reason=\(MReaderLog.describe(error), privacy: .public)"
                )
                MReaderLog.reader.notice(
                    "Komga source unavailable; retaining existing library records source=\(result.source.id.uuidString, privacy: .public)"
                )
                continue
            }
            syncedCount += result.comics.count
            if applyKomgaScan(
                result.comics,
                sourceID: result.source.id,
                isAuthoritative: result.isAuthoritative,
                coverRefreshKeys: result.coverRefreshKeys
            ) {
                changed = true
            }
            if !result.isAuthoritative {
                MReaderLog.reader.notice(
                    "Komga sync incomplete; skipped missing-item cleanup source=\(result.source.id.uuidString, privacy: .public)"
                )
            }
        }
        let successfulSourceCount = results.filter { $0.error == nil && $0.isAuthoritative }.count
        lastKomgaStartupFailureCount = max(enabledSourceIDs.count - successfulSourceCount, 0)
        if changed {
            sortAndSave()
        }
        mediaSyncErrors[.komga] = errors.isEmpty ? nil : errors.joined(separator: "\n")
        return syncedCount
    }

    func removeKomgaSource(id: UUID) {
        for comic in comics where comic.sourceType == .komga && comic.mediaSourceID == id {
            pendingKomgaProgressTasks[comic.id]?.cancel()
            pendingKomgaProgressTasks[comic.id] = nil
        }
        let oldCount = comics.count
        comics.removeAll { $0.sourceType == .komga && $0.mediaSourceID == id }
        if comics.count != oldCount {
            save()
        }
    }

    @discardableResult
    func syncOPDSSources() async -> Int {
        await syncCoordinator.perform(scope: .opds) { [weak self] scope in
            guard let self else { return }
            await self.performLibrarySync(scope: scope)
        }
        return lastOPDSSyncCount
    }

    /// 只刷新单个 OPDS 源。
    @discardableResult
    func syncOPDSSource(id: UUID) async -> Int {
        await syncCoordinator.perform(scope: .opds) { [weak self] _ in
            guard let self else { return }
            _ = await self.performOPDSSourcesSync(sourceIDs: [id])
        }
        return lastOPDSSyncCount
    }

    private func performOPDSSourcesSync(sourceIDs: Set<UUID>? = nil) async -> Int {
        let loadedSources = await KomgaProvider.loadSources().filter { $0.type == .opds }
        let enabledSourceIDs = Set(
            loadedSources
                .filter { source in
                    source.isEnabled && (sourceIDs?.contains(source.id) ?? true)
                }
                .map(\.id)
        )
        lastOPDSStartupSourceCount = enabledSourceIDs.count
        let disabledSourceIDs = Set(loadedSources.filter { !$0.isEnabled }.map(\.id))
        let oldDisabledCount = comics.count
        comics.removeAll { comic in
            guard comic.sourceType == .opds, let sourceID = comic.mediaSourceID else { return false }
            return disabledSourceIDs.contains(sourceID)
        }
        let results = await OPDSProvider.syncEnabledSources(sourceIDs: sourceIDs)
        var changed = comics.count != oldDisabledCount
        var syncedCount = 0
        var errors: [String] = []
        for result in results {
            if let error = result.error {
                errors.append("\(result.source.name): \(error.localizedDescription)")
                MReaderLog.reader.error(
                    "OPDS sync failed source=\(result.source.id.uuidString, privacy: .public) reason=\(MReaderLog.describe(error), privacy: .public)"
                )
                continue
            }
            syncedCount += result.comics.count
            if applyRemoteScan(
                result.comics,
                sourceID: result.source.id,
                sourceType: .opds,
                isAuthoritative: result.isAuthoritative
            ) {
                changed = true
            }
        }
        let successfulSourceCount = results.filter { $0.error == nil && $0.isAuthoritative }.count
        lastOPDSStartupFailureCount = max(enabledSourceIDs.count - successfulSourceCount, 0)
        if changed {
            sortAndSave()
        }
        mediaSyncErrors[.opds] = errors.isEmpty ? nil : errors.joined(separator: "\n")
        return syncedCount
    }

    func removeOPDSSource(id: UUID) {
        let oldCount = comics.count
        comics.removeAll { $0.sourceType == .opds && $0.mediaSourceID == id }
        OPDSProvider.removeCachedFiles(sourceID: id)
        if comics.count != oldCount {
            save()
        }
    }

    func setKomgaSourceEnabled(id: UUID, isEnabled: Bool) async {
        var sources = await KomgaProvider.loadSources()
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].isEnabled = isEnabled
        try? await KomgaProvider.updateSource(sources[index])
        if isEnabled {
            await syncKomgaSources()
        } else {
            removeKomgaSource(id: id)
        }
    }

    func setMediaSourceEnabled(id: UUID, isEnabled: Bool) async {
        guard let source = await KomgaProvider.loadSources().first(where: { $0.id == id }) else { return }
        var updatedSource = source
        updatedSource.isEnabled = isEnabled
        try? await KomgaProvider.updateSource(updatedSource)
        switch source.type {
        case .komga:
            if isEnabled { _ = await syncKomgaSources() } else { removeKomgaSource(id: id) }
        case .opds:
            if isEnabled { _ = await syncOPDSSources() } else { removeOPDSSource(id: id) }
        case .local:
            break
        }
    }

    func refreshVisibility() {
        objectWillChange.send()
    }

    private func applyScan(_ scanned: ComicManager.LibraryScanResult) {
        let scannedComicPaths = Set((scanned.comics + scanned.series.flatMap(\.comics)).map(\.libraryPath))
        let scannedSeriesPaths = Set(scanned.series.map(\.libraryPath))
        var changed = false

        for scannedSeries in scanned.series {
            let seriesID: UUID
            if let index = series.firstIndex(where: { $0.libraryPath == scannedSeries.libraryPath || ($0.libraryPath == nil && $0.title == scannedSeries.title) }) {
                seriesID = series[index].id
                if series[index].libraryPath != scannedSeries.libraryPath {
                    series[index].libraryPath = scannedSeries.libraryPath
                    changed = true
                }
                if series[index].title != scannedSeries.title {
                    series[index].title = scannedSeries.title
                    changed = true
                }
            } else {
                let newSeries = ComicSeries(title: scannedSeries.title, libraryPath: scannedSeries.libraryPath)
                series.append(newSeries)
                seriesID = newSeries.id
                changed = true
            }

            for result in scannedSeries.comics {
                if upsertScannedComic(result, seriesID: seriesID) {
                    changed = true
                }
            }
        }

        for result in scanned.comics {
            if upsertScannedComic(result, seriesID: nil) {
                changed = true
            }
        }

        let oldComicCount = comics.count
        comics.removeAll { comic in
            guard let path = comic.libraryPath else { return false }
            return comic.sourceType == .local && !scannedComicPaths.contains(path) && !FileManager.default.fileExists(atPath: path)
        }
        changed = changed || comics.count != oldComicCount

        let oldSeriesCount = series.count
        series.removeAll { item in
            guard let path = item.libraryPath else { return false }
            return !scannedSeriesPaths.contains(path) && !FileManager.default.fileExists(atPath: path)
        }
        changed = changed || series.count != oldSeriesCount

        if changed {
            sortAndSave()
            saveSeries()
        }
    }

    func rebuildAllThumbnails() {
        let workItems = comics.filter { $0.sourceType == .local }.map { ($0.id, $0.bookmarkData) }
        Task {
            await syncKomgaSources()
        }
        Task.detached(priority: .utility) {
            for (id, bookmarkData) in workItems {
                let coverPath = ComicManager.rebuildCoverImage(bookmarkData: bookmarkData)
                let fileSize = ComicManager.librarySize(bookmarkData: bookmarkData)
                await MainActor.run {
                    guard let index = self.comics.firstIndex(where: { $0.id == id }) else { return }
                    var changed = false
                    if let coverPath, self.comics[index].coverImagePath != coverPath {
                        self.comics[index].coverImagePath = coverPath
                        changed = true
                    }
                    if self.comics[index].fileSize != fileSize {
                        self.comics[index].fileSize = fileSize
                        changed = true
                    }
                    if changed {
                        self.save()
                    }
                }
                ComicManager.logMemory("rebuild-thumbnail \(id.uuidString)")
            }
        }
    }

    func rebuildThumbnails(for comicIDs: Set<UUID>, seriesIDs: Set<UUID>) {
        let seriesComicIDs = Set(comics.filter { comic in
            guard let seriesID = comic.seriesID else { return false }
            return seriesIDs.contains(seriesID)
        }.map(\.id))
        for id in comicIDs.union(seriesComicIDs) {
            rebuildThumbnail(for: id)
        }
    }

    func rename(id: UUID, title: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, let index = comics.firstIndex(where: { $0.id == id }) else { return }
        comics[index].title = trimmedTitle
        save()
    }

    func deleteSeries(id: UUID) {
        if let item = series.first(where: { $0.id == id }) {
            ComicManager.deleteLibraryPath(item.libraryPath)
        }
        comics.removeAll { $0.seriesID == id }
        series.removeAll { $0.id == id }
        save()
        saveSeries()
    }

    func renameSeries(id: UUID, title: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, let index = series.firstIndex(where: { $0.id == id }) else { return }
        series[index].title = trimmedTitle
        saveSeries()
    }

    func setLocked(id: UUID, isLocked: Bool) {
        guard let index = comics.firstIndex(where: { $0.id == id }) else { return }
        comics[index].isLocked = isLocked
        save()
    }

    func markAsRead(id: UUID) {
        guard let index = comics.firstIndex(where: { $0.id == id }) else { return }
        comics[index].currentPageIndex = max(comics[index].totalPages - 1, 0)
        comics[index].furthestPageIndex = comics[index].currentPageIndex
        comics[index].progressUpdatedAt = Date()
        comics[index].hasBeenOpened = true
        comics[index].lastReadAt = Date()
        let updatedComic = comics[index]
        sortAndSave()
        if updatedComic.sourceType == .komga {
            scheduleKomgaProgressSync(for: updatedComic)
        }
    }

    func markSeriesAsRead(seriesID: UUID) {
        var changed = false
        var updatedKomgaComics: [ComicBook] = []
        for index in comics.indices where comics[index].seriesID == seriesID && !ComicReadingProgress.isFinished(comics[index]) {
            comics[index].currentPageIndex = max(comics[index].totalPages - 1, 0)
            comics[index].furthestPageIndex = comics[index].currentPageIndex
            comics[index].progressUpdatedAt = Date()
            comics[index].hasBeenOpened = true
            comics[index].lastReadAt = Date()
            if comics[index].sourceType == .komga {
                updatedKomgaComics.append(comics[index])
            }
            changed = true
        }
        if changed {
            sortAndSave()
            for comic in updatedKomgaComics {
                scheduleKomgaProgressSync(for: comic)
            }
        }
    }

    func resetReadingPresetDetection() {
        for index in comics.indices {
            comics[index].hasInitializedReadingPreset = false
        }
        save()
    }

    private func load() async {
        let snapshot = await diskStore.load(libraryURL: libraryURL, seriesURL: seriesURL)
        comics = snapshot.comics
        series = snapshot.series
        normalizeLegacyReadingDefaults()
        normalizeLegacyLibraryRelativePaths()
        if !snapshot.loadIssues.isEmpty {
            libraryLoadIssues = snapshot.loadIssues.map(\.userMessage)
            for issue in snapshot.loadIssues {
                MReaderLog.reader.error("library load issue=\(issue.userMessage, privacy: .public)")
            }
        }
    }

    /// library.json 可能保存了旧容器中的绝对 Application Support 路径。
    /// Komga 封面缓存的稳定身份是 sourceID + bookID，启动加载后据此恢复当前路径。
    private func restoreCachedRemoteCoverPaths() {
        var changed = false
        for index in comics.indices {
            let comic = comics[index]
            guard comic.sourceType == .komga,
                  let sourceID = comic.mediaSourceID,
                  let bookID = comic.komgaBookID,
                  let currentPath = RemoteImageLoader.cachedCoverPath(sourceID: sourceID, bookID: bookID),
                  comic.coverImagePath != currentPath else {
                continue
            }
            comics[index].coverImagePath = currentPath
            changed = true
        }
        if changed {
            save()
        }
    }

    private func sortAndSave() {
        comics.sort { lhs, rhs in
            let lhsFinished = ComicReadingProgress.isFinished(lhs)
            let rhsFinished = ComicReadingProgress.isFinished(rhs)
            if lhsFinished != rhsFinished { return !lhsFinished }
            return lhs.lastReadAt > rhs.lastReadAt
        }
        save()
    }

    func runStartupMaintenance() {
        Task {
            await syncAllLibrariesAsync()
        }
    }

    func runStartupRemoteMaintenance() {
        guard !didStartStartupRemoteMaintenance else { return }
        didStartStartupRemoteMaintenance = true
        Task { [weak self] in
            guard let self else { return }
            await self.syncStartupRemoteLibrariesAsync()
        }
    }

    private func purgeNetworkLibraryState() {
        UserDefaults.standard.removeObject(forKey: "mreader.smb.librarySources")
        UserDefaults.standard.removeObject(forKey: "mreader.webdav.librarySources")
        let oldComicCount = comics.count
        let oldSeriesCount = series.count
        comics.removeAll { comic in
            let legacyRemoteType = ![ComicSourceType.local.rawValue, ComicSourceType.komga.rawValue, ComicSourceType.opds.rawValue].contains(comic.sourceTypeRaw)
            let misplacedLegacyPath = comic.sourceType == .local && (
                comic.libraryPath?.hasPrefix("smb://") == true ||
                comic.libraryPath?.hasPrefix("http://") == true ||
                comic.libraryPath?.hasPrefix("https://") == true
            )
            return legacyRemoteType || misplacedLegacyPath
        }
        series.removeAll { item in
            guard let path = item.libraryPath else { return false }
            return path.hasPrefix("smb://") || path.hasPrefix("http://") || path.hasPrefix("https://")
        }
        if comics.count != oldComicCount {
            save()
        }
        if series.count != oldSeriesCount {
            saveSeries()
        }
    }

    private func normalizeLegacyReadingDefaults() {
        var changed = false
        for index in comics.indices {
            if abs(comics[index].ocrSafeAreaInset - 0.05) < 0.000_001 {
                comics[index].ocrSafeAreaInset = 0
                changed = true
            }
            if abs(comics[index].ocrMinimumTextHeight - 0.014) < 0.000_001 ||
                abs(comics[index].ocrMinimumTextHeight - 0.006) < 0.000_001 {
                comics[index].ocrMinimumTextHeight = 0.002
                changed = true
            }
            if AITranslationMode(rawValue: comics[index].aiTranslationModeRaw) == nil {
                comics[index].aiTranslationModeRaw = AITranslationMode.ocr.rawValue
                changed = true
            }
        }
        if changed {
            save()
        }
    }

    private func normalizeLegacyLibraryRelativePaths() {
        var changed = false
        for index in comics.indices where comics[index].sourceType == .local && comics[index].libraryRelativePath == nil {
            guard let path = comics[index].libraryPath else { continue }
            if let relativePath = ComicManager.libraryRelativePath(for: URL(fileURLWithPath: path)) {
                comics[index].libraryRelativePath = relativePath
                changed = true
            }
        }
        if changed {
            save()
        }
    }

    private func matchesExistingComic(_ existing: ComicBook, _ incoming: ComicBook) -> Bool {
        if existing.id == incoming.id {
            return true
        }
        if existing.sourceType == .local, incoming.sourceType == .local,
           existing.libraryPath != nil, existing.libraryPath == incoming.libraryPath {
            return true
        }
        if existing.sourceType == .komga, incoming.sourceType == .komga,
           existing.mediaSourceID == incoming.mediaSourceID,
           existing.komgaBookID == incoming.komgaBookID {
            return true
        }
        if existing.sourceType == .opds, incoming.sourceType == .opds,
           existing.mediaSourceID == incoming.mediaSourceID,
           existing.remoteCoverID == incoming.remoteCoverID {
            return true
        }
        return false
    }

    private func removeLocalKomgaState(for comic: ComicBook) async {
        pendingKomgaProgressTasks[comic.id]?.cancel()
        pendingKomgaProgressTasks[comic.id] = nil
        comics.removeAll { existing in
            if existing.id == comic.id {
                return true
            }
            guard existing.sourceType == .komga,
                  comic.sourceType == .komga,
                  existing.mediaSourceID == comic.mediaSourceID,
                  existing.komgaBookID == comic.komgaBookID else {
                return false
            }
            return true
        }
        if let key = KomgaProvider.hiddenKey(for: comic) {
            await KomgaProvider.unhideComic(key: key)
        }
        if let sourceID = comic.mediaSourceID, let bookID = comic.komgaBookID {
            RemoteImageLoader.removeCachedImages(sourceID: sourceID, bookID: bookID)
            RemotePageLoader.removeCachedPages(sourceID: sourceID, bookID: bookID)
        }
        save()
    }

    private func applyKomgaScan(
        _ remoteComics: [ComicBook],
        sourceID: UUID,
        isAuthoritative: Bool,
        coverRefreshKeys: Set<String> = []
    ) -> Bool {
        applyRemoteScan(
            remoteComics,
            sourceID: sourceID,
            sourceType: .komga,
            isAuthoritative: isAuthoritative,
            coverRefreshKeys: coverRefreshKeys
        )
    }

    private func applyRemoteScan(
        _ remoteComics: [ComicBook],
        sourceID: UUID,
        sourceType: ComicSourceType,
        isAuthoritative: Bool,
        coverRefreshKeys: Set<String> = []
    ) -> Bool {
        var changed = false
        let remoteKeys = Set(remoteComics.map(remoteIdentityKey))
        for comic in remoteComics where upsertRemoteComic(
            comic,
            coverWasRefreshed: coverRefreshKeys.contains(remoteIdentityKey(comic))
        ) {
            changed = true
        }
        guard isAuthoritative else { return changed }
        let oldCount = comics.count
        comics.removeAll { comic in
            guard comic.sourceType == sourceType, comic.mediaSourceID == sourceID else { return false }
            return !remoteKeys.contains(remoteIdentityKey(comic))
        }
        return changed || comics.count != oldCount
    }

    private func remoteIdentityKey(_ comic: ComicBook) -> String {
        switch comic.sourceType {
        case .komga:
            return "\(comic.mediaSourceID?.uuidString ?? ""):\(comic.komgaBookID ?? "")"
        case .opds:
            return "\(comic.mediaSourceID?.uuidString ?? ""):\(comic.remoteCoverID ?? comic.sourceURL ?? "")"
        case .local:
            return comic.libraryPath ?? comic.id.uuidString
        }
    }

    private func upsertRemoteComic(_ comic: ComicBook, coverWasRefreshed: Bool = false) -> Bool {
        if let index = comics.firstIndex(where: { matchesExistingComic($0, comic) }) {
            let existing = comics[index]
            var merged = comic
            merged.id = existing.id
            if comic.sourceType == .komga {
                merged.coverImagePath = RemoteImageLoader.resolvedCoverPath(
                    persistedPath: comic.coverImagePath ?? existing.coverImagePath,
                    sourceID: comic.mediaSourceID ?? existing.mediaSourceID,
                    bookID: comic.komgaBookID ?? existing.komgaBookID
                )
            }
            if comic.sourceType == .opds {
                merged.totalPages = max(existing.totalPages, comic.totalPages)
                merged.remotePageCount = existing.remotePageCount ?? comic.remotePageCount
            }
            let progressResolution = ReadingProgressMergePolicy.resolve(
                existing: existing,
                incoming: comic,
                totalPages: merged.totalPages
            )
            merged.currentPageIndex = progressResolution.currentPageIndex
            merged.furthestPageIndex = progressResolution.furthestPageIndex
            merged.progressUpdatedAt = progressResolution.progressUpdatedAt
            merged.metadataUpdatedAt = existing.metadataUpdatedAt
            if progressResolution.usesIncomingLocation {
                merged.scrollProgress = comic.scrollProgress
                merged.scrollPageProgress = comic.scrollPageProgress
            } else {
                merged.scrollProgress = existing.scrollProgress
                merged.scrollPageProgress = existing.scrollPageProgress
            }
            merged.hasBeenOpened = existing.hasBeenOpened || comic.hasBeenOpened || merged.furthestPageIndex > 0
            merged.lastReadAt = max(existing.lastReadAt, comic.lastReadAt)
            merged.isLocked = existing.isLocked
            merged.isOCREnabled = existing.isOCREnabled
            merged.isAITranslationEnabled = existing.isAITranslationEnabled
            merged.isAutoTranslationEnabled = existing.isAutoTranslationEnabled
            merged.isOfflineTranslationOverlayEnabled = existing.isOfflineTranslationOverlayEnabled
            merged.isAutoOCRMagnificationEnabled = existing.isAutoOCRMagnificationEnabled
            merged.ocrTextScale = existing.ocrTextScale
            merged.ocrSafeAreaInset = existing.ocrSafeAreaInset
            merged.ocrMinimumTextHeight = existing.ocrMinimumTextHeight
            merged.borderlessTranslationFontSize = existing.borderlessTranslationFontSize
            merged.aiTranslationModeRaw = existing.aiTranslationModeRaw
            merged.hasInitializedReadingPreset = existing.hasInitializedReadingPreset
            merged.readingDirectionRaw = existing.readingDirectionRaw
            merged.readingModeRaw = existing.readingModeRaw
            merged.pageTurnAnimationRaw = existing.pageTurnAnimationRaw
            merged.imageFitModeRaw = existing.imageFitModeRaw
            merged.scrollSpeedRaw = existing.scrollSpeedRaw
            merged.bookmarks = existing.bookmarks
            merged.seriesID = existing.seriesID
            let didChange = Self.shouldPublishRemoteComicUpdate(
                existing: existing,
                merged: merged,
                coverWasRefreshed: coverWasRefreshed
            )
            if didChange {
                comics[index] = merged
            }
            if comic.sourceType == .komga, existing.furthestPageIndex > comic.furthestPageIndex {
                Task {
                    await self.syncKomgaProgressNow(for: merged)
                }
            }
            return didChange
        }
        comics.append(comic)
        return true
    }

    private func deleteKomgaComic(_ comic: ComicBook) async {
        do {
            try await KomgaProvider.deleteBook(comic)
            await removeLocalKomgaState(for: comic)
            HapticManager.shared.play(.success)
        } catch MediaSourceError.notFound {
            await removeLocalKomgaState(for: comic)
            HapticManager.shared.play(.success)
        } catch {
            MReaderLog.reader.error(
                "Komga delete failed comic=\(comic.id.uuidString, privacy: .public) reason=\(MReaderLog.describe(error), privacy: .public)"
            )
            HapticManager.shared.play(.error)
        }
    }

    private func scheduleKomgaProgressSync(for comic: ComicBook) {
        guard comic.sourceType == .komga else { return }
        pendingKomgaProgressTasks[comic.id]?.cancel()
        pendingKomgaProgressTasks[comic.id] = Task { [comic] in
            do {
                try await Task.sleep(nanoseconds: 1_500_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self.syncKomgaProgressNow(for: comic)
            await MainActor.run {
                self.pendingKomgaProgressTasks[comic.id] = nil
            }
        }
    }

    private func syncKomgaProgressNow(for comic: ComicBook) async {
        do {
            try await KomgaProvider.updateReadProgress(for: comic)
        } catch {
            MReaderLog.reader.error(
                "Komga reading progress sync failed comic=\(comic.id.uuidString, privacy: .public) reason=\(MReaderLog.describe(error), privacy: .public)"
            )
        }
    }

    private func upsertScannedComic(_ result: ComicManager.ImportResult, seriesID: UUID?) -> Bool {
        let relativePath = ComicManager.libraryRelativePath(for: URL(fileURLWithPath: result.libraryPath))
        if let index = comics.firstIndex(where: { $0.libraryPath == result.libraryPath }) {
            var changed = false
            if comics[index].bookmarkData != result.bookmarkData {
                comics[index].bookmarkData = result.bookmarkData
                changed = true
            }
            if comics[index].totalPages != result.pagesCount {
                comics[index].totalPages = result.pagesCount
                changed = true
            }
            if comics[index].fileSize != result.fileSize {
                comics[index].fileSize = result.fileSize
                changed = true
            }
            if let coverImagePath = result.coverImagePath,
               comics[index].coverImagePath != coverImagePath {
                comics[index].coverImagePath = coverImagePath
                changed = true
            }
            if comics[index].seriesID != seriesID {
                comics[index].seriesID = seriesID
                changed = true
            }
            if comics[index].sourceTypeRaw != result.sourceTypeRaw {
                comics[index].sourceTypeRaw = result.sourceTypeRaw
                changed = true
            }
            if comics[index].sourceURL != result.sourceURL {
                comics[index].sourceURL = result.sourceURL
                changed = true
            }
            if comics[index].chapterTypeRaw != result.chapterTypeRaw {
                comics[index].chapterTypeRaw = result.chapterTypeRaw
                changed = true
            }
            if comics[index].chapterPath != result.chapterPath {
                comics[index].chapterPath = result.chapterPath
                changed = true
            }
            if comics[index].libraryRelativePath != relativePath {
                comics[index].libraryRelativePath = relativePath
                changed = true
            }
            return changed
        }

        comics.append(ComicBook(
            title: result.title,
            bookmarkData: result.bookmarkData,
            totalPages: result.pagesCount,
            coverImagePath: result.coverImagePath,
            fileSize: result.fileSize,
            libraryPath: result.libraryPath,
            libraryRelativePath: relativePath,
            sourceTypeRaw: result.sourceTypeRaw,
            sourceURL: result.sourceURL,
            chapterTypeRaw: result.chapterTypeRaw,
            chapterPath: result.chapterPath,
            seriesID: seriesID
        ))
        return true
    }

    private func save() {
        comicsSaveRevision += 1
        let revision = comicsSaveRevision
        let snapshot = comics
        let url = libraryURL
        Task {
            await diskStore.saveComics(snapshot, revision: revision, to: url)
        }
    }

    private func saveSeries() {
        let snapshot = series
        let url = seriesURL
        Task {
            await diskStore.saveSeries(snapshot, to: url)
        }
    }
}
