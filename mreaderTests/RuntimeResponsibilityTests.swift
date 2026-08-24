import Foundation
import Testing
@testable import mreader

struct RuntimeResponsibilityTests {
    @Test
    func localReaderSourceKeepsInvalidBookmarkFailureClosed() async {
        let comic = ComicBook(
            title: "Invalid local book",
            bookmarkData: Data(),
            totalPages: 1
        )

        #expect(await ReaderPageSourceService.loadPages(for: comic) == nil)
    }

    @Test
    func settingsServiceDoesNotClassifyPlainDataAsEncrypted() {
        #expect(!SettingsBackupService.isEncrypted(Data("{}".utf8)))
    }

    @Test
    func remoteShelfStateKeepsExplicitSourceAndHiddenComicPayloads() {
        let state = RemoteSourceShelfState(sources: [], hiddenComics: [])
        #expect(state.sources.isEmpty)
        #expect(state.hiddenComics.isEmpty)
    }
}
