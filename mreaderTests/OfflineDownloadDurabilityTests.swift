import Foundation
import Testing
@testable import mreader

struct OfflineDownloadDurabilityTests {
    @Test
    func cancelledOwnerCannotCommitACompletionRecord() {
        var registry = OfflineDownloadOwnerRegistry()
        let comicID = UUID()
        let ownerToken = registry.begin(for: comicID)

        #expect(registry.canCommit(comicID: comicID, ownerToken: ownerToken))
        registry.cancel(for: comicID)
        #expect(!registry.canCommit(comicID: comicID, ownerToken: ownerToken))
        #expect(registry.isCurrentOwner(comicID: comicID, ownerToken: ownerToken))

        registry.finish(comicID: comicID, ownerToken: ownerToken)
        let nextOwnerToken = registry.begin(for: comicID)
        #expect(nextOwnerToken != ownerToken)
        #expect(registry.canCommit(comicID: comicID, ownerToken: nextOwnerToken))
    }

    @Test
    func offlineComicsUseApplicationSupportStorage() {
        let components = OfflinePageStore.storageURL.pathComponents
        #expect(components.contains("Application Support"))
        #expect(components.last == "MReaderOfflineComics")
    }
}
