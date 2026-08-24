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
}
