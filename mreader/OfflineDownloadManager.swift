import Foundation
import Combine
import SwiftUI

nonisolated struct OfflineComicRecord: Codable, Equatable, Sendable {
    let comicID: UUID
    let sourceID: UUID
    let sourceTypeRaw: String
    let remoteID: String
    let pageCount: Int
    let fileName: String?
    let completedAt: Date
}

nonisolated struct OfflineDownloadOwnerRegistry: Sendable {
    private var owners: [UUID: UUID] = [:]
    private var cancelledOwners: Set<UUID> = []

    mutating func begin(for comicID: UUID) -> UUID {
        let token = UUID()
        owners[comicID] = token
        cancelledOwners.remove(token)
        return token
    }

    mutating func cancel(for comicID: UUID) {
        if let token = owners[comicID] {
            cancelledOwners.insert(token)
        }
    }

    func isCurrentOwner(comicID: UUID, ownerToken: UUID) -> Bool {
        owners[comicID] == ownerToken
    }

    func canCommit(comicID: UUID, ownerToken: UUID) -> Bool {
        isCurrentOwner(comicID: comicID, ownerToken: ownerToken)
            && !cancelledOwners.contains(ownerToken)
    }

    mutating func finish(comicID: UUID, ownerToken: UUID) {
        guard owners[comicID] == ownerToken else { return }
        owners[comicID] = nil
        cancelledOwners.remove(ownerToken)
    }
}

nonisolated enum OfflinePageStore {
    static var storageURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MReaderOfflineComics", isDirectory: true)
    }

    private static var legacyStorageURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MReaderOfflineComics", isDirectory: true)
    }

    static func prepareStorage() {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: storageURL, withIntermediateDirectories: true)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var storageDirectory = storageURL
        try? storageDirectory.setResourceValues(resourceValues)
        migrateLegacyStorage(fileManager: fileManager)
    }

    static func reconcile(records: [UUID: OfflineComicRecord]) -> [UUID: OfflineComicRecord] {
        prepareStorage()
        return records.filter { _, record in
            guard hasMaterializedContent(record) else {
                remove(sourceID: record.sourceID, remoteID: record.remoteID)
                return false
            }
            return true
        }
    }

    static func data(for key: PageCacheKey) -> Data? {
        try? Data(contentsOf: pageURL(for: key))
    }

    static func store(_ data: Data, for key: PageCacheKey) throws {
        let url = pageURL(for: key)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func storeOPDSFile(_ sourceURL: URL, sourceID: UUID, publicationID: String) throws -> URL {
        prepareStorage()
        let directory = storageURL
            .appendingPathComponent(sourceID.uuidString, isDirectory: true)
            .appendingPathComponent(RemoteImageLoader.safeFileName(publicationID), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("book").appendingPathExtension(sourceURL.pathExtension)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return destination
    }

    static func opdsFile(sourceID: UUID, publicationID: String) -> URL? {
        let directory = storageURL
            .appendingPathComponent(sourceID.uuidString, isDirectory: true)
            .appendingPathComponent(RemoteImageLoader.safeFileName(publicationID), isDirectory: true)
        return try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).first(where: { $0.deletingPathExtension().lastPathComponent == "book" })
    }

    static func remove(sourceID: UUID, remoteID: String) {
        let directory = storageURL
            .appendingPathComponent(sourceID.uuidString, isDirectory: true)
            .appendingPathComponent(RemoteImageLoader.safeFileName(remoteID), isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
    }

    private static func hasMaterializedContent(_ record: OfflineComicRecord) -> Bool {
        switch record.sourceTypeRaw {
        case ComicSourceType.komga.rawValue:
            guard record.pageCount > 0 else { return false }
            return (0..<record.pageCount).allSatisfy { pageIndex in
                let url = pageURL(
                    for: PageCacheKey(
                        sourceID: record.sourceID,
                        bookID: record.remoteID,
                        pageIndex: pageIndex
                    )
                )
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else {
                    return false
                }
                return values.isRegularFile == true && (values.fileSize ?? 0) > 0
            }
        case ComicSourceType.opds.rawValue:
            guard let url = opdsFile(sourceID: record.sourceID, publicationID: record.remoteID),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else {
                return false
            }
            return values.isRegularFile == true && (values.fileSize ?? 0) > 0
        default:
            return false
        }
    }

    private static func pageURL(for key: PageCacheKey) -> URL {
        storageURL
            .appendingPathComponent(key.sourceID.uuidString, isDirectory: true)
            .appendingPathComponent(RemoteImageLoader.safeFileName(key.bookID), isDirectory: true)
            .appendingPathComponent("pages", isDirectory: true)
            .appendingPathComponent("\(key.pageIndex)")
            .appendingPathExtension("img")
    }

    private static func migrateLegacyStorage(fileManager: FileManager) {
        guard legacyStorageURL != storageURL,
              fileManager.fileExists(atPath: legacyStorageURL.path) else { return }
        try? fileManager.createDirectory(at: storageURL, withIntermediateDirectories: true)
        guard let items = try? fileManager.contentsOfDirectory(
            at: legacyStorageURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for item in items {
            let destination = storageURL.appendingPathComponent(item.lastPathComponent, isDirectory: item.hasDirectoryPath)
            if fileManager.fileExists(atPath: destination.path) {
                if treeSummary(item) == treeSummary(destination) {
                    try? fileManager.removeItem(at: item)
                }
                continue
            }
            do {
                try fileManager.copyItem(at: item, to: destination)
                guard treeSummary(item) == treeSummary(destination) else {
                    try? fileManager.removeItem(at: destination)
                    continue
                }
                try fileManager.removeItem(at: item)
            } catch {
                try? fileManager.removeItem(at: destination)
            }
        }

        if let remaining = try? fileManager.contentsOfDirectory(
            at: legacyStorageURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ), remaining.isEmpty {
            try? fileManager.removeItem(at: legacyStorageURL)
        }
    }

    private static func treeSummary(_ url: URL) -> (files: Int, bytes: Int64) {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return (0, 0) }
        var files = 0
        var bytes: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            files += 1
            bytes += Int64(values.fileSize ?? 0)
        }
        return (files, bytes)
    }
}

