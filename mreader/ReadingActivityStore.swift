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

nonisolated struct ReadingActivityDay: Codable, Identifiable, Sendable {
    var dateKey: String
    var seconds: Int
    var pages: Int
    var completedComicIDs: Set<UUID>
    var comicSeconds: [UUID: Int]
    var comicPages: [UUID: Int]

    var id: String { dateKey }

    init(
        dateKey: String,
        seconds: Int = 0,
        pages: Int = 0,
        completedComicIDs: Set<UUID> = [],
        comicSeconds: [UUID: Int] = [:],
        comicPages: [UUID: Int] = [:]
    ) {
        self.dateKey = dateKey
        self.seconds = seconds
        self.pages = pages
        self.completedComicIDs = completedComicIDs
        self.comicSeconds = comicSeconds
        self.comicPages = comicPages
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
        return min(max(comic.currentPageIndex + 1, 0), comic.totalPages)
    }

    static func fraction(for comic: ComicBook) -> Double {
        guard comic.totalPages > 0 else { return 0 }
        return min(max(Double(completedPages(for: comic)) / Double(comic.totalPages), 0), 1)
    }

    static func isFinished(_ comic: ComicBook) -> Bool {
        comic.totalPages > 0 && completedPages(for: comic) >= comic.totalPages
    }
}
