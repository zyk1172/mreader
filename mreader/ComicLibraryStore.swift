import Foundation
import Combine

nonisolated private struct ComicLibrarySnapshot: Sendable {
    let comics: [ComicBook]
    let series: [ComicSeries]
}

private actor ComicLibraryDiskStore {
    private var latestComicsRevision = 0

    func load(libraryURL: URL, seriesURL: URL) -> ComicLibrarySnapshot {
        let comics: [ComicBook]
        do {
            let data = try Data(contentsOf: libraryURL)
            comics = try JSONDecoder().decode([ComicBook].self, from: data)
                .sorted { $0.lastReadAt > $1.lastReadAt }
        } catch {
            comics = []
        }

        let series: [ComicSeries]
        do {
            let data = try Data(contentsOf: seriesURL)
            series = try JSONDecoder().decode([ComicSeries].self, from: data)
                .sorted { $0.createdAt > $1.createdAt }
        } catch {
            series = []
        }
        return ComicLibrarySnapshot(comics: comics, series: series)
    }

    func saveComics(_ comics: [ComicBook], revision: Int, to url: URL) {
        guard revision >= latestComicsRevision else { return }
        latestComicsRevision = revision
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(comics)
            try data.write(to: url, options: .atomic)
        } catch {
            print("保存书架失败: \(error)")
        }
    }

    func saveSeries(_ series: [ComicSeries], to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(series)
            try data.write(to: url, options: .atomic)
        } catch {
            print("保存系列失败: \(error)")
        }
    }
}

@MainActor
final class ComicLibraryStore: ObservableObject {
    @Published private(set) var comics: [ComicBook] = []
    @Published private(set) var series: [ComicSeries] = []

    private let libraryURL: URL
    private let seriesURL: URL
    private let diskStore = ComicLibraryDiskStore()
    private var pendingKomgaProgressTasks: [UUID: Task<Void, Never>] = [:]
    private var comicsSaveRevision = 0

    init() {
        let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        libraryURL = applicationSupportURL.appendingPathComponent("library.json")
        seriesURL = applicationSupportURL.appendingPathComponent("series.json")
        ComicManager.ensureLocalLibraryExists()
        Task {
            await load()
            purgeNetworkLibraryState()
            runStartupMaintenance()
        }
    }

    func add(_ comic: ComicBook) {
        if let index = comics.firstIndex(where: { matchesExistingComic($0, comic) }) {
            let existing = comics[index]
            var merged = comic
            merged.id = existing.id
            merged.title = existing.title.isEmpty ? comic.title : existing.title
            merged.currentPageIndex = min(max(existing.currentPageIndex, 0), max(0, comic.totalPages - 1))
            merged.hasBeenOpened = existing.hasBeenOpened
            merged.scrollProgress = existing.scrollProgress
            merged.scrollPageProgress = existing.scrollPageProgress
            merged.lastReadAt = existing.lastReadAt
            merged.isLocked = existing.isLocked
            merged.isOCREnabled = existing.isOCREnabled
            merged.isAITranslationEnabled = existing.isAITranslationEnabled
            merged.isAutoTranslationEnabled = existing.isAutoTranslationEnabled
            merged.isAutoOCRMagnificationEnabled = existing.isAutoOCRMagnificationEnabled
            merged.ocrTextScale = existing.ocrTextScale
            merged.ocrSafeAreaInset = existing.ocrSafeAreaInset
            merged.ocrMinimumTextHeight = existing.ocrMinimumTextHeight
            merged.aiTranslationModeRaw = existing.aiTranslationModeRaw
            merged.hasInitializedReadingPreset = existing.hasInitializedReadingPreset
            merged.readingDirectionRaw = existing.readingDirectionRaw
            merged.readingModeRaw = existing.readingModeRaw
            merged.pageTurnAnimationRaw = existing.pageTurnAnimationRaw
            merged.imageFitModeRaw = existing.imageFitModeRaw
            merged.scrollSpeedRaw = existing.scrollSpeedRaw
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
            sourceTypeRaw: result.sourceTypeRaw,
            sourceURL: result.sourceURL,
            chapterTypeRaw: result.chapterTypeRaw,
            chapterPath: result.chapterPath,
            seriesID: seriesID
        )
        add(comic)
    }

