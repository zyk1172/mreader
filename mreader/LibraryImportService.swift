import Foundation

/// 本地库与导入入口的运行时边界。
/// ComicManager 保留为兼容 façade，具体调用集中在此处，便于后续继续拆出归档实现。
nonisolated enum LibraryImportService {
    static func importFilesOrFolders(urls: [URL]) async -> [ComicManager.ImportResult] {
        await ComicManager.importFilesOrFolders(urls: urls)
    }

    static func importFileOrFolder(url: URL, destinationRoot: URL? = nil) async -> ComicManager.ImportResult? {
        await ComicManager.importFileOrFolder(url: url, destinationRoot: destinationRoot)
    }

    static func scanLocalLibraryHierarchy() -> ComicManager.LibraryScanResult {
        ComicManager.scanLocalLibraryHierarchy()
    }

    static func createSeriesFolder(title: String) -> URL? {
        ComicManager.createSeriesFolder(title: title)
    }

    static func moveComicFile(bookmarkData: Data, to destinationFolder: URL) -> Data? {
        ComicManager.moveComicFile(bookmarkData: bookmarkData, to: destinationFolder)
    }

    static func libraryPathOfMovedFile(oldBookmark: Data, newBookmark: Data) -> String? {
        ComicManager.libraryPathOfMovedFile(oldBookmark: oldBookmark, newBookmark: newBookmark)
    }
}
