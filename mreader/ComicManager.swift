import PDFKit
import SWCompression
import SwiftUI
import ZIPFoundation
import os
import Darwin

struct ComicPage: Identifiable, Hashable, Sendable {
    let id = UUID()
    let index: Int
    let url: URL
}

@Observable
class ComicManager {
    var pages: [ComicPage] = []
    var isAccessing: Bool = false
    var currentURL: URL?

    nonisolated struct ImportResult: Sendable {
        let title: String
        let pagesCount: Int
        let bookmarkData: Data
        let coverImagePath: String?
        let fileSize: Int64
        let libraryPath: String
        let sourceTypeRaw: String
        let sourceURL: String?
        let smbPath: String?
        let chapterTypeRaw: String?
        let chapterPath: String?

        init(
            title: String,
            pagesCount: Int,
            bookmarkData: Data,
            coverImagePath: String?,
            fileSize: Int64,
            libraryPath: String,
            sourceTypeRaw: String = ComicSourceType.local.rawValue,
            sourceURL: String? = nil,
            smbPath: String? = nil,
            chapterTypeRaw: String? = nil,
            chapterPath: String? = nil
        ) {
            self.title = title
            self.pagesCount = pagesCount
            self.bookmarkData = bookmarkData
            self.coverImagePath = coverImagePath
            self.fileSize = fileSize
            self.libraryPath = libraryPath
            self.sourceTypeRaw = sourceTypeRaw
            self.sourceURL = sourceURL
            self.smbPath = smbPath
            self.chapterTypeRaw = chapterTypeRaw
            self.chapterPath = chapterPath
        }
    }

    nonisolated enum ChapterType: String, Sendable {
        case archive
        case folder
        case pdf
    }

    nonisolated struct ScannedChapter: Sendable {
        let title: String
        let chapterType: ChapterType
        let path: String
        let importResult: ImportResult
    }

    nonisolated struct ScannedSeries: Sendable {
        let title: String
        let libraryPath: String
        let comics: [ImportResult]
    }

    nonisolated struct LibraryScanResult: Sendable {
        let comics: [ImportResult]
        let series: [ScannedSeries]
    }

    nonisolated struct LoadResult: Sendable {
        let url: URL
        let didStartSecurityScope: Bool
        let pages: [ComicPage]
    }

    nonisolated enum ArchiveFormat: String, Sendable {
        case zip
        case sevenZip
    }

    nonisolated struct ArchiveImageEntry: Sendable {
        let path: String
        let encodingRawValue: UInt?
        let format: ArchiveFormat
    }

    nonisolated enum ArchiveReadError: LocalizedError {
        case damagedArchive
        case noImages
        case unsupportedArchive
        case memoryLimit
        case permissionDenied
        case encodingFailed
        case archiveTooLarge

        var errorDescription: String? {
            switch self {
            case .damagedArchive:
                return "压缩包损坏或不是有效格式"
            case .noImages:
                return "压缩包内没有找到图片"
            case .unsupportedArchive:
                return "当前已支持 ZIP/CBZ/7z；RAR/CBR 暂无稳定 iOS 解压库支持"
            case .memoryLimit:
                return "图片过大，可能导致内存不足"
            case .permissionDenied:
                return "没有权限读取该文件"
            case .encodingFailed:
                return "压缩包文件名编码解析失败"
            case .archiveTooLarge:
                return "7z 文件过大，当前版本为避免内存暴涨未加载"
            }
        }
    }

    nonisolated private static let libraryRootBookmarkKey = "mreader.libraryRootBookmark"
    nonisolated private static let scanBatchSize = 25
    nonisolated private static let logger = Logger(subsystem: "MReader", category: "LibraryIO")
    nonisolated private static let archivePageScheme = "mreader-zip-page"
    nonisolated private static let maxArchiveImageBytes: UInt64 = 120 * 1024 * 1024
    nonisolated private static let maxSevenZipArchiveBytes: UInt64 = 600 * 1024 * 1024

    func loadFrom(bookmarkData: Data) -> Bool {
        stopAccessing()
        guard let result = Self.loadPages(bookmarkData: bookmarkData) else {
            return false
        }
        applyLoadedPages(result)
        return !pages.isEmpty
    }

    nonisolated static func loadPages(bookmarkData: Data) -> LoadResult? {
        do {
            let url = try resolveBookmark(bookmarkData)
            let didStart = url.startAccessingSecurityScopedResource()
            logMemory("load-pages-start \(url.lastPathComponent)")
            if isReadableArchive(url) {
                do {
                    let entries = try archiveImageEntries(in: url)
                    let pages = entries.enumerated().map { index, entry in
                        ComicPage(index: index, url: archivePageURL(archiveURL: url, entry: entry, index: index))
                    }
                    logMemory("load-pages-end \(url.lastPathComponent) count=\(pages.count)")
                    return pages.isEmpty ? nil : LoadResult(url: url, didStartSecurityScope: didStart, pages: pages)
                } catch {
                    logger.error("load-archive-failed path=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                    if didStart {
                        url.stopAccessingSecurityScopedResource()
                    }
                    return nil
                }
            }
            guard let pageSourceURL = pageSourceURL(for: url) else {
                if didStart {
                    url.stopAccessingSecurityScopedResource()
                }
                return nil
            }
            let sortedURLs = getAllImages(from: pageSourceURL)
                .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            let pages = sortedURLs.enumerated().map { ComicPage(index: $0, url: $1) }
            logMemory("load-pages-end \(url.lastPathComponent) count=\(pages.count)")
            if pages.isEmpty, didStart {
                url.stopAccessingSecurityScopedResource()
            }
            return pages.isEmpty ? nil : LoadResult(url: url, didStartSecurityScope: didStart, pages: pages)
        } catch {
            return nil
        }
    }

