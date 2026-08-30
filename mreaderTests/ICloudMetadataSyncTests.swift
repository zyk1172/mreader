import Foundation
import Testing
@testable import mreader

// ComicBook / ComicBookmark / SyncedComicMetadata 都是 MainActor 隔离的。
@MainActor
struct ICloudMetadataSyncTests {
    @Test
    func sourceIdentityIsStableAcrossURLEdits() {
        let source = MediaSource(
            name: "Komga",
            type: .komga,
            baseURL: "HTTPS://Example.com:443/library/"
        )

        #expect(source.stableSyncSourceIdentity == "komga:https://example.com/library")

        var edited = source
        edited.baseURL = "https://new.example/library"
        #expect(edited.stableSyncSourceIdentity == source.stableSyncSourceIdentity)
    }

    @Test
    func localIdentityUsesPortableRelativePath() {
        let comic = ComicBook(
            title: "Book",
            bookmarkData: Data(),
            totalPages: 10,
            libraryPath: "/private/var/mobile/MReader/Series/Book.cbz",
            libraryRelativePath: "Series/Book.cbz"
        )

        #expect(
            ComicSyncIdentity.v2Value(for: comic, sourcesByID: [:]) == "local:Series/Book.cbz"
        )
    }

    @Test
    func progressAndMetadataMergeIndependently() throws {
        let progressOld = Date(timeIntervalSince1970: 100)
        let progressNew = Date(timeIntervalSince1970: 200)
        let metadataNew = Date(timeIntervalSince1970: 300)
        let local = SyncedComicMetadata(
            identity: "local:Series/Book.cbz",
            currentPageIndex: 8,
            furthestPageIndex: 8,
            progressUpdatedAt: progressNew,
            metadataUpdatedAt: progressOld,
            readingModeRaw: "horizontalPage"
        )
        let remote = SyncedComicMetadata(
            identity: "local:Series/Book.cbz",
            currentPageIndex: 2,
            furthestPageIndex: 6,
            progressUpdatedAt: progressOld,
            metadataUpdatedAt: metadataNew,
            readingModeRaw: "verticalScroll",
            bookmarks: [ComicBookmark(pageIndex: 4, note: "remote")]
        )

        let merged = ICloudMetadataMergePolicy.merge(
            local: ICloudMetadataPayload(deviceID: "device-local", comics: [local], activityDays: []),
            remote: ICloudMetadataPayload(deviceID: "device-remote", comics: [remote], activityDays: [])
        )

        let result = try #require(merged.comics.first)
        #expect(result.currentPageIndex == 8)
        #expect(result.furthestPageIndex == 8)
        #expect(result.readingModeRaw == "verticalScroll")
        #expect(result.bookmarks.count == remote.bookmarks.count)
        #expect(result.bookmarks.first?.pageIndex == remote.bookmarks.first?.pageIndex)
    }

    @Test
    func ambiguousV1IdentityFailsClosed() {
        let path = "/private/var/mobile/MReader/Series/Book.cbz"
        let first = ComicBook(
            title: "Book",
            bookmarkData: Data(),
            totalPages: 10,
            libraryPath: path
        )
        let second = ComicBook(
            title: "Book",
            bookmarkData: Data(),
            totalPages: 10,
            libraryPath: path
        )
        let legacy = SyncedComicMetadata(
            identity: ComicSyncIdentity.legacyV1Value(for: first),
            currentPageIndex: 5,
            progressUpdatedAt: Date(timeIntervalSince1970: 100)
        )
        let payload = ICloudMetadataPayload(
            version: 1,
            updatedAt: Date(timeIntervalSince1970: 100),
            deviceID: "legacy-v1",
            comics: [legacy],
            activityDays: []
        )

        let migrated = ICloudMetadataMergePolicy.migrateLegacyV1(
            payload,
            comics: [first, second],
            sourcesByID: [:]
        )
        #expect(migrated.version == 2)
        #expect(migrated.comics.isEmpty)
    }

    @Test
    func activityMergeCountsEachDeviceOnceAndUnionsCompletions() throws {
        let remoteDay = ICloudReadingActivityDay(
            dateKey: "2026-08-23",
            completedComicKeys: ["device-a#local:Book.cbz"],
            comicSeconds: ["device-a#local:Book.cbz": 3],
            deviceSeconds: ["device-a": 3]
        )
        let localDay = ICloudReadingActivityDay(
            dateKey: "2026-08-23",
            completedComicKeys: ["device-b#local:Book.cbz"],
            comicSeconds: ["device-b#local:Book.cbz": 5],
            deviceSeconds: ["device-b": 5]
        )

        let merged = ICloudMetadataMergePolicy.merge(
            local: ICloudMetadataPayload(
                deviceID: "device-b",
                comics: [],
                activityDays: [localDay]
            ),
            remote: ICloudMetadataPayload(
                deviceID: "device-a",
                comics: [],
                activityDays: [remoteDay]
            )
        )

        let result = try #require(merged.activityDays.first)
        #expect(result.seconds == 8)
        #expect(result.comicSeconds["device-a#local:Book.cbz"] == 3)
        #expect(result.comicSeconds["device-b#local:Book.cbz"] == 5)
        #expect(result.completedComicKeys.count == 2)
    }

    @Test
    func activityRoundTripKeepsEachDeviceCounterIndependentFromAggregate() throws {
        let deviceADay = ICloudReadingActivityDay(
            dateKey: "2026-08-24",
            seconds: 30,
            pages: 3,
            deviceSeconds: ["device-a": 30],
            devicePages: ["device-a": 3]
        )
        let deviceBDay = ICloudReadingActivityDay(
            dateKey: "2026-08-24",
            seconds: 20,
            pages: 2,
            deviceSeconds: ["device-b": 20],
            devicePages: ["device-b": 2]
        )

        let afterBPull = ICloudMetadataMergePolicy.merge(
            local: ICloudMetadataPayload(deviceID: "device-b", comics: [], activityDays: [deviceBDay]),
            remote: ICloudMetadataPayload(deviceID: "device-a", comics: [], activityDays: [deviceADay])
        )
        let mergedDay = try #require(afterBPull.activityDays.first)
        #expect(mergedDay.seconds == 50)
        #expect(mergedDay.deviceSeconds == ["device-a": 30, "device-b": 20])

        var bAfterReading = ReadingActivityDay(
            dateKey: mergedDay.dateKey,
            seconds: 51,
            pages: 6,
            syncedDeviceSeconds: mergedDay.deviceSeconds,
            syncedDevicePages: ["device-a": 3, "device-b": 3]
        )
        bAfterReading.syncedDeviceSeconds["device-b"] = 21
        let bPushDay = ICloudReadingActivityDay(
            local: bAfterReading,
            deviceID: "device-b",
            comicIdentities: [:]
        )

        #expect(bPushDay.seconds == 51)
        #expect(bPushDay.deviceSeconds == ["device-a": 30, "device-b": 21])

        let afterARoundTrip = ICloudMetadataMergePolicy.merge(
            local: ICloudMetadataPayload(deviceID: "device-a", comics: [], activityDays: [deviceADay]),
            remote: ICloudMetadataPayload(deviceID: "device-b", comics: [], activityDays: [bPushDay])
        )
        let finalDay = try #require(afterARoundTrip.activityDays.first)
        #expect(finalDay.seconds == 51)
        #expect(finalDay.pages == 6)
        #expect(finalDay.deviceSeconds == ["device-a": 30, "device-b": 21])
        #expect(finalDay.devicePages == ["device-a": 3, "device-b": 3])
    }
}