@MainActor
final class OfflineDownloadManager: ObservableObject {
    static let shared = OfflineDownloadManager()

    @Published private(set) var progress: [UUID: Double] = [:]
    @Published private(set) var activeComicIDs: Set<UUID> = []
    @Published private(set) var queuedComicIDs: Set<UUID> = []
    @Published private(set) var records: [UUID: OfflineComicRecord] = [:]

    private let recordsKey = "mreader.offlineComicRecords.v1"
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var reconciliationTask: Task<Void, Never>? = nil
    private var ownerRegistry = OfflineDownloadOwnerRegistry()
    private var pendingRemovals: Set<UUID> = []
    private var queue: [ComicBook] = []
    private let maximumConcurrentDownloads = 1

    private init() {
        if let data = UserDefaults.standard.data(forKey: recordsKey),
           let values = try? JSONDecoder().decode([OfflineComicRecord].self, from: data) {
            records = Dictionary(uniqueKeysWithValues: values.map { ($0.comicID, $0) })
        }
    }

    func isAvailableOffline(_ comic: ComicBook) -> Bool {
        records[comic.id] != nil
    }

    func download(_ comic: ComicBook) {
        guard comic.sourceType == .komga || comic.sourceType == .opds,
              tasks[comic.id] == nil,
              !queuedComicIDs.contains(comic.id) else { return }
        HapticManager.shared.play(.medium)
        queue.append(comic)
        queuedComicIDs.insert(comic.id)
        progress[comic.id] = 0
        processQueue()
    }

    private func processQueue() {
        guard tasks.count < maximumConcurrentDownloads, !queue.isEmpty else { return }
        let comic = queue.removeFirst()
        queuedComicIDs.remove(comic.id)
        activeComicIDs.insert(comic.id)
        let ownerToken = ownerRegistry.begin(for: comic.id)
        tasks[comic.id] = Task { [weak self] in
            await self?.runDownload(comic, ownerToken: ownerToken)
        }
    }

    func cancel(_ comic: ComicBook) {
        queue.removeAll { $0.id == comic.id }
        queuedComicIDs.remove(comic.id)
        progress[comic.id] = nil
        guard tasks[comic.id] != nil else {
            activeComicIDs.remove(comic.id)
            return
        }
        ownerRegistry.cancel(for: comic.id)
        tasks[comic.id]?.cancel()
    }

    func remove(_ comic: ComicBook) {
        if tasks[comic.id] != nil {
            pendingRemovals.insert(comic.id)
            records[comic.id] = nil
            persistRecords()
            cancel(comic)
            return
        }
        queue.removeAll { $0.id == comic.id }
        queuedComicIDs.remove(comic.id)
        activeComicIDs.remove(comic.id)
        progress[comic.id] = nil
        guard let record = records.removeValue(forKey: comic.id) else {
            if let sourceID = comic.mediaSourceID,
               let remoteID = comic.komgaBookID ?? comic.remoteCoverID {
                OfflinePageStore.remove(sourceID: sourceID, remoteID: remoteID)
            }
            HapticManager.shared.play(.heavy)
            return
        }
        OfflinePageStore.remove(sourceID: record.sourceID, remoteID: record.remoteID)
        persistRecords()
        HapticManager.shared.play(.heavy)
    }

    func removeOrphanedRecords(validComicIDs: Set<UUID>) {
        let orphaned = records.values.filter { !validComicIDs.contains($0.comicID) }
        guard !orphaned.isEmpty else { return }
        for record in orphaned {
            OfflinePageStore.remove(sourceID: record.sourceID, remoteID: record.remoteID)
            records[record.comicID] = nil
        }
        persistRecords()
    }

