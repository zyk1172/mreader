import Foundation
import Combine
import SwiftUI

nonisolated struct OfflineComicRecord: Codable, Sendable {
    let comicID: UUID
    let sourceID: UUID
    let sourceTypeRaw: String
    let remoteID: String
    let pageCount: Int
    let fileName: String?
    let completedAt: Date
}

nonisolated enum OfflinePageStore {
    private static var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MReaderOfflineComics", isDirectory: true)
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
        let directory = root
            .appendingPathComponent(sourceID.uuidString, isDirectory: true)
            .appendingPathComponent(RemoteImageLoader.safeFileName(publicationID), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("book").appendingPathExtension(sourceURL.pathExtension)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return destination
    }

    static func opdsFile(sourceID: UUID, publicationID: String) -> URL? {
        let directory = root
            .appendingPathComponent(sourceID.uuidString, isDirectory: true)
            .appendingPathComponent(RemoteImageLoader.safeFileName(publicationID), isDirectory: true)
        return try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).first(where: { $0.deletingPathExtension().lastPathComponent == "book" })
    }

    static func remove(sourceID: UUID, remoteID: String) {
        let directory = root
            .appendingPathComponent(sourceID.uuidString, isDirectory: true)
            .appendingPathComponent(RemoteImageLoader.safeFileName(remoteID), isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
    }

    private static func pageURL(for key: PageCacheKey) -> URL {
        root
            .appendingPathComponent(key.sourceID.uuidString, isDirectory: true)
            .appendingPathComponent(RemoteImageLoader.safeFileName(key.bookID), isDirectory: true)
            .appendingPathComponent("pages", isDirectory: true)
            .appendingPathComponent("\(key.pageIndex)")
            .appendingPathExtension("img")
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
        tasks[comic.id] = Task {
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
                records[comic.id] = record
                persistRecords()
                progress[comic.id] = 1
                HapticManager.shared.play(.success)
            } catch is CancellationError {
                HapticManager.shared.play(.warning)
            } catch {
                print("MReader offline download failed comic=\(comic.title) reason=\(error.localizedDescription)")
                HapticManager.shared.play(.error)
            }
            activeComicIDs.remove(comic.id)
            tasks[comic.id] = nil
            processQueue()
        }
    }

    func cancel(_ comic: ComicBook) {
        queue.removeAll { $0.id == comic.id }
        queuedComicIDs.remove(comic.id)
        tasks[comic.id]?.cancel()
        tasks[comic.id] = nil
        activeComicIDs.remove(comic.id)
        progress[comic.id] = nil
        processQueue()
    }

    func remove(_ comic: ComicBook) {
        cancel(comic)
        guard let record = records.removeValue(forKey: comic.id) else {
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
