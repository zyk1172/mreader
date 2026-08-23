import Foundation
import SwiftUI
import Combine

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
    /// Per-device stable identities retained for iCloud merge. Local UI totals continue
    /// using UUID dictionaries, while sync avoids double-counting a merged snapshot.
    var syncedCompletedComicKeys: Set<String>
    var syncedComicSeconds: [String: Int]
    var syncedComicPages: [String: Int]
    var syncedDeviceSeconds: [String: Int]
    var syncedDevicePages: [String: Int]

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
        syncedDevicePages: [String: Int] = [:]
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
    }

    private enum CodingKeys: String, CodingKey {
        case dateKey, seconds, pages, completedComicIDs, comicSeconds, comicPages
        case syncedCompletedComicKeys, syncedComicSeconds, syncedComicPages
        case syncedDeviceSeconds, syncedDevicePages
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
    }
}

@MainActor
final class ReadingActivityStore: ObservableObject {
    static let shared = ReadingActivityStore()

    @Published private(set) var days: [ReadingActivityDay] = []

    private let storageURL: URL
    private let calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        storageURL = support.appendingPathComponent("reading_activity.json")
        load()
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

        days[index].seconds = min(86_400, days[index].seconds + increment.seconds)
        days[index].pages += increment.pages
        days[index].comicSeconds[comicID, default: 0] += increment.seconds
        days[index].comicPages[comicID, default: 0] += increment.pages
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
        for incoming in incomingDays {
            guard var existing = merged[incoming.dateKey] else {
                merged[incoming.dateKey] = incoming
                continue
            }
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
            for (deviceID, seconds) in incoming.syncedDeviceSeconds {
                existing.syncedDeviceSeconds[deviceID] = max(existing.syncedDeviceSeconds[deviceID] ?? 0, seconds)
            }
            for (deviceID, pages) in incoming.syncedDevicePages {
                existing.syncedDevicePages[deviceID] = max(existing.syncedDevicePages[deviceID] ?? 0, pages)
            }
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

        for incoming in incomingDays {
            var existing = merged[incoming.dateKey] ?? ReadingActivityDay(dateKey: incoming.dateKey)
            existing.seconds = max(existing.seconds, incoming.seconds)
            existing.pages = max(existing.pages, incoming.pages)
            existing.syncedCompletedComicKeys.formUnion(incoming.completedComicKeys)
            for (key, seconds) in incoming.comicSeconds {
                existing.syncedComicSeconds[key] = max(existing.syncedComicSeconds[key] ?? 0, seconds)
            }
            for (key, pages) in incoming.comicPages {
                existing.syncedComicPages[key] = max(existing.syncedComicPages[key] ?? 0, pages)
            }
            for (deviceID, seconds) in incoming.deviceSeconds {
                existing.syncedDeviceSeconds[deviceID] = max(existing.syncedDeviceSeconds[deviceID] ?? 0, seconds)
            }
            for (deviceID, pages) in incoming.devicePages {
                existing.syncedDevicePages[deviceID] = max(existing.syncedDevicePages[deviceID] ?? 0, pages)
            }
            existing.seconds = max(existing.seconds, existing.syncedDeviceSeconds.values.reduce(0, +))
            existing.pages = max(existing.pages, existing.syncedDevicePages.values.reduce(0, +))

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

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([ReadingActivityDay].self, from: data) else {
            return
        }
        days = decoded.sorted { $0.dateKey < $1.dateKey }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(days)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            print("保存阅读统计失败: \(error.localizedDescription)")
        }
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
