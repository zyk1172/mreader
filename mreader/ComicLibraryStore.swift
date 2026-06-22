import Foundation
import Combine

nonisolated private struct ComicLibrarySnapshot: Sendable {
    let comics: [ComicBook]
    let series: [ComicSeries]
}

private actor ComicLibraryDiskStore {
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

    func saveComics(_ comics: [ComicBook], to url: URL) {
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
            merged.currentPageIndex = min(existing.currentPageIndex, max(0, comic.totalPages - 1))
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
            merged.readingDirectionRaw = existing.readingDirectionRaw
            merged.readingModeRaw = existing.readingModeRaw
            merged.pageTurnAnimationRaw = existing.pageTurnAnimationRaw
            merged.imageFitModeRaw = existing.imageFitModeRaw
            merged.scrollSpeedRaw = existing.scrollSpeedRaw
            merged.seriesID = comic.seriesID ?? existing.seriesID
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
            smbPath: result.smbPath,
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
            }
        }
        comics.removeAll { $0.id == id }
        save()
    }

    func update(_ comic: ComicBook) {
        guard let index = comics.firstIndex(where: { $0.id == comic.id }) else { return }
        comics[index] = comic
        sortAndSave()
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
        HapticManager.shared.play(.success)
    }

    @discardableResult
    func syncKomgaSources() async -> Int {
        let results = await KomgaProvider.syncEnabledSources()
        var changed = false
        var syncedCount = 0
        for result in results {
            if let error = result.error {
                print("Komga 同步失败 \(result.source.name): \(error.localizedDescription)")
                let oldCount = comics.count
                comics.removeAll { $0.sourceType == .komga && $0.mediaSourceID == result.source.id }
                if comics.count != oldCount {
                    changed = true
                    print("Komga 源失去连接，已从书架移除 \(oldCount - comics.count) 本漫画: \(result.source.name)")
                }
                continue
            }
            syncedCount += result.comics.count
            if applyKomgaScan(result.comics, sourceID: result.source.id) {
                changed = true
            }
        }
        if changed {
            sortAndSave()
        }
        return syncedCount
    }

    func removeKomgaSource(id: UUID) {
        let oldCount = comics.count
        comics.removeAll { $0.sourceType == .komga && $0.mediaSourceID == id }
        if comics.count != oldCount {
            save()
        }
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
            let legacyRemoteType = ![ComicSourceType.local.rawValue, ComicSourceType.komga.rawValue].contains(comic.sourceTypeRaw)
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
        return false
    }

    private func applyKomgaScan(_ remoteComics: [ComicBook], sourceID: UUID) -> Bool {
        var changed = false
        let remoteIDs = Set(remoteComics.map(\.id))
        for comic in remoteComics {
            if upsertRemoteComic(comic) {
                changed = true
            }
        }
        let oldCount = comics.count
        comics.removeAll { comic in
            comic.sourceType == .komga && comic.mediaSourceID == sourceID && !remoteIDs.contains(comic.id)
        }
        return changed || comics.count != oldCount
    }

    private func upsertRemoteComic(_ comic: ComicBook) -> Bool {
        if let index = comics.firstIndex(where: { matchesExistingComic($0, comic) }) {
            let existing = comics[index]
            var merged = comic
            merged.id = existing.id
            merged.currentPageIndex = min(existing.currentPageIndex, max(0, comic.totalPages - 1))
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
            merged.readingDirectionRaw = existing.readingDirectionRaw
            merged.readingModeRaw = existing.readingModeRaw
            merged.pageTurnAnimationRaw = existing.pageTurnAnimationRaw
            merged.imageFitModeRaw = existing.imageFitModeRaw
            merged.scrollSpeedRaw = existing.scrollSpeedRaw
            let didChange = merged != existing
            if didChange {
                comics[index] = merged
            }
            return didChange
        }
        comics.append(comic)
        return true
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
            if comics[index].coverImagePath == nil || comics[index].coverImagePath != result.coverImagePath {
                comics[index].coverImagePath = result.coverImagePath
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
            if comics[index].smbPath != result.smbPath {
                comics[index].smbPath = result.smbPath
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
            smbPath: result.smbPath,
            chapterTypeRaw: result.chapterTypeRaw,
            chapterPath: result.chapterPath,
            seriesID: seriesID
        ))
        return true
    }

    private func save() {
        let snapshot = comics
        let url = libraryURL
        Task {
            await diskStore.saveComics(snapshot, to: url)
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
