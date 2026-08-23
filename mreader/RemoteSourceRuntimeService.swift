import Foundation

nonisolated struct RemoteSourceShelfState: Sendable {
    let sources: [MediaSource]
    let hiddenComics: [HiddenKomgaComic]
}

/// 远端源的 UI/阅读器边界，集中协调 Komga 与 OPDS façade。
nonisolated enum RemoteSourceRuntimeService {
    static func shelfState() async -> RemoteSourceShelfState {
        RemoteSourceShelfState(
            sources: await KomgaProvider.loadSources(),
            hiddenComics: await KomgaProvider.hiddenKomgaComics()
        )
    }

    static func sourceName(for comic: ComicBook) async -> String? {
        await KomgaProvider.sourceName(for: comic)
    }

    static func coverData(for url: URL) async -> Data? {
        await OPDSProvider.coverData(for: url)
    }
}
