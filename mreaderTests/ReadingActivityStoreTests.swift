import Foundation
import Testing
@testable import mreader

@MainActor
struct ReadingActivityStoreTests {
    @Test
    func legacyAggregateUsesSharedSyntheticDeviceBucket() throws {
        let comicID = UUID()
        let legacyDay = ReadingActivityDay(
            dateKey: "2026-08-24",
            seconds: 30,
            pages: 3,
            comicSeconds: [comicID: 30],
            comicPages: [comicID: 3]
        )
        let identities = [comicID: "local:Series/Book.cbz"]
        let deviceADay = ICloudReadingActivityDay(
            local: legacyDay,
            deviceID: "device-a",
            comicIdentities: identities
        )
        let deviceBDay = ICloudReadingActivityDay(
            local: legacyDay,
            deviceID: "device-b",
            comicIdentities: identities
        )

        let merged = ICloudMetadataMergePolicy.merge(
            local: ICloudMetadataPayload(deviceID: "device-b", comics: [], activityDays: [deviceBDay]),
            remote: ICloudMetadataPayload(deviceID: "device-a", comics: [], activityDays: [deviceADay])
        )

        let result = try #require(merged.activityDays.first)
        #expect(result.seconds == 30)
        #expect(result.pages == 3)
        #expect(result.deviceSeconds == [ICloudSyncDeviceIdentity.legacyDeviceID: 30])
        #expect(result.devicePages == [ICloudSyncDeviceIdentity.legacyDeviceID: 3])
        #expect(result.comicSeconds == [
            "legacy-v1#legacy-comic:\(comicID.uuidString)": 30
        ])
        #expect(result.comicPages == [
            "legacy-v1#legacy-comic:\(comicID.uuidString)": 3
        ])
    }

    @Test
    func recordingAfterRemoteMergeAdvancesOnlyCurrentComicCounter() throws {
        let deviceIDKey = "mreader.icloudSync.deviceID"
        let previousDeviceID = UserDefaults.standard.string(forKey: deviceIDKey)
        UserDefaults.standard.set("device-b", forKey: deviceIDKey)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MReaderReadingActivity-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("reading_activity.json")
        defer {
            if let previousDeviceID {
                UserDefaults.standard.set(previousDeviceID, forKey: deviceIDKey)
            } else {
                UserDefaults.standard.removeObject(forKey: deviceIDKey)
            }
            try? FileManager.default.removeItem(at: directory)
        }

        let comic = ComicBook(
            title: "Book",
            bookmarkData: Data(),
            totalPages: 10,
            libraryRelativePath: "Series/Book.cbz"
        )
        let identity = "local:Series/Book.cbz"
        let store = ReadingActivityStore(storageURL: storageURL)
        store.mergeSyncedDays(
            [
                ICloudReadingActivityDay(
                    dateKey: "1970-01-02",
                    seconds: 50,
                    pages: 5,
                    comicSeconds: [
                        "device-a#\(identity)": 30,
                        "device-b#\(identity)": 20
                    ],
                    comicPages: [
                        "device-a#\(identity)": 3,
                        "device-b#\(identity)": 2
                    ],
                    deviceSeconds: ["device-a": 30, "device-b": 20],
                    devicePages: ["device-a": 3, "device-b": 2]
                )
            ],
            comics: [comic]
        )

        let start = Date(timeIntervalSince1970: 86_400)
        store.record(
            comicID: comic.id,
            previousDate: start,
            now: start.addingTimeInterval(1),
            previousPageIndex: 0,
            currentPageIndex: 1,
            completed: false
        )

        let day = try #require(store.days.first)
        #expect(day.comicSeconds[comic.id] == 51)
        #expect(day.localDeviceComicSeconds[comic.id] == 21)

        let pushed = ICloudReadingActivityDay(
            local: day,
            deviceID: "device-b",
            comicIdentities: [comic.id: identity]
        )
        #expect(pushed.comicSeconds["device-a#\(identity)"] == 30)
        #expect(pushed.comicSeconds["device-b#\(identity)"] == 21)
        #expect(pushed.comicSeconds.values.reduce(0, +) == 51)

        let merged = ICloudMetadataMergePolicy.merge(
            local: ICloudMetadataPayload(deviceID: "device-b", comics: [], activityDays: [pushed]),
            remote: ICloudMetadataPayload(
                deviceID: "device-a",
                comics: [],
                activityDays: [
                    ICloudReadingActivityDay(
                        dateKey: "1970-01-02",
                        comicSeconds: ["device-a#\(identity)": 30],
                        deviceSeconds: ["device-a": 30]
                    )
                ]
            )
        )
        let result = try #require(merged.activityDays.first)
        #expect(result.seconds == 51)
        #expect(result.comicSeconds["device-b#\(identity)"] == 21)
    }

    @Test
    func recordingAfterRemoteMergeAdvancesOnlyCurrentDeviceCounter() throws {
        let deviceIDKey = "mreader.icloudSync.deviceID"
        let previousDeviceID = UserDefaults.standard.string(forKey: deviceIDKey)
        UserDefaults.standard.set("device-b", forKey: deviceIDKey)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MReaderReadingActivity-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("reading_activity.json")
        defer {
            if let previousDeviceID {
                UserDefaults.standard.set(previousDeviceID, forKey: deviceIDKey)
            } else {
                UserDefaults.standard.removeObject(forKey: deviceIDKey)
            }
            try? FileManager.default.removeItem(at: directory)
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let store = ReadingActivityStore(calendar: calendar, storageURL: storageURL)
        store.mergeSyncedDays(
            [
                ICloudReadingActivityDay(
                    dateKey: "1970-01-02",
                    seconds: 30,
                    pages: 3,
                    deviceSeconds: ["device-a": 30],
                    devicePages: ["device-a": 3]
                )
            ],
            comics: []
        )

        let start = Date(timeIntervalSince1970: 86_400)
        store.record(
            comicID: UUID(),
            previousDate: start,
            now: start.addingTimeInterval(1),
            previousPageIndex: 0,
            currentPageIndex: 1,
            completed: false
        )

        let day = try #require(store.days.first)
        #expect(day.seconds == 31)
        #expect(day.pages == 4)
        #expect(day.syncedDeviceSeconds == ["device-a": 30, "device-b": 1])
        #expect(day.syncedDevicePages == ["device-a": 3, "device-b": 1])

        let payloadDay = ICloudReadingActivityDay(
            local: day,
            deviceID: "device-b",
            comicIdentities: [:]
        )
        #expect(payloadDay.seconds == 31)
        #expect(payloadDay.deviceSeconds == ["device-a": 30, "device-b": 1])
        #expect(payloadDay.devicePages == ["device-a": 3, "device-b": 1])
    }

    /// 审查 #8：读盘不再阻塞主线程，但加载完成后必须把磁盘上的天数应用回内存。
    @Test
    func loadsExistingDaysInBackgroundAndAppliesThem() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MReaderReadingActivity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storageURL = directory.appendingPathComponent("reading_activity.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let seeded = [
            ReadingActivityDay(dateKey: "2026-01-01", seconds: 120, pages: 7)
        ]
        try JSONEncoder().encode(seeded).write(to: storageURL, options: .atomic)

        let store = ReadingActivityStore(storageURL: storageURL)
        await waitUntil { !store.days.isEmpty }

        #expect(store.days.map(\.dateKey) == ["2026-01-01"])
        #expect(store.days.first?.seconds == 120)
        #expect(store.days.first?.pages == 7)
    }

    /// 审查 #8：写盘移出主线程后，重新打开 store 仍应读回刚写入的记录。
    @Test
    func recordedDaysSurviveReloadAfterAsyncWrite() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MReaderReadingActivity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storageURL = directory.appendingPathComponent("reading_activity.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let start = Date(timeIntervalSince1970: 0)
        let store = ReadingActivityStore(calendar: calendar, storageURL: storageURL)
        store.record(
            comicID: UUID(),
            previousDate: start,
            now: start.addingTimeInterval(12),
            previousPageIndex: 0,
            currentPageIndex: 2,
            completed: false
        )

        await waitUntil { FileManager.default.fileExists(atPath: storageURL.path) }

        let reloaded = ReadingActivityStore(calendar: calendar, storageURL: storageURL)
        await waitUntil { !reloaded.days.isEmpty }
        #expect(reloaded.days.first?.pages == 2)
        #expect(reloaded.days.first?.seconds == 12)
    }

    /// 审查 #6：读盘完成前发生的 record 不能立刻落盘，
    /// 否则会把"还没包含磁盘历史"的快照写回去，用户在这一瞬间退出就永久丢了旧统计。
    @Test
    func recordingBeforeBackgroundLoadKeepsDiskHistory() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MReaderReadingActivity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storageURL = directory.appendingPathComponent("reading_activity.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        // 磁盘上已有历史：1970-01-02。
        let seeded = [ReadingActivityDay(dateKey: "1970-01-02", seconds: 100, pages: 5)]
        try JSONEncoder().encode(seeded).write(to: storageURL, options: .atomic)

        // 立刻创建 store 并马上 record：此时后台读盘尚未完成。
        let store = ReadingActivityStore(calendar: calendar, storageURL: storageURL)
        let day = Date(timeIntervalSince1970: 172_800) // 1970-01-03 UTC
        store.record(
            comicID: UUID(),
            previousDate: day,
            now: day.addingTimeInterval(12),
            previousPageIndex: 0,
            currentPageIndex: 2,
            completed: false
        )

        await waitUntil { Self.storedDayKeys(at: storageURL).count == 2 }
        #expect(Self.storedDayKeys(at: storageURL) == ["1970-01-02", "1970-01-03"])

        // 重启后历史与新记录都在。
        let reloaded = ReadingActivityStore(calendar: calendar, storageURL: storageURL)
        await waitUntil { reloaded.days.count == 2 }
        #expect(reloaded.days.map(\.dateKey) == ["1970-01-02", "1970-01-03"])
        #expect(reloaded.days.first { $0.dateKey == "1970-01-02" }?.seconds == 100)
        #expect(reloaded.days.first { $0.dateKey == "1970-01-03" }?.pages == 2)
    }

    /// 审查 #6：写入走防抖，但显式 flush（例如进入后台）必须立即落盘。
    @Test
    func explicitFlushPersistsPendingChangesImmediately() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MReaderReadingActivity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storageURL = directory.appendingPathComponent("reading_activity.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let seeded = [ReadingActivityDay(dateKey: "1970-01-02", seconds: 100, pages: 5)]
        try JSONEncoder().encode(seeded).write(to: storageURL, options: .atomic)

        let store = ReadingActivityStore(calendar: calendar, storageURL: storageURL)
        // 读到磁盘历史即证明读盘阶段已结束。
        await waitUntil { !store.days.isEmpty }

        let day = Date(timeIntervalSince1970: 172_800)
        store.record(
            comicID: UUID(),
            previousDate: day,
            now: day.addingTimeInterval(5),
            previousPageIndex: 0,
            currentPageIndex: 1,
            completed: false
        )
        store.flushPendingWrites()

        await waitUntil { Self.storedDayKeys(at: storageURL).count == 2 }
        #expect(Self.storedDayKeys(at: storageURL) == ["1970-01-02", "1970-01-03"])
    }

    private static func storedDayKeys(at url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([ReadingActivityDay].self, from: data) else {
            return []
        }
        return decoded.map(\.dateKey).sorted()
    }

    /// 轮询等待后台 IO 完成，避免测试依赖固定 sleep 时长。
    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
