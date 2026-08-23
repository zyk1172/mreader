import Foundation
import Testing
@testable import mreader

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
}