    nonisolated static func loadTemporaryPages(from sourceURL: URL) -> LoadResult? {
        if isReadableArchive(sourceURL) {
            do {
                let entries = try archiveImageEntries(in: sourceURL)
                let pages = entries.enumerated().map { index, entry in
                    ComicPage(index: index, url: archivePageURL(archiveURL: sourceURL, entry: entry, index: index))
                }
                logMemory("load-temporary-pages-end \(sourceURL.lastPathComponent) count=\(pages.count)")
                return pages.isEmpty ? nil : LoadResult(url: sourceURL, didStartSecurityScope: false, pages: pages)
            } catch {
                logger.error("load-temporary-archive-failed path=\(sourceURL.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        guard let pageSourceURL = pageSourceURL(for: sourceURL) else { return nil }

        logMemory("load-temporary-pages-start \(sourceURL.lastPathComponent)")
        let sortedURLs = getAllImages(from: pageSourceURL)
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let pages = sortedURLs.enumerated().map { ComicPage(index: $0, url: $1) }
        logMemory("load-temporary-pages-end \(sourceURL.lastPathComponent) count=\(pages.count)")
        return pages.isEmpty ? nil : LoadResult(url: pageSourceURL, didStartSecurityScope: false, pages: pages)
    }

    func applyLoadedPages(_ result: LoadResult) {
        stopAccessing()
        isAccessing = result.didStartSecurityScope
        currentURL = result.url
        pages = result.pages
    }

    nonisolated static func resolveBookmark(_ bookmarkData: Data) throws -> URL {
        var isStale = false
        return try URL(resolvingBookmarkData: bookmarkData, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &isStale)
    }
    
    // 新增：批量导入多选文件或文件夹
    nonisolated static func importFilesOrFolders(urls: [URL]) async -> [ImportResult] {
        var results: [ImportResult] = []
        for url in urls {
            if let result = await importFileOrFolder(url: url) {
                results.append(result)
            }
        }
        return results
    }
    
    // 统一导入入口
    nonisolated static func importFileOrFolder(url: URL, destinationRoot: URL? = nil) async -> ImportResult? {
        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        defer { if isSecurityScoped { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.lowercased()

        if isReadableArchive(url) {
            return importArchiveReference(url: url, destinationRoot: destinationRoot)
        }

        let imageSourceURL: URL
        var temporaryExtractionURL: URL?

        if ["rar", "cbr"].contains(ext) {
            return nil
        } else if ext == "pdf" {
            guard let extractedURL = await extractImagesFromPDF(url) else {
                return nil
            }
            temporaryExtractionURL = extractedURL
            imageSourceURL = extractedURL
        } else {
            imageSourceURL = url
        }
        defer {
            if let temporaryExtractionURL {
                try? FileManager.default.removeItem(at: temporaryExtractionURL)
            }
        }

        let destinationFolder: URL
        if temporaryExtractionURL != nil {
            guard let libraryRoot = destinationRoot ?? selectedLibraryRootURL() else { return nil }
            let targetFolder = uniqueFolder(in: libraryRoot, preferredName: sanitizedFolderName(url.deletingPathExtension().lastPathComponent))
            do {
                try FileManager.default.moveItem(at: imageSourceURL, to: targetFolder)
                destinationFolder = targetFolder
                temporaryExtractionURL = nil // 已经移走，不需要 defer 删除
            } catch {
                return nil
            }
        } else if destinationRoot == nil && imageSourceURL.hasDirectoryPath && isInsideLocalLibrary(imageSourceURL) {
            destinationFolder = imageSourceURL
        } else {
            guard let copiedFolder = copyImagesToLocalLibrary(from: imageSourceURL, title: url.deletingPathExtension().lastPathComponent, root: destinationRoot) else {
                return nil
            }
            destinationFolder = copiedFolder
        }

        let summary = imageSummary(from: destinationFolder)
        guard summary.count > 0 else { return nil }

        if let bookmark = createBookmark(for: destinationFolder) {
            return ImportResult(
                title: url.deletingPathExtension().lastPathComponent,
                pagesCount: summary.count,
                bookmarkData: bookmark,
                coverImagePath: summary.first?.path,
                fileSize: folderSize(destinationFolder),
                libraryPath: destinationFolder.path,
                chapterTypeRaw: ChapterType.folder.rawValue,
                chapterPath: destinationFolder.path
            )
        }
        return nil
    }

    nonisolated static func ensureLocalLibraryExists() {
        _ = selectedLibraryRootURL()
    }

    nonisolated static func scanLocalLibrary() -> [ImportResult] {
        let hierarchy = scanLocalLibraryHierarchy()
        return hierarchy.comics + hierarchy.series.flatMap(\.comics)
    }

    nonisolated static func scanLocalLibraryHierarchy() -> LibraryScanResult {
        guard let libraryRoot = selectedLibraryRootURL(),
              let children = try? FileManager.default.contentsOfDirectory(at: libraryRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return LibraryScanResult(comics: [], series: [])
        }

        var comics: [ImportResult] = []
        var series: [ScannedSeries] = []
        logMemory("scan-start root=\(libraryRoot.lastPathComponent) children=\(children.count)")
        var archiveCount = 0
        var folderChapterCount = 0
        for batchStart in stride(from: 0, to: children.count, by: scanBatchSize) {
            let batchEnd = min(batchStart + scanBatchSize, children.count)
            autoreleasepool {
                for child in children[batchStart..<batchEnd] {
                    if isDirectory(child) {
                        let detected = scanSeriesFolder(child)
                        archiveCount += detected.archiveCount
                        folderChapterCount += detected.folderChapterCount
                        if !detected.series.isEmpty {
                            series.append(contentsOf: detected.series)
                        } else if let directComic = detected.directComic {
                            comics.append(directComic)
                        }
                        continue
                    }

                    if isArchiveOrDocument(child) {
                        archiveCount += 1
                    }
                    if let chapter = makeChapter(from: child) {
                        if chapter.chapterType == .folder {
                            folderChapterCount += 1
                        }
                        comics.append(chapter.importResult)
                    }
                }
            }
            logMemory("scan-batch \(batchEnd)/\(children.count)")
        }
        logger.info("scan-summary archives=\(archiveCount, privacy: .public) folderChapters=\(folderChapterCount, privacy: .public) mergedComics=\(series.count + comics.count, privacy: .public)")
        for scannedSeries in series {
            let chapterList = scannedSeries.comics.map(\.title).joined(separator: " | ")
            logger.info("scan-comic title=\(scannedSeries.title, privacy: .public) chapters=\(chapterList, privacy: .public)")
        }
        return LibraryScanResult(
            comics: comics.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending },
            series: series.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        )
    }
    
    nonisolated private static func createBookmark(for url: URL) -> Data? {
        do {
            return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch { return nil }
    }

    nonisolated private static func copyImagesToLocalLibrary(from sourceURL: URL, title: String, root: URL? = nil) -> URL? {
        let imageURLs = getAllImages(from: sourceURL)
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        guard !imageURLs.isEmpty else { return nil }
        let libraryRoot = root ?? selectedLibraryRootURL()
        guard let libraryRoot else { return nil }

        let targetFolder = uniqueFolder(in: libraryRoot, preferredName: sanitizedFolderName(title))
        do {
            try FileManager.default.createDirectory(at: targetFolder, withIntermediateDirectories: true)
            for (index, imageURL) in imageURLs.enumerated() {
                let ext = imageURL.pathExtension.isEmpty ? "jpg" : imageURL.pathExtension
                let destination = targetFolder.appendingPathComponent(String(format: "%05d.%@", index + 1, ext))
                try FileManager.default.copyItem(at: imageURL, to: destination)
            }
            return targetFolder
        } catch {
            try? FileManager.default.removeItem(at: targetFolder)
            return nil
        }
    }

    nonisolated private static func unzipArchive(_ archiveURL: URL) -> URL? {
        do {
            let extractionRoot = temporaryImportRoot()
            try FileManager.default.createDirectory(at: extractionRoot, withIntermediateDirectories: true)

            let destinationURL = extractionRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
            try FileManager.default.unzipItem(at: archiveURL, to: destinationURL)
            return destinationURL
        } catch {
            return nil
        }
    }

    nonisolated private static func importArchiveReference(url: URL, destinationRoot: URL?) -> ImportResult? {
        do {
            let entries = try archiveImageEntries(in: url)
            guard let firstEntry = entries.first else { return nil }

            let destinationURL: URL
            if destinationRoot == nil && isInsideLocalLibrary(url) {
                destinationURL = url
            } else {
                let libraryRoot = destinationRoot ?? selectedLibraryRootURL()
                guard let libraryRoot else { return nil }
                destinationURL = uniqueURL(in: libraryRoot, preferredName: url.lastPathComponent, isDirectory: false)
                try FileManager.default.copyItem(at: url, to: destinationURL)
            }

            let bookmark = createBookmark(for: destinationURL)
            guard let bookmark else { return nil }
            let coverData = try? archiveImageData(
                archiveURL: destinationURL,
                entryPath: firstEntry.path,
                encodingRawValue: firstEntry.encodingRawValue,
                format: firstEntry.format
            )
            let coverPath = cacheCoverData(coverData, cacheKey: destinationURL.path + "#" + firstEntry.path)
            return ImportResult(
                title: destinationURL.deletingPathExtension().lastPathComponent,
                pagesCount: entries.count,
                bookmarkData: bookmark,
                coverImagePath: coverPath,
                fileSize: folderSize(destinationURL),
                libraryPath: destinationURL.path,
                chapterTypeRaw: ChapterType.archive.rawValue,
                chapterPath: destinationURL.path
            )
        } catch {
            logger.error("import-archive-failed path=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    nonisolated private static func extractImagesFromPDF(_ pdfURL: URL) async -> URL? {
        guard let document = PDFDocument(url: pdfURL) else { return nil }

        let extractionRoot = temporaryImportRoot()
        let destinationURL = extractionRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        return await Task.detached(priority: .userInitiated) { () -> URL? in
            autoreleasepool {
                for i in 0..<document.pageCount {
                    autoreleasepool {
                        guard let page = document.page(at: i) else { return }

                        // 渲染 PDF 页面为高分辨率图片
                        let pageRect = page.bounds(for: .mediaBox)
                        let scale: CGFloat = 3.0 // 提高分辨率
                        let size = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)

                        let format = UIGraphicsImageRendererFormat()
                        format.scale = 1

                        let renderer = UIGraphicsImageRenderer(size: size, format: format)
                        let image = renderer.image { ctx in
                            UIColor.white.set()
                            ctx.fill(CGRect(origin: .zero, size: size))

                            ctx.cgContext.translateBy(x: 0.0, y: size.height)
                            ctx.cgContext.scaleBy(x: scale, y: -scale)

                            page.draw(with: .mediaBox, to: ctx.cgContext)
                        }

                        if let data = image.jpegData(compressionQuality: 0.85) {
                            let fileURL = destinationURL.appendingPathComponent(String(format: "%05d.jpg", i + 1))
                            try? data.write(to: fileURL)
                        }
                    }
                }
            }
            return destinationURL
        }.value
    }

    nonisolated private static func importArchiveAlreadyInLibrary(_ archiveURL: URL) -> ImportResult? {
        guard let extractedURL = unzipArchive(archiveURL) else { return nil }

        let libraryRoot = archiveURL.deletingLastPathComponent()
        let targetFolder = uniqueFolder(in: libraryRoot, preferredName: sanitizedFolderName(archiveURL.deletingPathExtension().lastPathComponent))
        do {
            try FileManager.default.moveItem(at: extractedURL, to: targetFolder)
        } catch {
            try? FileManager.default.removeItem(at: extractedURL)
            return nil
        }

        try? FileManager.default.removeItem(at: archiveURL)

        let summary = imageSummary(from: targetFolder)
        guard summary.count > 0, let bookmark = createBookmark(for: targetFolder) else { return nil }

        return ImportResult(
            title: targetFolder.lastPathComponent,
            pagesCount: summary.count,
            bookmarkData: bookmark,
            coverImagePath: summary.first?.path,
            fileSize: folderSize(targetFolder),
            libraryPath: targetFolder.path,
            chapterTypeRaw: ChapterType.folder.rawValue,
            chapterPath: targetFolder.path
        )
    }

    nonisolated private static func importPDFAlreadyInLibrary(_ pdfURL: URL) -> ImportResult? {
        let extractedURL = extractImagesFromPDFSynchronously(pdfURL)
        guard let extractedURL else { return nil }
        let libraryRoot = pdfURL.deletingLastPathComponent()
        let targetFolder = uniqueFolder(in: libraryRoot, preferredName: sanitizedFolderName(pdfURL.deletingPathExtension().lastPathComponent))
        do {
            try FileManager.default.moveItem(at: extractedURL, to: targetFolder)
        } catch {
            try? FileManager.default.removeItem(at: extractedURL)
            return nil
        }
        try? FileManager.default.removeItem(at: pdfURL)

        return importResultForLocalFolder(targetFolder)
    }

    nonisolated private static func extractImagesFromPDFSynchronously(_ pdfURL: URL) -> URL? {
        guard let document = PDFDocument(url: pdfURL) else { return nil }

        let extractionRoot = temporaryImportRoot()
        let destinationURL = extractionRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        autoreleasepool {
            for i in 0..<document.pageCount {
                autoreleasepool {
                    guard let page = document.page(at: i) else { return }
                    let pageRect = page.bounds(for: .mediaBox)
                    let scale: CGFloat = 3.0
                    let size = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)

                    let format = UIGraphicsImageRendererFormat()
                    format.scale = 1

                    let renderer = UIGraphicsImageRenderer(size: size, format: format)
                    let image = renderer.image { ctx in
                        UIColor.white.set()
                        ctx.fill(CGRect(origin: .zero, size: size))
                        ctx.cgContext.translateBy(x: 0.0, y: size.height)
                        ctx.cgContext.scaleBy(x: scale, y: -scale)
                        page.draw(with: .mediaBox, to: ctx.cgContext)
                    }

                    if let data = image.jpegData(compressionQuality: 0.85) {
                        let fileURL = destinationURL.appendingPathComponent(String(format: "%05d.jpg", i + 1))
                        try? data.write(to: fileURL)
                    }
                }
            }
        }

        return destinationURL
    }

    nonisolated private static func importResultForLocalFolder(_ folderURL: URL) -> ImportResult? {
        let summary = imageSummary(from: folderURL)
        guard summary.count > 0, let bookmark = createBookmark(for: folderURL) else { return nil }
        return ImportResult(
            title: folderURL.deletingPathExtension().lastPathComponent,
            pagesCount: summary.count,
            bookmarkData: bookmark,
            coverImagePath: summary.first?.path,
            fileSize: folderSize(folderURL),
            libraryPath: folderURL.path,
            chapterTypeRaw: ChapterType.folder.rawValue,
            chapterPath: folderURL.path
        )
    }

    nonisolated static func createSeriesFolder(title: String) -> URL? {
        guard let libraryRoot = selectedLibraryRootURL() else { return nil }
        let folder = uniqueFolder(in: libraryRoot, preferredName: sanitizedFolderName(title))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        } catch {
            return nil
        }
    }

    nonisolated static func hasSelectedLibraryRoot() -> Bool {
        selectedLibraryRootURL() != nil
    }

    nonisolated static func setLibraryRoot(_ url: URL) -> Bool {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: libraryRootBookmarkKey)
            return true
        } catch {
            return false
        }
    }

    nonisolated static func selectedLibraryRootURL() -> URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: libraryRootBookmarkKey) else { return nil }
        do {
            let url = try resolveBookmark(bookmark)
            _ = url.startAccessingSecurityScopedResource()
            return url
        } catch {
            return nil
        }
    }

