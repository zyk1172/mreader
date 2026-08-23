import Foundation
import Testing
@testable import mreader

@MainActor
struct ReadingActivityStoreTests {
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
