import Foundation
import SwiftUI
import Combine
import UIKit
import os

nonisolated struct ReadingActivityIncrement: Equatable, Sendable {
    let seconds: Int
    let pages: Int
}

nonisolated enum ReadingActivityAccumulator {
    static func increment(
        previousDate: Date,
        now: Date,
        previousPageIndex: Int,
        currentPageIndex: Int
    ) -> ReadingActivityIncrement {
        let elapsed = max(0, Int(now.timeIntervalSince(previousDate).rounded(.down)))
        return ReadingActivityIncrement(
            seconds: min(elapsed, 60),
            pages: min(max(currentPageIndex - previousPageIndex, 0), 20)
        )
    }
}

nonisolated struct ReadingActivityDay: Codable, Identifiable, Equatable, Sendable {
    var dateKey: String
    var seconds: Int
    var pages: Int
    var completedComicIDs: Set<UUID>
    var comicSeconds: [UUID: Int]
    var comicPages: [UUID: Int]
    /// Per-device stable identities retained for iCloud merge. `seconds` and `pages`
    /// are derived from these counters after a v2 merge, so a later local record can
    /// update only the current device rather than re-attributing the aggregate.
    var syncedCompletedComicKeys: Set<String>
    var syncedComicSeconds: [String: Int]
    var syncedComicPages: [String: Int]
    var syncedDeviceSeconds: [String: Int]
    var syncedDevicePages: [String: Int]
    /// Cumulative counters for the current device, keyed by the local comic ID.
    /// These are converted to stable identities only when an iCloud payload is built.
    var localDeviceComicSeconds: [UUID: Int]
    var localDeviceComicPages: [UUID: Int]

    var id: String { dateKey }

    init(
        dateKey: String,
        seconds: Int = 0,
        pages: Int = 0,
        completedComicIDs: Set<UUID> = [],
        comicSeconds: [UUID: Int] = [:],
        comicPages: [UUID: Int] = [:],
        syncedCompletedComicKeys: Set<String> = [],
        syncedComicSeconds: [String: Int] = [:],
        syncedComicPages: [String: Int] = [:],
        syncedDeviceSeconds: [String: Int] = [:],
        syncedDevicePages: [String: Int] = [:],
        localDeviceComicSeconds: [UUID: Int] = [:],
        localDeviceComicPages: [UUID: Int] = [:]
    ) {
        self.dateKey = dateKey
        self.seconds = seconds
        self.pages = pages
        self.completedComicIDs = completedComicIDs
        self.comicSeconds = comicSeconds
        self.comicPages = comicPages
        self.syncedCompletedComicKeys = syncedCompletedComicKeys
        self.syncedComicSeconds = syncedComicSeconds
        self.syncedComicPages = syncedComicPages
        self.syncedDeviceSeconds = syncedDeviceSeconds
        self.syncedDevicePages = syncedDevicePages
        self.localDeviceComicSeconds = localDeviceComicSeconds
        self.localDeviceComicPages = localDeviceComicPages
    }

    private enum CodingKeys: String, CodingKey {
        case dateKey, seconds, pages, completedComicIDs, comicSeconds, comicPages
        case syncedCompletedComicKeys, syncedComicSeconds, syncedComicPages
        case syncedDeviceSeconds, syncedDevicePages
        case localDeviceComicSeconds, localDeviceComicPages
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dateKey = try container.decode(String.self, forKey: .dateKey)
        seconds = try container.decodeIfPresent(Int.self, forKey: .seconds) ?? 0
        pages = try container.decodeIfPresent(Int.self, forKey: .pages) ?? 0
        completedComicIDs = try container.decodeIfPresent(Set<UUID>.self, forKey: .completedComicIDs) ?? []
        comicSeconds = try container.decodeIfPresent([UUID: Int].self, forKey: .comicSeconds) ?? [:]
        comicPages = try container.decodeIfPresent([UUID: Int].self, forKey: .comicPages) ?? [:]
        syncedCompletedComicKeys = try container.decodeIfPresent(Set<String>.self, forKey: .syncedCompletedComicKeys) ?? []
        syncedComicSeconds = try container.decodeIfPresent([String: Int].self, forKey: .syncedComicSeconds) ?? [:]
        syncedComicPages = try container.decodeIfPresent([String: Int].self, forKey: .syncedComicPages) ?? [:]
        syncedDeviceSeconds = try container.decodeIfPresent([String: Int].self, forKey: .syncedDeviceSeconds) ?? [:]
        syncedDevicePages = try container.decodeIfPresent([String: Int].self, forKey: .syncedDevicePages) ?? [:]
        localDeviceComicSeconds = try container.decodeIfPresent([UUID: Int].self, forKey: .localDeviceComicSeconds) ?? [:]
        localDeviceComicPages = try container.decodeIfPresent([UUID: Int].self, forKey: .localDeviceComicPages) ?? [:]
    }
}