    nonisolated static func readableLocalLibraryAddress() -> String {
        selectedLibraryRootURL()?.path ?? "未选择漫画库"
    }

    nonisolated static func localLibraryURLForOpening() -> URL {
        selectedLibraryRootURL() ?? URL(fileURLWithPath: "/")
    }

    nonisolated static func urlForLibraryPath(_ path: String?) -> URL? {
        guard let path else { return nil }
        return URL(fileURLWithPath: path)
    }

    nonisolated static func deleteLibraryPath(_ path: String?) {
        guard let path else { return }
        let url = URL(fileURLWithPath: path)
        guard isInsideLocalLibrary(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    nonisolated static func temporaryImportCacheSize() -> Int64 {
        folderSize(temporaryImportRoot())
    }

    nonisolated static func clearTemporaryImportCache() {
        try? FileManager.default.removeItem(at: temporaryImportRoot())
    }

    nonisolated static func rebuildCoverImage(bookmarkData: Data) -> String? {
        do {
            let url = try resolveBookmark(bookmarkData)
            return firstImageURL(from: url)?.path
        } catch {
            return nil
        }
    }

    nonisolated static func librarySize(bookmarkData: Data) -> Int64 {
        do {
            return folderSize(try resolveBookmark(bookmarkData))
        } catch {
            return 0
        }
    }
    
    // 递归获取所有图片文件
    nonisolated static func getAllImages(from folderURL: URL) -> [URL] {
        if supportedImageExtensions.contains(folderURL.pathExtension.lowercased()) {
            return [folderURL]
        }

        guard let enumerator = FileManager.default.enumerator(at: folderURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        var imageURLs: [URL] = []
        for case let fileURL as URL in enumerator {
            if supportedImageExtensions.contains(fileURL.pathExtension.lowercased()) {
                imageURLs.append(fileURL)
            }
        }
        return imageURLs
    }

    nonisolated static func firstImageURL(from folderURL: URL) -> URL? {
        imageSummary(from: folderURL).first
    }

    nonisolated static func imageSummary(from folderURL: URL) -> (first: URL?, count: Int) {
        if supportedImageExtensions.contains(folderURL.pathExtension.lowercased()) {
            return (folderURL, 1)
        }

        guard let enumerator = FileManager.default.enumerator(at: folderURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return (nil, 0)
        }

        var first: URL?
        var count = 0
        for case let fileURL as URL in enumerator {
            guard supportedImageExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
            count += 1
            if first == nil || fileURL.path.localizedStandardCompare(first!.path) == .orderedAscending {
                first = fileURL
            }
        }
        return (first, count)
    }

    nonisolated static func folderSize(_ folderURL: URL) -> Int64 {
        if let values = try? folderURL.resourceValues(forKeys: [.fileSizeKey]), let fileSize = values.fileSize {
            return Int64(fileSize)
        }

        guard let enumerator = FileManager.default.enumerator(at: folderURL, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }

    nonisolated static func logMemory(_ label: String) {
        let used = residentMemoryBytes()
        let usedText = used > 0 ? ByteCountFormatter.string(fromByteCount: used, countStyle: .memory) : "unknown"
        logger.info("\(label, privacy: .public) memory=\(usedText, privacy: .public)")
    }

    nonisolated private static func residentMemoryBytes() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int64(info.resident_size)
    }

    nonisolated private static func sanitizedFolderName(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = trimmed.components(separatedBy: invalid).joined(separator: "-")
        return cleaned.isEmpty ? "Untitled Comic" : cleaned
    }

    nonisolated private static func uniqueFolder(in root: URL, preferredName: String) -> URL {
        var candidate = root.appendingPathComponent(preferredName, isDirectory: true)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(preferredName) \(index)", isDirectory: true)
            index += 1
        }
        return candidate
    }

    nonisolated private static func uniqueURL(in root: URL, preferredName: String, isDirectory: Bool) -> URL {
        var candidate = root.appendingPathComponent(preferredName, isDirectory: isDirectory)
        let baseName = (preferredName as NSString).deletingPathExtension
        let ext = (preferredName as NSString).pathExtension
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(baseName) \(index)" : "\(baseName) \(index).\(ext)"
            candidate = root.appendingPathComponent(name, isDirectory: isDirectory)
            index += 1
        }
        return candidate
    }

    nonisolated private static func temporaryImportRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MReaderImports", isDirectory: true)
    }