    func reconcileStorage() {
        guard reconciliationTask == nil else { return }
        let snapshot = records
        let scanTask = Task.detached(priority: .utility) {
            OfflinePageStore.reconcile(records: snapshot)
        }
        reconciliationTask = Task { @MainActor [weak self] in
            let reconciled = await scanTask.value
            guard let self else { return }
            for (comicID, snapshotRecord) in snapshot {
                guard records[comicID] == snapshotRecord, reconciled[comicID] == nil else { continue }
                records[comicID] = nil
            }
            if records != snapshot {
                persistRecords()
            }
            reconciliationTask = nil
        }
    }

    private func runDownload(_ comic: ComicBook, ownerToken: UUID) async {
        do {
            let record: OfflineComicRecord
            switch comic.sourceType {
            case .komga:
                record = try await downloadKomga(comic)
            case .opds:
                record = try await downloadOPDS(comic)
            case .local:
                return
            }
            try Task.checkCancellation()
            guard ownerRegistry.canCommit(comicID: comic.id, ownerToken: ownerToken) else {
                throw CancellationError()
            }
            if pendingRemovals.remove(comic.id) != nil {
                OfflinePageStore.remove(sourceID: record.sourceID, remoteID: record.remoteID)
                records[comic.id] = nil
                persistRecords()
            } else {
                records[comic.id] = record
                persistRecords()
                progress[comic.id] = 1
                HapticManager.shared.play(.success)
            }
        } catch is CancellationError {
            cleanupPartialDownload(for: comic)
            HapticManager.shared.play(.warning)
        } catch {
            cleanupPartialDownload(for: comic)
            print("MReader offline download failed comic=\(comic.title) reason=\(error.localizedDescription)")
            HapticManager.shared.play(.error)
        }

        guard ownerRegistry.isCurrentOwner(comicID: comic.id, ownerToken: ownerToken) else { return }
        if pendingRemovals.remove(comic.id) != nil {
            records[comic.id] = nil
            persistRecords()
            cleanupPartialDownload(for: comic)
        }
        ownerRegistry.finish(comicID: comic.id, ownerToken: ownerToken)
        activeComicIDs.remove(comic.id)
        tasks[comic.id] = nil
        progress[comic.id] = nil
        processQueue()
    }

    private func cleanupPartialDownload(for comic: ComicBook) {
        guard let sourceID = comic.mediaSourceID,
              let remoteID = comic.komgaBookID ?? comic.remoteCoverID else { return }
        OfflinePageStore.remove(sourceID: sourceID, remoteID: remoteID)
    }

    private func downloadKomga(_ comic: ComicBook) async throws -> OfflineComicRecord {
        guard let sourceID = comic.mediaSourceID,
              let bookID = comic.komgaBookID else { throw MediaSourceError.invalidResponse }
        let pageCount = max(comic.remotePageCount ?? comic.totalPages, 0)
        guard pageCount > 0 else { throw MediaSourceError.notFound }
        for pageIndex in 0..<pageCount {
            try Task.checkCancellation()
            let key = PageCacheKey(sourceID: sourceID, bookID: bookID, pageIndex: pageIndex)
            guard let data = await RemotePageCache.shared.data(for: key, priority: .prefetch), !data.isEmpty else {
                throw MediaSourceError.imageLoadFailed
            }
            try OfflinePageStore.store(data, for: key)
            progress[comic.id] = Double(pageIndex + 1) / Double(pageCount)
        }
        return OfflineComicRecord(
            comicID: comic.id,
            sourceID: sourceID,
            sourceTypeRaw: ComicSourceType.komga.rawValue,
            remoteID: bookID,
            pageCount: pageCount,
            fileName: nil,
            completedAt: Date()
        )
    }

    private func downloadOPDS(_ comic: ComicBook) async throws -> OfflineComicRecord {
        guard let sourceID = comic.mediaSourceID,
              let publicationID = comic.remoteCoverID else { throw MediaSourceError.invalidResponse }
        let downloaded = try await OPDSProvider.downloadFile(for: comic)
        let destination = try OfflinePageStore.storeOPDSFile(
            downloaded,
            sourceID: sourceID,
            publicationID: publicationID
        )
        progress[comic.id] = 1
        return OfflineComicRecord(
            comicID: comic.id,
            sourceID: sourceID,
            sourceTypeRaw: ComicSourceType.opds.rawValue,
            remoteID: publicationID,
            pageCount: max(comic.totalPages, 1),
            fileName: destination.lastPathComponent,
            completedAt: Date()
        )
    }

    private func persistRecords() {
        let values = records.values.sorted { $0.completedAt < $1.completedAt }
        if let data = try? JSONEncoder().encode(values) {
            UserDefaults.standard.set(data, forKey: recordsKey)
        }
    }
}