@MainActor
final class ReadingActivityStore: ObservableObject {
    static let shared = ReadingActivityStore()

    @Published private(set) var days: [ReadingActivityDay] = []

    /// 写盘防抖窗口：连续 record / merge 只落盘一次。
    private static let writeDebounceInterval: TimeInterval = 0.8

    /// 观察者在 box 析构时自动注销，避免在 deinit 里触碰主线程隔离的状态。
    nonisolated private final class NotificationObserverBox {
        var token: NSObjectProtocol?
        deinit {
            if let token {
                NotificationCenter.default.removeObserver(token)
            }
        }
    }

    private let storageURL: URL
    private let calendar: Calendar
    /// 串行后台队列：JSON 编解码与读写盘全部在这里，绝不在主线程做同步 IO（审查 #8）。
    private let ioQueue = DispatchQueue(label: "com.mreader.reading-activity.io", qos: .utility)
    /// 磁盘快照是否已经应用。**在它变成 true 之前绝不落盘**：否则会把"还没包含
    /// 磁盘历史"的快照写回去，用户在这一瞬间退出就会永久丢掉旧统计（审查 #6）。
    private var isLoadedFromDisk = false
    /// 读盘完成前累积的 mutation，读盘结束后统一落盘一次。
    private var hasPendingWrite = false
    private var pendingWriteWorkItem: DispatchWorkItem?
    private let backgroundObserverBox = NotificationObserverBox()

    init(calendar: Calendar = .current, storageURL: URL? = nil) {
        self.calendar = calendar
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.storageURL = storageURL ?? support.appendingPathComponent("reading_activity.json")
        observeAppBackgrounding()
        startLoading()
    }

    /// 启动路径不再阻塞主线程：读盘 + 解码在后台串行队列完成，结果回到 MainActor 应用。
    private func startLoading() {
        let url = storageURL
        ioQueue.async { [weak self] in
            let loaded = Self.readDays(from: url)
            Task { @MainActor [weak self] in
                self?.finishLoading(with: loaded)
            }
        }
    }

    /// 读盘完成：先合并磁盘历史，再统一落盘一次。
    /// 期间发生的 mutation 只会累积成一次写入，不会用旧快照覆盖磁盘。
    private func finishLoading(with loaded: [ReadingActivityDay]?) {
        isLoadedFromDisk = true
        if let loaded, !loaded.isEmpty {
            if hasPendingWrite {
                // 读盘完成前已经产生新数据：合并而不是覆盖。
                mergeSyncedDays(loaded)
            } else {
                var normalized = loaded
                for index in normalized.indices {
                    normalizeDeviceCounters(&normalized[index])
                }
                days = normalized.sorted { $0.dateKey < $1.dateKey }
            }
        }
        flushPendingWriteIfNeeded()
    }

    /// 立即把待写入的快照落盘（进入后台、或测试需要确定性落盘时调用）。
    func flushPendingWrites() {
        flushPendingWriteIfNeeded()
    }

