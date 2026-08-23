import Foundation

/// 阅读器的页面来源边界。页面加载仍由既有 ComicManager/远端 provider 执行，
/// 但容器和 OCR 索引不再各自维护 local/Komga/OPDS 分支。
nonisolated enum ReaderPageSourceService {
    static func loadPages(for comic: ComicBook) async -> ComicManager.LoadResult? {
        switch comic.sourceType {
        case .local:
            let bookmarkData = comic.bookmarkData
            return await Task.detached(priority: .userInitiated) {
                ComicManager.loadPages(bookmarkData: bookmarkData)
            }.value
        case .komga:
            return await RemotePageLoader.loadPages(for: comic)
        case .opds:
            return await OPDSProvider.loadPages(for: comic)
        }
    }
}