    func delete(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            if comics[index].sourceType == .local {
                ComicManager.deleteLibraryPath(comics[index].libraryPath)
            }
            comics.remove(at: index)
        }
        save()
    }

    func delete(id: UUID) {
        if let comic = comics.first(where: { $0.id == id }) {
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
        if comic.sourceType == .komga {
            merged.currentPageIndex = min(max(existing.currentPageIndex, comic.currentPageIndex), max(0, comic.totalPages - 1))
        }
        merged.hasBeenOpened = existing.hasBeenOpened || comic.hasBeenOpened
        comics[index] = merged
        sortAndSave()
        if merged.sourceType == .komga {
            scheduleKomgaProgressSync(for: merged)
        }
    }

    @discardableResult
    func addSeries(title: String, libraryPath: String? = nil) -> ComicSeries? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return nil }
        let folderPath = libraryPath ?? ComicManager.createSeriesFolder(title: trimmedTitle)?.path
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
        guard let newBookmark = ComicManager.moveComicFile(bookmarkData: comic.bookmarkData, to: URL(fileURLWithPath: targetPath, isDirectory: true)) else {
            return false
        }

        comics[index].seriesID = seriesID
        comics[index].bookmarkData = newBookmark
        if let newLibraryPath = ComicManager.libraryPathOfMovedFile(oldBookmark: comic.bookmarkData, newBookmark: newBookmark) {
            comics[index].libraryPath = newLibraryPath
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
            await syncAllLibrariesAsync()
        }
    }

    func syncLocalLibraryAsync() async {
        let scanned = await Task.detached(priority: .utility) {
            ComicManager.scanLocalLibraryHierarchy()
        }.value
        applyScan(scanned)
    }

    func syncAllLibrariesAsync() async {
        await syncLocalLibraryAsync()
        await syncKomgaSources()
        await syncOPDSSources()
        HapticManager.shared.play(.success)
    }

    @discardableResult
    func syncKomgaSources() async -> Int {
        let loadedSources = KomgaProvider.loadSources().filter { $0.type == .komga }
        let disabledSourceIDs = Set(loadedSources.filter { !$0.isEnabled }.map(\.id))
        let oldDisabledCount = comics.count
        comics.removeAll { comic in
            guard comic.sourceType == .komga, let sourceID = comic.mediaSourceID else { return false }
            return disabledSourceIDs.contains(sourceID)
        }
        let results = await KomgaProvider.syncEnabledSources()
        var changed = comics.count != oldDisabledCount
        var syncedCount = 0
        for result in results {
            if let error = result.error {
                print("Komga 同步失败 \(result.source.name): \(error.localizedDescription)")
                print("Komga 源暂时不可用，保留旧书架记录: \(result.source.name)")
                continue
            }
            syncedCount += result.comics.count
            if applyKomgaScan(result.comics, sourceID: result.source.id, isAuthoritative: result.isAuthoritative) {
                changed = true
            }
            if !result.isAuthoritative {
                print("Komga 同步结果不完整，跳过缺失项清理: \(result.source.name)")
            }
        }
        if changed {
            sortAndSave()
        }
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
        let loadedSources = KomgaProvider.loadSources().filter { $0.type == .opds }
        let disabledSourceIDs = Set(loadedSources.filter { !$0.isEnabled }.map(\.id))
        let oldDisabledCount = comics.count
        comics.removeAll { comic in
            guard comic.sourceType == .opds, let sourceID = comic.mediaSourceID else { return false }
            return disabledSourceIDs.contains(sourceID)
        }
        let results = await OPDSProvider.syncEnabledSources()
        var changed = comics.count != oldDisabledCount
        var syncedCount = 0
        for result in results {
            if let error = result.error {
                print("OPDS 同步失败 \(result.source.name): \(error.localizedDescription)")
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
        if changed {
            sortAndSave()
        }
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
        var sources = KomgaProvider.loadSources()
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].isEnabled = isEnabled
        try? KomgaProvider.updateSource(sources[index])
        if isEnabled {
            await syncKomgaSources()
        } else {
            removeKomgaSource(id: id)
        }
    }

    func setMediaSourceEnabled(id: UUID, isEnabled: Bool) async {
        guard let source = KomgaProvider.loadSources().first(where: { $0.id == id }) else { return }
        var updatedSource = source
        updatedSource.isEnabled = isEnabled
        try? KomgaProvider.updateSource(updatedSource)
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

    private func load() async {
        let snapshot = await diskStore.load(libraryURL: libraryURL, seriesURL: seriesURL)
        comics = snapshot.comics
        series = snapshot.series
        normalizeLegacyReadingDefaults()
    }

    private func sortAndSave() {
        comics.sort { $0.lastReadAt > $1.lastReadAt }
        save()
    }

    func runStartupMaintenance() {
        syncLocalLibrary()
    }

    private func purgeNetworkLibraryState() {
        UserDefaults.standard.removeObject(forKey: "mreader.smb.librarySources")
        UserDefaults.standard.removeObject(forKey: "mreader.webdav.librarySources")
        let oldComicCount = comics.count
        let oldSeriesCount = series.count
        comics.removeAll { comic in
            let legacyRemoteType = ![ComicSourceType.local.rawValue, ComicSourceType.komga.rawValue, ComicSourceType.opds.rawValue].contains(comic.sourceTypeRaw)
            return legacyRemoteType ||
            comic.libraryPath?.hasPrefix("smb://") == true ||
            comic.libraryPath?.hasPrefix("http://") == true ||
            comic.libraryPath?.hasPrefix("https://") == true
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

    private func komgaIdentityKey(for comic: ComicBook) -> String? {
        guard comic.sourceType == .komga,
              let sourceID = comic.mediaSourceID,
              let bookID = comic.komgaBookID else {
            return nil
        }
        return "\(sourceID.uuidString):\(bookID)"
    }

    private func removeLocalKomgaState(for comic: ComicBook) {
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
            KomgaProvider.unhideComic(key: key)
        }
        if let sourceID = comic.mediaSourceID, let bookID = comic.komgaBookID {
            RemoteImageLoader.removeCachedImages(sourceID: sourceID, bookID: bookID)
            RemotePageLoader.removeCachedPages(sourceID: sourceID, bookID: bookID)
        }
        save()
    }

    private func applyKomgaScan(_ remoteComics: [ComicBook], sourceID: UUID, isAuthoritative: Bool) -> Bool {
        applyRemoteScan(remoteComics, sourceID: sourceID, sourceType: .komga, isAuthoritative: isAuthoritative)
    }

    private func applyRemoteScan(
        _ remoteComics: [ComicBook],
        sourceID: UUID,
        sourceType: ComicSourceType,
        isAuthoritative: Bool
    ) -> Bool {
        var changed = false
        let remoteKeys = Set(remoteComics.map(remoteIdentityKey))
        for comic in remoteComics where upsertRemoteComic(comic) {
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

    private func upsertRemoteComic(_ comic: ComicBook) -> Bool {
        if let index = comics.firstIndex(where: { matchesExistingComic($0, comic) }) {
            let existing = comics[index]
            var merged = comic
            merged.id = existing.id
            if comic.sourceType == .opds {
                merged.totalPages = max(existing.totalPages, comic.totalPages)
                merged.remotePageCount = existing.remotePageCount ?? comic.remotePageCount
            }
            merged.currentPageIndex = min(max(existing.currentPageIndex, comic.currentPageIndex), max(0, merged.totalPages - 1))
            merged.hasBeenOpened = existing.hasBeenOpened || comic.hasBeenOpened || comic.currentPageIndex > 0
            merged.scrollProgress = existing.scrollProgress
            merged.scrollPageProgress = existing.scrollPageProgress
            merged.lastReadAt = existing.lastReadAt
            merged.isLocked = existing.isLocked
            merged.isOCREnabled = existing.isOCREnabled
            merged.isAITranslationEnabled = existing.isAITranslationEnabled
            merged.isAutoTranslationEnabled = existing.isAutoTranslationEnabled
            merged.isAutoOCRMagnificationEnabled = existing.isAutoOCRMagnificationEnabled
            merged.ocrTextScale = existing.ocrTextScale
            merged.ocrSafeAreaInset = existing.ocrSafeAreaInset
            merged.ocrMinimumTextHeight = existing.ocrMinimumTextHeight
            merged.aiTranslationModeRaw = existing.aiTranslationModeRaw
            merged.hasInitializedReadingPreset = existing.hasInitializedReadingPreset
            merged.readingDirectionRaw = existing.readingDirectionRaw
            merged.readingModeRaw = existing.readingModeRaw
            merged.pageTurnAnimationRaw = existing.pageTurnAnimationRaw
            merged.imageFitModeRaw = existing.imageFitModeRaw
            merged.scrollSpeedRaw = existing.scrollSpeedRaw
            merged.seriesID = existing.seriesID
            let didChange = merged != existing
            if didChange {
                comics[index] = merged
            }
            if comic.sourceType == .komga, existing.currentPageIndex > comic.currentPageIndex {
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
            removeLocalKomgaState(for: comic)
            HapticManager.shared.play(.success)
        } catch MediaSourceError.notFound {
            removeLocalKomgaState(for: comic)
            HapticManager.shared.play(.success)
        } catch {
            print("Komga 删除失败 \(comic.title): \(error.localizedDescription)")
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
            print("Komga 阅读进度同步失败 \(comic.title): \(error.localizedDescription)")
        }
    }

    private func upsertScannedComic(_ result: ComicManager.ImportResult, seriesID: UUID?) -> Bool {
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
            return changed
        }

        comics.append(ComicBook(
            title: result.title,
            bookmarkData: result.bookmarkData,
            totalPages: result.pagesCount,
            coverImagePath: result.coverImagePath,
            fileSize: result.fileSize,
            libraryPath: result.libraryPath,
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