    private func observeAppBackgrounding() {
        // 防抖窗口内的改动不能在系统挂起时丢掉。
        backgroundObserverBox.token = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.flushPendingWriteIfNeeded()
            }
        }
    }

    nonisolated private static func readDays(from url: URL) -> [ReadingActivityDay]? {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([ReadingActivityDay].self, from: data) else {
            return nil
        }
        return decoded
    }

    nonisolated private static func writeDays(_ days: [ReadingActivityDay], to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(days)
            try data.write(to: url, options: .atomic)
        } catch {
            MReaderLog.reader.error("saving reading activity failed reason=\(MReaderLog.describe(error), privacy: .public)")
        }
    }

    private func flushPendingWriteIfNeeded() {
        pendingWriteWorkItem?.cancel()
        pendingWriteWorkItem = nil
        // 读盘完成前绝不落盘，即使被显式 flush：写回"还没包含磁盘历史"的快照
        // 会让用户在两步之间退出时永久丢掉旧统计（审查 #6）。
        guard isLoadedFromDisk, hasPendingWrite else { return }
        hasPendingWrite = false
        // 只在主线程取快照；编码与写盘在串行后台队列执行。
        let snapshot = days
        let url = storageURL
        ioQueue.async {
            Self.writeDays(snapshot, to: url)
        }
    }

    private func scheduleWrite() {
        hasPendingWrite = true
        // 读盘完成前只累积，不落盘。
        guard isLoadedFromDisk else { return }
        pendingWriteWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.flushPendingWriteIfNeeded()
            }
        }
        pendingWriteWorkItem = work
        ioQueue.asyncAfter(deadline: .now() + Self.writeDebounceInterval, execute: work)
    }

    func record(
        comicID: UUID,
        previousDate: Date,
        now: Date,
        previousPageIndex: Int,
        currentPageIndex: Int,
        completed: Bool
    ) {
        let increment = ReadingActivityAccumulator.increment(
            previousDate: previousDate,
            now: now,
            previousPageIndex: previousPageIndex,
            currentPageIndex: currentPageIndex
        )
        guard increment.seconds > 0 || increment.pages > 0 || completed else { return }

        let key = Self.dateKey(for: now, calendar: calendar)
        let index: Int
        if let existing = days.firstIndex(where: { $0.dateKey == key }) {
            index = existing
        } else {
            days.append(ReadingActivityDay(dateKey: key))
            index = days.count - 1
        }

        normalizeDeviceCounters(&days[index])
        let deviceID = ICloudSyncDeviceIdentity.current
        days[index].syncedDeviceSeconds[deviceID, default: 0] += increment.seconds
        days[index].syncedDevicePages[deviceID, default: 0] += increment.pages
        days[index].seconds = days[index].syncedDeviceSeconds.values.reduce(0, +)
        days[index].pages = days[index].syncedDevicePages.values.reduce(0, +)
        days[index].comicSeconds[comicID, default: 0] += increment.seconds
        days[index].comicPages[comicID, default: 0] += increment.pages
        days[index].localDeviceComicSeconds[comicID, default: 0] += increment.seconds
        days[index].localDeviceComicPages[comicID, default: 0] += increment.pages
        if completed {
            days[index].completedComicIDs.insert(comicID)
        }
        days.sort { $0.dateKey < $1.dateKey }
        save()
    }

    func hasActivity(for comicID: UUID) -> Bool {
        days.contains {
            ($0.comicSeconds[comicID] ?? 0) > 0 ||
            ($0.comicPages[comicID] ?? 0) > 0 ||
            $0.completedComicIDs.contains(comicID)
        }
    }

    func totalSeconds(for comicID: UUID) -> Int {
        days.reduce(0) { $0 + ($1.comicSeconds[comicID] ?? 0) }
    }

    func totalPages(for comicID: UUID) -> Int {
        days.reduce(0) { $0 + ($1.comicPages[comicID] ?? 0) }
    }

    func mergeSyncedDays(_ incomingDays: [ReadingActivityDay]) {
        var merged = Dictionary(uniqueKeysWithValues: days.map { ($0.dateKey, $0) })
        for rawIncoming in incomingDays {
            var incoming = rawIncoming
            normalizeDeviceCounters(&incoming)
            guard var existing = merged[incoming.dateKey] else {
                merged[incoming.dateKey] = incoming
                continue
            }
            normalizeDeviceCounters(&existing)
            existing.seconds = max(existing.seconds, incoming.seconds)
            existing.pages = max(existing.pages, incoming.pages)
            existing.completedComicIDs.formUnion(incoming.completedComicIDs)
            for (comicID, seconds) in incoming.comicSeconds {
                existing.comicSeconds[comicID] = max(existing.comicSeconds[comicID] ?? 0, seconds)
            }
            for (comicID, pages) in incoming.comicPages {
                existing.comicPages[comicID] = max(existing.comicPages[comicID] ?? 0, pages)
            }
            existing.syncedCompletedComicKeys.formUnion(incoming.syncedCompletedComicKeys)
            for (key, seconds) in incoming.syncedComicSeconds {
                existing.syncedComicSeconds[key] = max(existing.syncedComicSeconds[key] ?? 0, seconds)
            }
            for (key, pages) in incoming.syncedComicPages {
                existing.syncedComicPages[key] = max(existing.syncedComicPages[key] ?? 0, pages)
            }
            for (comicID, seconds) in incoming.localDeviceComicSeconds {
                existing.localDeviceComicSeconds[comicID] = max(existing.localDeviceComicSeconds[comicID] ?? 0, seconds)
            }
            for (comicID, pages) in incoming.localDeviceComicPages {
                existing.localDeviceComicPages[comicID] = max(existing.localDeviceComicPages[comicID] ?? 0, pages)
            }
            for (deviceID, seconds) in incoming.syncedDeviceSeconds {
                existing.syncedDeviceSeconds[deviceID] = max(existing.syncedDeviceSeconds[deviceID] ?? 0, seconds)
            }
            for (deviceID, pages) in incoming.syncedDevicePages {
                existing.syncedDevicePages[deviceID] = max(existing.syncedDevicePages[deviceID] ?? 0, pages)
            }
            existing.seconds = existing.syncedDeviceSeconds.values.reduce(0, +)
            existing.pages = existing.syncedDevicePages.values.reduce(0, +)
            merged[incoming.dateKey] = existing
        }
        let updated = merged.values.sorted { $0.dateKey < $1.dateKey }
        guard updated != days else { return }
        days = updated
        save()
    }

    func mergeSyncedDays(
        _ incomingDays: [ICloudReadingActivityDay],
        comics: [ComicBook],
        sources: [MediaSource] = []
    ) {
        var merged = Dictionary(uniqueKeysWithValues: days.map { ($0.dateKey, $0) })
        let sourcesByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        let identityByComicID: [UUID: String] = Dictionary(uniqueKeysWithValues: comics.compactMap { comic in
            guard let identity = ComicSyncIdentity.v2Value(for: comic, sourcesByID: sourcesByID) else { return nil }
            return (comic.id, identity)
        })
        let comicIDByIdentity = Dictionary(uniqueKeysWithValues: identityByComicID.map { ($0.value, $0.key) })
        let currentDeviceID = ICloudSyncDeviceIdentity.current

        for incoming in incomingDays {
            var existing = merged[incoming.dateKey] ?? ReadingActivityDay(dateKey: incoming.dateKey)
            normalizeDeviceCounters(&existing)
            existing.syncedCompletedComicKeys.formUnion(incoming.completedComicKeys)
            for (key, seconds) in incoming.comicSeconds {
                existing.syncedComicSeconds[key] = max(existing.syncedComicSeconds[key] ?? 0, seconds)
            }
            for (key, pages) in incoming.comicPages {
                existing.syncedComicPages[key] = max(existing.syncedComicPages[key] ?? 0, pages)
            }
            for (key, seconds) in incoming.comicSeconds {
                guard ICloudActivityIdentity.deviceID(from: key) == currentDeviceID,
                      let identity = ICloudActivityIdentity.comicIdentity(from: key),
                      let comicID = comicIDByIdentity[identity] else { continue }
                existing.localDeviceComicSeconds[comicID] = max(existing.localDeviceComicSeconds[comicID] ?? 0, seconds)
            }
            for (key, pages) in incoming.comicPages {
                guard ICloudActivityIdentity.deviceID(from: key) == currentDeviceID,
                      let identity = ICloudActivityIdentity.comicIdentity(from: key),
                      let comicID = comicIDByIdentity[identity] else { continue }
                existing.localDeviceComicPages[comicID] = max(existing.localDeviceComicPages[comicID] ?? 0, pages)
            }
            let incomingDeviceSeconds = incoming.deviceSeconds.isEmpty && incoming.seconds > 0
                ? ["legacy-v1": incoming.seconds]
                : incoming.deviceSeconds
            let incomingDevicePages = incoming.devicePages.isEmpty && incoming.pages > 0
                ? ["legacy-v1": incoming.pages]
                : incoming.devicePages
            for (deviceID, seconds) in incomingDeviceSeconds {
                existing.syncedDeviceSeconds[deviceID] = max(existing.syncedDeviceSeconds[deviceID] ?? 0, seconds)
            }
            for (deviceID, pages) in incomingDevicePages {
                existing.syncedDevicePages[deviceID] = max(existing.syncedDevicePages[deviceID] ?? 0, pages)
            }
            existing.seconds = existing.syncedDeviceSeconds.values.reduce(0, +)
            existing.pages = existing.syncedDevicePages.values.reduce(0, +)

            for comic in comics {
                guard let identity = identityByComicID[comic.id] else { continue }
                let matchingSeconds = existing.syncedComicSeconds
                    .filter { ICloudActivityIdentity.comicIdentity(from: $0.key) == identity }
                    .values
                    .reduce(0, +)
                let matchingPages = existing.syncedComicPages
                    .filter { ICloudActivityIdentity.comicIdentity(from: $0.key) == identity }
                    .values
                    .reduce(0, +)
                existing.comicSeconds[comic.id] = max(existing.comicSeconds[comic.id] ?? 0, matchingSeconds)
                existing.comicPages[comic.id] = max(existing.comicPages[comic.id] ?? 0, matchingPages)
                if existing.syncedCompletedComicKeys.contains(where: {
                    ICloudActivityIdentity.comicIdentity(from: $0) == identity
                }) {
                    existing.completedComicIDs.insert(comic.id)
                }
            }
            merged[incoming.dateKey] = existing
        }

        let updated = merged.values.sorted { $0.dateKey < $1.dateKey }
        guard updated != days else { return }
        days = updated
        save()
    }

    nonisolated static func dateKey(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private func normalizeDeviceCounters(_ day: inout ReadingActivityDay) {
        if day.syncedDeviceSeconds.isEmpty, day.seconds > 0 {
            day.syncedDeviceSeconds[ICloudSyncDeviceIdentity.legacyDeviceID] = day.seconds
        }
        if day.syncedDevicePages.isEmpty, day.pages > 0 {
            day.syncedDevicePages[ICloudSyncDeviceIdentity.legacyDeviceID] = day.pages
        }
        day.seconds = day.syncedDeviceSeconds.values.reduce(0, +)
        day.pages = day.syncedDevicePages.values.reduce(0, +)
    }

    private func save() {
        scheduleWrite()
    }
}

nonisolated enum ComicReadingProgress {
    static func completedPages(for comic: ComicBook) -> Int {
        guard comic.hasBeenOpened, comic.totalPages > 0 else { return 0 }
        return min(max(comic.furthestPageIndex + 1, 0), comic.totalPages)
    }

    static func fraction(for comic: ComicBook) -> Double {
        guard comic.totalPages > 0 else { return 0 }
        return min(max(Double(completedPages(for: comic)) / Double(comic.totalPages), 0), 1)
    }

    static func isFinished(_ comic: ComicBook) -> Bool {
        comic.totalPages > 0 && completedPages(for: comic) >= comic.totalPages
    }
}