    nonisolated private static let supportedImageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "heic", "heif"]
    nonisolated private static let supportedArchiveExtensions: Set<String> = ["zip", "cbz", "rar", "cbr", "7z"]
    nonisolated private static let supportedDocumentExtensions: Set<String> = ["pdf"]

    nonisolated private static func isInsideLocalLibrary(_ url: URL) -> Bool {
        guard let libraryRoot = selectedLibraryRootURL() else { return false }
        let rootPath = libraryRoot.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    nonisolated private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    nonisolated static func hasDirectImages(in folderURL: URL) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return false
        }
        return contents.contains { supportedImageExtensions.contains($0.pathExtension.lowercased()) }
    }

    nonisolated static func folderContainsImportableChildren(_ folderURL: URL) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return false
        }
        return contents.contains { child in
            let ext = child.pathExtension.lowercased()
            return isDirectory(child) || supportedArchiveExtensions.contains(ext) || supportedDocumentExtensions.contains(ext)
        }
    }

    nonisolated private static func makeChapter(from url: URL) -> ScannedChapter? {
        let ext = url.pathExtension.lowercased()
        let chapterType: ChapterType
        let pageSourceURL: URL

        if isDirectory(url) {
            guard hasDirectImages(in: url) else { return nil }
            chapterType = .folder
            pageSourceURL = url
        } else if ext == "pdf" {
            guard let extractedURL = extractImagesFromPDFSynchronously(url) else { return nil }
            chapterType = .pdf
            pageSourceURL = extractedURL
        } else if supportedArchiveExtensions.contains(ext) {
            guard canReadArchiveExtension(ext) else {
                logger.warning("scan-unsupported-archive path=\(url.lastPathComponent, privacy: .public) ext=\(ext, privacy: .public)")
                return nil
            }
            guard let imported = importArchiveReference(url: url, destinationRoot: nil) else { return nil }
            return ScannedChapter(
                title: url.deletingPathExtension().lastPathComponent,
                chapterType: .archive,
                path: url.path,
                importResult: imported
            )
        } else {
            return nil
        }

        let summary = imageSummary(from: pageSourceURL)
        guard summary.count > 0, let bookmark = createBookmark(for: url) else {
            if pageSourceURL != url {
                try? FileManager.default.removeItem(at: pageSourceURL)
            }
            return nil
        }

        let chapterTitle = url.deletingPathExtension().lastPathComponent
        let coverPath = cacheCoverImage(from: summary.first, cacheKey: url.path)
        let result = ImportResult(
            title: chapterTitle,
            pagesCount: summary.count,
            bookmarkData: bookmark,
            coverImagePath: coverPath ?? summary.first?.path,
            fileSize: folderSize(url),
            libraryPath: url.path,
            chapterTypeRaw: chapterType.rawValue,
            chapterPath: url.path
        )

        if pageSourceURL != url {
            try? FileManager.default.removeItem(at: pageSourceURL)
        }

        return ScannedChapter(
            title: chapterTitle,
            chapterType: chapterType,
            path: url.path,
            importResult: result
        )
    }

    nonisolated private static func pageSourceURL(for sourceURL: URL) -> URL? {
        let ext = sourceURL.pathExtension.lowercased()
        if ext == "pdf" {
            return extractImagesFromPDFSynchronously(sourceURL)
        }
        if supportedArchiveExtensions.contains(ext) {
            guard canReadArchiveExtension(ext) else {
                logger.warning("load-unsupported-archive path=\(sourceURL.lastPathComponent, privacy: .public) ext=\(ext, privacy: .public)")
                return nil
            }
            return unzipArchive(sourceURL)
        }
        return sourceURL
    }

    nonisolated static func isArchivePageURL(_ url: URL) -> Bool {
        url.scheme == archivePageScheme
    }

    nonisolated static func imageData(forArchivePageURL url: URL) -> Data? {
        guard let (archiveURL, entryPath, encodingRawValue, format) = archivePageComponents(from: url) else {
            return nil
        }
        return try? archiveImageData(archiveURL: archiveURL, entryPath: entryPath, encodingRawValue: encodingRawValue, format: format)
    }

    nonisolated static func zipImportFailureReason(for url: URL) -> String {
        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        defer { if isSecurityScoped { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.lowercased()
        guard isReadableArchive(url) else {
            if ["rar", "cbr"].contains(ext) {
                return ArchiveReadError.unsupportedArchive.localizedDescription
            }
            return "不支持的文件类型"
        }
        do {
            _ = try archiveImageEntries(in: url)
            return ""
        } catch {
            return error.localizedDescription
        }
    }

    nonisolated private static func canReadArchiveExtension(_ ext: String) -> Bool {
        ext == "zip" || ext == "cbz" || ext == "7z"
    }

    nonisolated private static func isReadableArchive(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return canReadArchiveExtension(ext)
    }

    nonisolated private static func archiveImageEntries(in archiveURL: URL) throws -> [ArchiveImageEntry] {
        switch archiveFormat(for: archiveURL) {
        case .zip:
            return try zipImageEntries(in: archiveURL)
        case .sevenZip:
            return try sevenZipImageEntries(in: archiveURL)
        }
    }

    nonisolated private static func archiveImageData(archiveURL: URL, entryPath: String, encodingRawValue: UInt?, format: ArchiveFormat) throws -> Data {
        switch format {
        case .zip:
            return try zipImageData(archiveURL: archiveURL, entryPath: entryPath, encodingRawValue: encodingRawValue)
        case .sevenZip:
            return try sevenZipImageData(archiveURL: archiveURL, entryPath: entryPath)
        }
    }

    nonisolated private static func archiveFormat(for archiveURL: URL) -> ArchiveFormat {
        archiveURL.pathExtension.lowercased() == "7z" ? .sevenZip : .zip
    }

    nonisolated private static func zipImageEntries(in archiveURL: URL) throws -> [ArchiveImageEntry] {
        guard FileManager.default.isReadableFile(atPath: archiveURL.path) else {
            throw ArchiveReadError.permissionDenied
        }

        var lastError: Error?
        for encoding in zipPathEncodings() {
            do {
                let archive = try Archive(url: archiveURL, accessMode: .read, pathEncoding: encoding)
                let entries = archive.compactMap { entry -> ArchiveImageEntry? in
                    let path = encoding.map { entry.path(using: $0) } ?? entry.path
                    guard entry.type == .file, isValidArchiveImagePath(path) else { return nil }
                    return ArchiveImageEntry(path: path, encodingRawValue: encoding?.rawValue, format: .zip)
                }
                .sorted { lhs, rhs in
                    lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
                }
                if !entries.isEmpty {
                    logger.info("zip-list path=\(archiveURL.lastPathComponent, privacy: .public) images=\(entries.count, privacy: .public)")
                    return entries
                }
            } catch {
                lastError = error
            }
        }

        if lastError != nil {
            throw ArchiveReadError.damagedArchive
        }
        throw ArchiveReadError.noImages
    }

    nonisolated private static func zipImageData(archiveURL: URL, entryPath: String, encodingRawValue: UInt?) throws -> Data {
        let encoding = encodingRawValue.map { String.Encoding(rawValue: $0) }
        let archive = try Archive(url: archiveURL, accessMode: .read, pathEncoding: encoding)
        guard let entry = archive.first(where: { entry in
            let path = encoding.map { entry.path(using: $0) } ?? entry.path
            return path == entryPath
        }) else {
            throw ArchiveReadError.encodingFailed
        }
        guard entry.uncompressedSize <= maxArchiveImageBytes else {
            throw ArchiveReadError.memoryLimit
        }
        var data = Data()
        data.reserveCapacity(Int(min(entry.uncompressedSize, UInt64(Int.max))))
        do {
            _ = try archive.extract(entry, skipCRC32: true) { chunk in
                data.append(chunk)
            }
            return data
        } catch {
            throw ArchiveReadError.damagedArchive
        }
    }

    nonisolated private static func sevenZipImageEntries(in archiveURL: URL) throws -> [ArchiveImageEntry] {
        guard FileManager.default.isReadableFile(atPath: archiveURL.path) else {
            throw ArchiveReadError.permissionDenied
        }

        let container = try sevenZipContainerData(for: archiveURL)
        let infos: [SevenZipEntryInfo]
        do {
            infos = try SevenZipContainer.info(container: container)
        } catch {
            throw ArchiveReadError.damagedArchive
        }

        let entries = infos.compactMap { info -> ArchiveImageEntry? in
            let name = info.name
            guard info.type == .regular, isValidArchiveImagePath(name) else { return nil }
            if let size = info.size, UInt64(size) > maxArchiveImageBytes {
                return nil
            }
            return ArchiveImageEntry(path: name, encodingRawValue: nil, format: .sevenZip)
        }
        .sorted { lhs, rhs in
            lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }

        if entries.isEmpty {
            throw ArchiveReadError.noImages
        }
        logger.info("7z-list path=\(archiveURL.lastPathComponent, privacy: .public) images=\(entries.count, privacy: .public)")
        return entries
    }

    nonisolated private static func sevenZipImageData(archiveURL: URL, entryPath: String) throws -> Data {
        let container = try sevenZipContainerData(for: archiveURL)
        let entries: [SevenZipEntry]
        do {
            entries = try SevenZipContainer.open(container: container)
        } catch {
            throw ArchiveReadError.damagedArchive
        }
        guard let entry = entries.first(where: { $0.info.name == entryPath }) else {
            throw ArchiveReadError.encodingFailed
        }
        guard let data = entry.data else {
            throw ArchiveReadError.damagedArchive
        }
        guard UInt64(data.count) <= maxArchiveImageBytes else {
            throw ArchiveReadError.memoryLimit
        }
        return data
    }

    nonisolated private static func sevenZipContainerData(for archiveURL: URL) throws -> Data {
        let values = try archiveURL.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = values.fileSize, UInt64(fileSize) > maxSevenZipArchiveBytes {
            throw ArchiveReadError.archiveTooLarge
        }
        do {
            return try Data(contentsOf: archiveURL, options: .mappedIfSafe)
        } catch {
            throw ArchiveReadError.permissionDenied
        }
    }

    nonisolated private static func isValidArchiveImagePath(_ path: String) -> Bool {
        let normalizedPath = path.replacingOccurrences(of: "\\", with: "/")
        let components = normalizedPath.split(separator: "/").map(String.init)
        guard let fileName = components.last, !fileName.isEmpty else { return false }
        if fileName == ".DS_Store" || fileName.localizedCaseInsensitiveCompare("Thumbs.db") == .orderedSame {
            return false
        }
        if components.contains("__MACOSX") {
            return false
        }
        if components.contains(where: { $0.hasPrefix(".") }) {
            return false
        }
        return supportedImageExtensions.contains((fileName as NSString).pathExtension.lowercased())
    }

    nonisolated private static func zipPathEncodings() -> [String.Encoding?] {
        var encodings: [String.Encoding?] = [nil, .utf8, .shiftJIS]
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let eucKR = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.EUC_KR.rawValue)))
        encodings.append(gb18030)
        encodings.append(eucKR)
        return encodings
    }

    nonisolated private static func archivePageURL(archiveURL: URL, entry: ArchiveImageEntry, index: Int) -> URL {
        var components = URLComponents()
        components.scheme = archivePageScheme
        components.host = "page"
        var queryItems = [
            URLQueryItem(name: "archive", value: base64URLEncoded(archiveURL.path)),
            URLQueryItem(name: "entry", value: base64URLEncoded(entry.path)),
            URLQueryItem(name: "format", value: entry.format.rawValue),
            URLQueryItem(name: "index", value: "\(index)")
        ]
        if let encodingRawValue = entry.encodingRawValue {
            queryItems.append(URLQueryItem(name: "encoding", value: "\(encodingRawValue)"))
        }
        components.queryItems = queryItems
        return components.url ?? URL(fileURLWithPath: archiveURL.path)
    }

    nonisolated private static func archivePageComponents(from url: URL) -> (URL, String, UInt?, ArchiveFormat)? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = components.queryItems ?? []
        guard let archiveValue = items.first(where: { $0.name == "archive" })?.value,
              let entryValue = items.first(where: { $0.name == "entry" })?.value,
              let archivePath = base64URLDecoded(archiveValue),
              let entryPath = base64URLDecoded(entryValue) else {
            return nil
        }
        let encodingRawValue = items.first(where: { $0.name == "encoding" })?.value.flatMap(UInt.init)
        let formatValue = items.first(where: { $0.name == "format" })?.value
        let format = formatValue.flatMap(ArchiveFormat.init(rawValue:)) ?? archiveFormat(for: URL(fileURLWithPath: archivePath))
        return (URL(fileURLWithPath: archivePath), entryPath, encodingRawValue, format)
    }

    nonisolated private static func base64URLEncoded(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    nonisolated private static func base64URLDecoded(_ value: String) -> String? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = base64.count % 4
        if padding > 0 {
            base64 += String(repeating: "=", count: 4 - padding)
        }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated private static func isArchiveOrDocument(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return supportedArchiveExtensions.contains(ext) || supportedDocumentExtensions.contains(ext)
    }

    nonisolated private static func cacheCoverImage(from sourceURL: URL?, cacheKey: String) -> String? {
        guard let sourceURL else { return nil }
        let destination = coverCacheURL(cacheKey: cacheKey)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                return destination.path
            }
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            return destination.path
        } catch {
            return nil
        }
    }

    nonisolated private static func cacheCoverData(_ data: Data?, cacheKey: String) -> String? {
        guard let data else { return nil }
        let destination = coverCacheURL(cacheKey: cacheKey)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                return destination.path
            }
            try data.write(to: destination, options: .atomic)
            return destination.path
        } catch {
            return nil
        }
    }

    nonisolated private static func coverCacheURL(cacheKey: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let encoded = Data(cacheKey.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return caches.appendingPathComponent("MReaderCoverCache", isDirectory: true)
            .appendingPathComponent(encoded + ".jpg")
    }

    nonisolated private struct SeriesFolderScan {
        let series: [ScannedSeries]
        let directComic: ImportResult?
        let archiveCount: Int
        let folderChapterCount: Int
    }

    nonisolated private static func scanSeriesFolder(_ seriesURL: URL) -> SeriesFolderScan {
        guard let children = try? FileManager.default.contentsOfDirectory(at: seriesURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return SeriesFolderScan(series: [], directComic: nil, archiveCount: 0, folderChapterCount: 0)
        }
        var chapters: [ScannedChapter] = []
        var archiveCount = 0
        var folderChapterCount = 0
        for child in children {
            if isArchiveOrDocument(child) {
                archiveCount += 1
            }
            guard let chapter = makeChapter(from: child) else { continue }
            chapters.append(chapter)
            if chapter.chapterType == .folder {
                folderChapterCount += 1
            }
        }

        if chapters.isEmpty, hasDirectImages(in: seriesURL), let directComic = importResultForLocalFolder(seriesURL) {
            return SeriesFolderScan(series: [], directComic: directComic, archiveCount: 0, folderChapterCount: 1)
        }

        let sortedChapters = chapters.sorted { lhs, rhs in
            lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
        let chapterList = sortedChapters.map { chapter in
            "\(chapter.title)[\(chapter.chapterType.rawValue)]"
        }.joined(separator: " | ")
        logger.info("scan-series-folder folder=\(seriesURL.lastPathComponent, privacy: .public) chapters=\(chapterList, privacy: .public)")
        let scannedSeries = [
            ScannedSeries(
                title: seriesURL.lastPathComponent,
                libraryPath: seriesURL.path,
                comics: sortedChapters.map { chapter in
                    chapter.importResult
                }
            )
        ]

        return SeriesFolderScan(
            series: scannedSeries,
            directComic: nil,
            archiveCount: archiveCount,
            folderChapterCount: folderChapterCount
        )
    }

    func stopAccessing() {
        if isAccessing {
            currentURL?.stopAccessingSecurityScopedResource()
        }
        isAccessing = false
        currentURL = nil
        pages.removeAll()
    }
}
