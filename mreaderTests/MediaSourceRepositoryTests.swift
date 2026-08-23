import Foundation
import Testing
@testable import mreader

struct MediaSourceRepositoryTests {
    @Test
    func concurrentSourceUpdatesAreNotLost() async throws {
        let (repository, cleanup) = try makeRepository()
        defer { cleanup() }

        let sources = (0..<24).map { index in
            MediaSource(
                name: "Source \(index)",
                type: .komga,
                baseURL: "https://example-\(index).invalid"
            )
        }

        await withTaskGroup(of: Void.self) { group in
            for source in sources {
                group.addTask {
                    try? await repository.updateSource(source)
                }
            }
        }

        let loaded = await repository.loadSources()
        #expect(Set(loaded.map(\.id)) == Set(sources.map(\.id)))
    }

    @Test
    func concurrentHiddenUpdatesAndRemovalsUseLatestActorState() async throws {
        let (repository, cleanup) = try makeRepository()
        defer { cleanup() }

        let hidden = (0..<24).map { index in
            HiddenKomgaComic(
                key: "source:\(index)",
                mediaSourceID: UUID(),
                komgaBookID: "book-\(index)",
                komgaSeriesID: nil,
                title: "Comic \(index)",
                sourceName: "Komga",
                hiddenAt: Date()
            )
        }

        await withTaskGroup(of: Void.self) { group in
            for record in hidden {
                group.addTask {
                    await repository.upsertHiddenComic(record)
                }
            }
        }
        await repository.removeHiddenComic(key: hidden[0].key)

        let loadedKeys = await repository.hiddenComicKeys()
        #expect(loadedKeys.count == hidden.count - 1)
        #expect(!loadedKeys.contains(hidden[0].key))
    }

    @Test
    func invalidationRejectsAnOlderResolvedURLRefresh() async throws {
        let (repository, cleanup) = try makeRepository()
        defer { cleanup() }

        let sourceID = UUID()
        let oldGeneration = await repository.beginResolvedURLRefresh(for: sourceID)
        await repository.storeResolvedURL(
            "https://old.invalid",
            for: sourceID,
            refreshGeneration: oldGeneration
        )

        let newerGeneration = await repository.beginResolvedURLRefresh(for: sourceID)
        await repository.invalidateResolvedURL(for: sourceID)
        await repository.storeResolvedURL(
            "https://stale.invalid",
            for: sourceID,
            refreshGeneration: newerGeneration
        )

        #expect(await repository.resolvedURL(for: sourceID, ttl: 600) == nil)
    }

    private func makeRepository() throws -> (MediaSourceRepository, () -> Void) {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("MReaderMediaSourceRepository-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let suiteName = "mreader.media-source-tests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let repository = MediaSourceRepository(
            fileManager: fileManager,
            directoryURL: directory,
            userDefaults: userDefaults
        )
        return (
            repository,
            {
                userDefaults.removePersistentDomain(forName: suiteName)
                try? fileManager.removeItem(at: directory)
            }
        )
    }
}
