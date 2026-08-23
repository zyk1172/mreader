import CryptoKit
import PDFKit
import SwiftUI
import ZIPFoundation
import ImageIO
import os
import Darwin

struct ComicPage: Identifiable, Hashable, Sendable {
    let id = UUID()
    let index: Int
    let url: URL
}

nonisolated final class SecurityScopedResource: @unchecked Sendable {
    let url: URL
    private let didStart: Bool
    private let lock = NSLock()
    private var isStopped = false

    init(url: URL) {
        self.url = url
        didStart = url.startAccessingSecurityScopedResource()
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard didStart, !isStopped else { return }
        url.stopAccessingSecurityScopedResource()
        isStopped = true
    }

    deinit {
        stop()
    }
}

@Observable
class ComicManager {
    var pages: [ComicPage] = []
    private var accessToken: SecurityScopedResource?

    nonisolated struct ImportResult: Sendable {
        let title: String
        let pagesCount: Int
        let bookmarkData: Data
        let coverImagePath: String?
        let fileSize: Int64
        let libraryPath: String
        let sourceTypeRaw: String
        let sourceURL: String?
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

    nonisolated struct ImportFolderInspection: Sendable {
        let hasDirectImages: Bool
        let importableChildren: [URL]
    }

    nonisolated struct LoadResult: Sendable {
        let url: URL
        let accessToken: SecurityScopedResource?
        let pages: [ComicPage]
    }

    nonisolated enum ArchiveFormat: String, Sendable {
        case zip
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

        var errorDescription: String? {
            switch self {
            case .damagedArchive:
                return "压缩包损坏或不是有效格式"
            case .noImages:
                return "压缩包内没有找到图片"
            case .unsupportedArchive:
                return "当前仅支持 ZIP、CBZ、EPUB、PDF 和图片文件夹"
            case .memoryLimit:
                return "图片过大，可能导致内存不足"
            case .permissionDenied:
                return "没有权限读取该文件"
            case .encodingFailed:
                return "压缩包文件名编码解析失败"
            }
        }
    }

    nonisolated private static let libraryRootBookmarkKey = "mreader.libraryRootBookmark"
    nonisolated private static let scanBatchSize = 25
    nonisolated private static let logger = Logger(subsystem: "MReader", category: "LibraryIO")
    nonisolated private static let archivePageScheme = "mreader-zip-page"
    nonisolated private static let maxArchiveImageBytes: UInt64 = 120 * 1024 * 1024

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
            let accessToken = SecurityScopedResource(url: url)
            logMemory("load-pages-start \(url.lastPathComponent)")
            if isReadableArchive(url) {
                do {
                    let entries = try archiveImageEntries(in: url)
                    let pages = entries.enumerated().map { index, entry in
                        ComicPage(index: index, url: archivePageURL(archiveURL: url, entry: entry, index: index))
                    }
                    logMemory("load-pages-end \(url.lastPathComponent) count=\(pages.count)")
                    return pages.isEmpty ? nil : LoadResult(url: url, accessToken: accessToken, pages: pages)
                } catch {
                    logger.error("load-archive-failed path=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                    return nil
                }
            }
            if url.pathExtension.lowercased() == "pdf" {
                // PDF 章节：原 PDF 文件保留，仅把页面按需渲染到临时缓存后读取，绝不改写或删除原文件。
                guard let extractedURL = extractImagesFromPDFSynchronously(url) else { return nil }
                let sortedURLs = getAllImages(from: extractedURL)
                    .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                let pages = sortedURLs.enumerated().map { ComicPage(index: $0, url: $1) }
                logMemory("load-pages-end \(url.lastPathComponent) count=\(pages.count)")
                return pages.isEmpty ? nil : LoadResult(url: url, accessToken: accessToken, pages: pages)
            }
            guard let pageSourceURL = pageSourceURL(for: url) else {
                return nil
            }
            let sortedURLs = getAllImages(from: pageSourceURL)
                .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            let pages = sortedURLs.enumerated().map { ComicPage(index: $0, url: $1) }
            logMemory("load-pages-end \(url.lastPathComponent) count=\(pages.count)")
            return pages.isEmpty ? nil : LoadResult(url: url, accessToken: accessToken, pages: pages)
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
                return pages.isEmpty ? nil : LoadResult(url: sourceURL, accessToken: nil, pages: pages)
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
        return pages.isEmpty ? nil : LoadResult(url: pageSourceURL, accessToken: nil, pages: pages)
    }

    nonisolated static func loadDownloadedRemotePages(from sourceURL: URL) async -> LoadResult? {
        if sourceURL.pathExtension.lowercased() == "pdf" {
            guard let pageSourceURL = await extractImagesFromPDF(sourceURL) else { return nil }
            let sortedURLs = getAllImages(from: pageSourceURL)
                .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            let pages = sortedURLs.enumerated().map { ComicPage(index: $0, url: $1) }
            return pages.isEmpty ? nil : LoadResult(url: pageSourceURL, accessToken: nil, pages: pages)
        }
        if supportedImageExtensions.contains(sourceURL.pathExtension.lowercased()) {
            return LoadResult(
                url: sourceURL,
                accessToken: nil,
                pages: [ComicPage(index: 0, url: sourceURL)]
            )
        }
        return loadTemporaryPages(from: sourceURL)
    }

    func applyLoadedPages(_ result: LoadResult) {
        stopAccessing()
        accessToken = result.accessToken
        pages = result.pages
    }

    nonisolated static func resolveBookmark(_ bookmarkData: Data) throws -> URL {
        var isStale = false
        let url = try URL(resolvingBookmarkData: bookmarkData, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &isStale)
        if isStale {
            logger.warning("bookmark-stale resolved-path=\(url.path, privacy: .public)")
        }
        return url
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

        // EPUB 保留为单文件，阅读时按需读取页面。整本解压会放大导入耗时和失败面，
        // 也会让封面依赖第一张成功落盘的图片。
        if ext == "epub" {
            return importArchiveReference(url: url, destinationRoot: destinationRoot)
        }

        if isReadableArchive(url) {
            return importArchiveReference(url: url, destinationRoot: destinationRoot)
        }

        let imageSourceURL: URL
        var temporaryExtractionURL: URL?

        if isUnsupportedArchiveExtension(ext) {
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
            guard let movedFolder = withLibraryWriteAccess(destinationRoot: destinationRoot, { libraryRoot -> URL? in
                let targetFolder = uniqueFolder(in: libraryRoot, preferredName: sanitizedFolderName(url.deletingPathExtension().lastPathComponent))
                do {
                    try FileManager.default.moveItem(at: imageSourceURL, to: targetFolder)
                    return targetFolder
                } catch {
                    logger.error("import-document-move-failed target=\(targetFolder.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                    return nil
                }
            }) ?? nil else {
                return nil
            }
            destinationFolder = movedFolder
            temporaryExtractionURL = nil
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
        withSelectedLibraryRoot { libraryRoot in
            guard let children = try? FileManager.default.contentsOfDirectory(at: libraryRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
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
        } ?? LibraryScanResult(comics: [], series: [])
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
        return withLibraryWriteAccess(destinationRoot: root) { libraryRoot in
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
                logger.error("import-folder-copy-failed target=\(targetFolder.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                return nil
            }
        } ?? nil
    }

    nonisolated private static func importArchiveReference(url: URL, destinationRoot: URL?) -> ImportResult? {
        do {
            let entries = try archiveImageEntries(in: url)
            guard let firstEntry = entries.first else { return nil }

            let destinationURL: URL
            if destinationRoot == nil && isInsideLocalLibrary(url) {
                destinationURL = url
            } else {
                guard let copiedURL = withLibraryWriteAccess(destinationRoot: destinationRoot, { libraryRoot -> URL? in
                    let destinationURL = uniqueURL(in: libraryRoot, preferredName: url.lastPathComponent, isDirectory: false)
                    do {
                        try FileManager.default.copyItem(at: url, to: destinationURL)
                        return destinationURL
                    } catch {
                        logger.error("import-archive-copy-failed source=\(url.path, privacy: .public) target=\(destinationURL.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                        return nil
                    }
                }) ?? nil else { return nil }
                destinationURL = copiedURL
            }

            let bookmark = createBookmark(for: destinationURL)
            guard let bookmark else { return nil }
            let coverData = try? archiveImageData(
                archiveURL: destinationURL,
                entryPath: firstEntry.path,
                encodingRawValue: firstEntry.encodingRawValue,
                format: firstEntry.format
            )
            let coverPath = cacheCoverData(
                coverData,
                cacheKey: coverCacheKey(for: destinationURL, suffix: firstEntry.path)
            ) ?? archivePageURL(
                archiveURL: destinationURL,
                entry: firstEntry,
                index: 0
            ).absoluteString
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

    /// EPUB 导入：将图片提取到库内文件夹，bookmark 指向文件夹，避免反复读 zip
    nonisolated private static func importEPUBAsImageFolder(url: URL, destinationRoot: URL?) async -> ImportResult? {
        do {
            // 1. 解析 EPUB 获取有序图片路径
            let entries = try epubImageEntries(in: url)
            guard !entries.isEmpty else {
                logger.error("import-epub-no-images path=\(url.lastPathComponent, privacy: .public)")
                return nil
            }

            // 2. 在库内创建图片文件夹
            guard let folderURL = withLibraryWriteAccess(destinationRoot: destinationRoot, { libraryRoot -> URL? in
                let folderName = sanitizedFolderName(url.deletingPathExtension().lastPathComponent)
                let folderURL = uniqueFolder(in: libraryRoot, preferredName: folderName)
                do {
                    try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
                    return folderURL
                } catch {
                    logger.error("import-epub-create-folder failed path=\(folderURL.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                    return nil
                }
            }) ?? nil else { return nil }

            // 3. 逐页提取图片到文件夹
            let pathEncoding = entries.first?.encodingRawValue.flatMap { String.Encoding(rawValue: $0) }
            let archive = try compatibleZIPArchive(url: url, pathEncoding: pathEncoding)
            var extractedCount = 0
            for (index, entry) in entries.enumerated() {
                let rawExt = (entry.path as NSString).pathExtension.lowercased()
                let fileExt = rawExt.isEmpty ? "jpg" : rawExt
                let destFile = folderURL.appendingPathComponent(String(format: "%05d.%@", index + 1, fileExt))
                do {
                    let data = try zipEntryData(archive: archive, entryPath: entry.path, encoding: pathEncoding, maximumBytes: maxArchiveImageBytes)
                    try data.write(to: destFile, options: .atomic)
                    extractedCount += 1
                } catch {
                    logger.warning("import-epub-extract-page-failed index=\(index) path=\(entry.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                }
            }

            guard extractedCount > 0 else {
                logger.error("import-epub-all-pages-failed path=\(url.lastPathComponent, privacy: .public)")
                try? FileManager.default.removeItem(at: folderURL)
                return nil
            }

            // 4. 生成封面（第一页图片直接作为封面）
            let firstEntryPath = entries.first?.path ?? ""
            let firstPathExt = (firstEntryPath as NSString).pathExtension.lowercased()
            let coverFileExt = firstPathExt.isEmpty ? "jpg" : firstPathExt
            let firstImageURL = folderURL.appendingPathComponent(String(format: "%05d.%@", 1, coverFileExt))
            let coverPath: String?
            if let imageData = try? Data(contentsOf: firstImageURL),
               imageData.count > 100,
               isDecodableImageData(imageData) {
                let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                let coverDir = cacheDir.appendingPathComponent("MReaderCoverCache", isDirectory: true)
                try? FileManager.default.createDirectory(at: coverDir, withIntermediateDirectories: true)
                let coverFile = coverDir.appendingPathComponent("\(folderURL.lastPathComponent).jpg")
                try? imageData.write(to: coverFile, options: .atomic)
                coverPath = coverFile.path
            } else {
                coverPath = nil
            }

            // 5. 创建 bookmark 指向文件夹
            let bookmark = createBookmark(for: folderURL)
            guard let bookmark else {
                try? FileManager.default.removeItem(at: folderURL)
                return nil
            }

            return ImportResult(
                title: url.deletingPathExtension().lastPathComponent,
                pagesCount: extractedCount,
                bookmarkData: bookmark,
                coverImagePath: coverPath,
                fileSize: folderSize(folderURL),
                libraryPath: folderURL.path,
                chapterTypeRaw: ChapterType.folder.rawValue,
                chapterPath: folderURL.path
            )
        } catch {
            logger.error("import-epub-failed path=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
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

    /// 只读地把原 PDF 的某一页渲染为 JPEG Data。仅读取源 PDF，绝不改写或删除原文件。
    nonisolated private static func renderPDFPageJPEGData(from pdfURL: URL, pageIndex: Int, scale: CGFloat = 1.5) -> Data? {
        guard let document = PDFDocument(url: pdfURL),
              document.pageCount > 0,
              let page = document.page(at: pageIndex) else { return nil }
        let pageRect = page.bounds(for: .mediaBox)
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
        return image.jpegData(compressionQuality: 0.85)
    }

    /// 为本地库中的 PDF 生成“只读”章节结果：保留原 PDF 文件与路径，章节按 PDF 类型登记，
    /// 阅读时由 loadPages 通过 PDFDocument(url:) 按页渲染到临时缓存读取。扫描/封面重建过程绝不删除或改写原 PDF。
    nonisolated private static func pdfChapterResult(from pdfURL: URL) -> ImportResult? {
        guard let document = PDFDocument(url: pdfURL), document.pageCount > 0 else { return nil }
        guard let bookmark = createBookmark(for: pdfURL) else { return nil }
        let coverPath = cacheCoverData(
            renderPDFPageJPEGData(from: pdfURL, pageIndex: 0),
            cacheKey: coverCacheKey(for: pdfURL, suffix: "pdf-cover"),
            forceOverwrite: true
        )
        return ImportResult(
            title: pdfURL.deletingPathExtension().lastPathComponent,
            pagesCount: document.pageCount,
            bookmarkData: bookmark,
            coverImagePath: coverPath,
            fileSize: folderSize(pdfURL),
            libraryPath: pdfURL.path,
            chapterTypeRaw: ChapterType.pdf.rawValue,
            chapterPath: pdfURL.path
        )
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
        let didStartLibraryAccess = libraryRoot.startAccessingSecurityScopedResource()
        defer {
            if didStartLibraryAccess {
                libraryRoot.stopAccessingSecurityScopedResource()
            }
        }
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

    /// 移动本地漫画文件到目标文件夹，返回新位置的 bookmarkData
    nonisolated static func moveComicFile(bookmarkData: Data, to destinationFolder: URL) -> Data? {
        guard let sourceURL = try? resolveBookmark(bookmarkData) else { return nil }
        let isSecurityScoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if isSecurityScoped { sourceURL.stopAccessingSecurityScopedResource() } }

        return withSelectedLibraryRoot { libraryRoot -> Data? in
            let standardizedRoot = libraryRoot.standardizedFileURL
            let standardizedDestination = destinationFolder.standardizedFileURL
            let rootPath = standardizedRoot.path
            let destinationPath = standardizedDestination.path
            guard destinationPath == rootPath || destinationPath.hasPrefix(rootPath + "/") else {
                return nil
            }

            let fileName = sourceURL.lastPathComponent
            let destinationURL = standardizedDestination.appendingPathComponent(
                fileName,
                isDirectory: sourceURL.hasDirectoryPath
            )
            guard destinationURL.path != sourceURL.standardizedFileURL.path else {
                return bookmarkData
            }

            do {
                try FileManager.default.createDirectory(
                    at: standardizedDestination,
                    withIntermediateDirectories: true
                )
                let finalURL: URL
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    finalURL = uniqueURL(
                        in: standardizedDestination,
                        preferredName: fileName,
                        isDirectory: sourceURL.hasDirectoryPath
                    )
                } else {
                    finalURL = destinationURL
                }
                try FileManager.default.moveItem(at: sourceURL, to: finalURL)
                return createBookmark(for: finalURL)
            } catch {
                logger.error("move-comic-file-failed source=\(sourceURL.path, privacy: .public) dest=\(destinationURL.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                return nil
            }
        } ?? nil
    }

    /// 获取移动后文件的新 libraryPath
    nonisolated static func libraryPathOfMovedFile(oldBookmark: Data, newBookmark: Data) -> String? {
        guard let newURL = try? resolveBookmark(newBookmark) else { return nil }
        return newURL.path
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
            return url
        } catch {
            return nil
        }
    }

    /// Returns a portable path relative to the selected library root. The absolute
    /// sandbox/security-scoped path is deliberately not used for cross-device identity.
    nonisolated static func libraryRelativePath(for url: URL) -> String? {
        guard let root = selectedLibraryRootURL() else { return nil }
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath == rootPath || filePath.hasPrefix(rootPath + "/") else { return nil }
        guard filePath.count > rootPath.count else { return nil }
        return String(filePath.dropFirst(rootPath.count + 1))
            .split(separator: "/", omittingEmptySubsequences: true)
            .joined(separator: "/")
    }

    nonisolated static func withSelectedLibraryRoot<T>(_ body: (URL) throws -> T) rethrows -> T? {
        guard let url = selectedLibraryRootURL() else { return nil }
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try body(url)
    }

    nonisolated private static func withLibraryWriteAccess<T>(
        destinationRoot: URL?,
        _ body: (URL) throws -> T
    ) rethrows -> T? {
        guard let selectedRoot = selectedLibraryRootURL() else { return nil }
        let targetRoot = (destinationRoot ?? selectedRoot).standardizedFileURL
        let selectedPath = selectedRoot.standardizedFileURL.path
        let targetPath = targetRoot.path
        guard targetPath == selectedPath || targetPath.hasPrefix(selectedPath + "/") else {
            return nil
        }
        let didStart = selectedRoot.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                selectedRoot.stopAccessingSecurityScopedResource()
            }
        }
        return try body(targetRoot)
    }

    nonisolated static func readableLocalLibraryAddress() -> String {
        selectedLibraryRootURL()?.path ?? "未选择漫画库"
    }

    nonisolated static func localLibraryURLForOpening() -> URL? {
        selectedLibraryRootURL()
    }

    nonisolated static func urlForLibraryPath(_ path: String?) -> URL? {
        guard let path else { return nil }
        return URL(fileURLWithPath: path)
    }

    nonisolated static func deleteLibraryPath(_ path: String?) {
        guard let path else { return }
        let url = URL(fileURLWithPath: path)
        guard isInsideLocalLibrary(url) else { return }
        _ = withSelectedLibraryRoot { _ in
            try? FileManager.default.removeItem(at: url)
        }
    }

    nonisolated static func temporaryImportCacheSize() -> Int64 {
        folderSize(temporaryImportRoot()) +
            folderSize(archiveCompatibilityCacheRoot()) +
            folderSize(webUploadTemporaryRoot())
    }

    nonisolated static func clearTemporaryImportCache() {
        try? FileManager.default.removeItem(at: temporaryImportRoot())
        try? FileManager.default.removeItem(at: webUploadTemporaryRoot())
        try? FileManager.default.removeItem(at: archiveCompatibilityCacheRoot())
        LocalWebServer.clearStaleBodyFiles()
    }

    nonisolated private static func archiveCompatibilityCacheRoot() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ArchiveCompatibility", isDirectory: true)
    }

    nonisolated static func rebuildCoverImage(bookmarkData: Data) -> String? {
        do {
            let url = try resolveBookmark(bookmarkData)
            let didStart = url.startAccessingSecurityScopedResource()
            defer {
                if didStart {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            if isReadableArchive(url) {
                guard let firstEntry = try archiveImageEntries(in: url).first else { return nil }
                let data = try? archiveImageData(
                    archiveURL: url,
                    entryPath: firstEntry.path,
                    encodingRawValue: firstEntry.encodingRawValue,
                    format: firstEntry.format
                )
                return cacheCoverData(data, cacheKey: coverCacheKey(for: url, suffix: firstEntry.path), forceOverwrite: true)
            }
            if url.pathExtension.lowercased() == "pdf" {
                // 封面重建同样只读：仅渲染原 PDF 首页到封面缓存，绝不删除或改写原文件。
                return cacheCoverData(
                    renderPDFPageJPEGData(from: url, pageIndex: 0),
                    cacheKey: coverCacheKey(for: url, suffix: "pdf-cover"),
                    forceOverwrite: true
                )
            }
            return cacheCoverImage(from: firstImageURL(from: url), cacheKey: coverCacheKey(for: url, suffix: "folder"), forceOverwrite: true)
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

    nonisolated static func inspectImportFolder(_ url: URL) -> ImportFolderInspection {
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return ImportFolderInspection(hasDirectImages: false, importableChildren: [])
        }
        var hasDirectImages = false
        var importableChildren: [URL] = []
        for child in contents.sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) {
            let ext = child.pathExtension.lowercased()
            if supportedImageExtensions.contains(ext) {
                hasDirectImages = true
            } else if isDirectory(child) || isReadableArchive(child) || supportedDocumentExtensions.contains(ext) {
                importableChildren.append(child)
            }
        }
        return ImportFolderInspection(hasDirectImages: hasDirectImages, importableChildren: importableChildren)
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

    nonisolated static func webUploadTemporaryRoot() -> URL {
        temporaryImportRoot().appendingPathComponent("WebUploads", isDirectory: true)
    }

    /// Returns the same page-extension decision used by local folder scanning.
    /// Offline translation source identity must hash exactly the files the
    /// reader can treat as comic pages.
    nonisolated static func isSupportedImageFile(_ url: URL) -> Bool {
        supportedImageExtensions.contains(url.pathExtension.lowercased())
    }

    nonisolated private static let supportedImageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "heic", "heif"]
    nonisolated private static let supportedArchiveExtensions: Set<String> = ["zip", "cbz", "epub"]
    nonisolated private static let unsupportedArchiveExtensions: Set<String> = ["7z", "rar", "cbr"]
    nonisolated private static let supportedDocumentExtensions: Set<String> = ["pdf"]

    nonisolated private static func isInsideLocalLibrary(_ url: URL) -> Bool {
        withSelectedLibraryRoot { libraryRoot in
            let rootPath = libraryRoot.standardizedFileURL.path
            let path = url.standardizedFileURL.path
            return path == rootPath || path.hasPrefix(rootPath + "/")
        } ?? false
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
            return isDirectory(child) || isReadableArchive(child) || supportedDocumentExtensions.contains(ext)
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
            // 扫描只读：PDF 作为 PDF 章节保留原文件与路径，不转换、不删除原 PDF。
            guard let result = pdfChapterResult(from: url) else { return nil }
            return ScannedChapter(
                title: result.title,
                chapterType: .pdf,
                path: result.libraryPath,
                importResult: result
            )
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
            return nil
        }
        if supportedArchiveExtensions.contains(ext) {
            return nil
        }
        return sourceURL
    }

    nonisolated static func isArchivePageURL(_ url: URL) -> Bool {
        url.scheme == archivePageScheme
    }

    nonisolated static func archivePageCacheKey(for url: URL) -> String? {
        guard let (archiveURL, entryPath, _, _) = archivePageComponents(from: url),
              let values = try? archiveURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else {
            return nil
        }
        let modification = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = values.fileSize ?? 0
        return "\(archiveURL.path)#\(size)#\(modification)#\(entryPath)"
    }

    nonisolated static func imageData(
        forArchivePageURL url: URL,
        securityScopedAccessHeld: Bool = false
    ) -> Data? {
        guard let (archiveURL, entryPath, encodingRawValue, format) = archivePageComponents(from: url) else {
            logger.error("archive-page-url-invalid url=\(url.absoluteString, privacy: .public)")
            return nil
        }
        let readData = {
            try archiveImageData(
                archiveURL: archiveURL,
                entryPath: entryPath,
                encodingRawValue: encodingRawValue,
                format: format
            )
        }
        do {
            let data: Data
            if securityScopedAccessHeld {
                data = try readData()
            } else if let scopedData = try withSelectedLibraryRoot({ _ in try readData() }) {
                data = scopedData
            } else {
                data = try readData()
            }
            guard !data.isEmpty else {
                logger.error("archive-page-empty archive=\(archiveURL.lastPathComponent, privacy: .public) entry=\(entryPath, privacy: .public)")
                return nil
            }
            return data
        } catch {
            logger.error(
                "archive-page-read-failed archive=\(archiveURL.lastPathComponent, privacy: .public) entry=\(entryPath, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// 只读取归档页图片的尺寸，不整张解码像素（审查 #18）。
    /// 用增量 ImageIO 边解压边尝试读宽高；ZIPFoundation 暂不支持提前中断解压，
    /// 但一旦拿到尺寸就不再做后续工作，也无需构造完整 Data。
    nonisolated static func imagePixelSizeForArchivePageURL(_ url: URL) -> CGSize? {
        guard let (archiveURL, entryPath, encodingRawValue, format) = archivePageComponents(from: url),
              format == .zip else {
            return nil
        }
        let readSize: () throws -> CGSize? = {
            let encoding = encodingRawValue.map { String.Encoding(rawValue: $0) }
            let archive = try compatibleZIPArchive(url: archiveURL, pathEncoding: encoding)
            let normalizedTarget = normalizedArchivePath(entryPath)
            guard let entry = archive.first(where: { entry in
                let path = encoding.map { entry.path(using: $0) } ?? entry.path
                return normalizedArchivePath(path).caseInsensitiveCompare(normalizedTarget) == .orderedSame
            }) else {
                return nil
            }
            let source = CGImageSourceCreateIncremental(nil)
            var accumulated = Data()
            var result: CGSize?
            _ = try archive.extract(entry, skipCRC32: false) { chunk in
                guard result == nil else { return }
                guard UInt64(accumulated.count) + UInt64(chunk.count) <= maxArchiveImageBytes else {
                    throw ArchiveReadError.memoryLimit
                }
                accumulated.append(chunk)
                CGImageSourceUpdateData(source, accumulated as CFData, false)
                if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                   let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
                   let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
                   width > 0, height > 0 {
                    result = CGSize(width: width, height: height)
                }
            }
            return result
        }
        do {
            if let size = try withSelectedLibraryRoot({ _ in try readSize() }) {
                return size
            }
            return try readSize()
        } catch {
            return nil
        }
    }

    nonisolated static func zipImportFailureReason(for url: URL) -> String {
        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        defer { if isSecurityScoped { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.lowercased()
        guard isReadableArchive(url) else {
            if isUnsupportedArchiveExtension(ext) {
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
        ext == "zip" || ext == "cbz" || ext == "epub"
    }

    nonisolated private static func isUnsupportedArchiveExtension(_ ext: String) -> Bool {
        unsupportedArchiveExtensions.contains(ext)
    }

    nonisolated private static func isReadableArchive(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return canReadArchiveExtension(ext)
    }

    nonisolated private static func archiveImageEntries(in archiveURL: URL) throws -> [ArchiveImageEntry] {
        if archiveURL.pathExtension.lowercased() == "epub" {
            return try epubImageEntries(in: archiveURL)
        }
        switch archiveFormat(for: archiveURL) {
        case .zip:
            return try zipImageEntries(in: archiveURL)
        }
    }

    nonisolated static func archivePageCountForDiagnostics(at archiveURL: URL) throws -> Int {
        try archiveImageEntries(in: archiveURL).count
    }

    nonisolated static func archiveFirstPageDataForDiagnostics(at archiveURL: URL) throws -> Data {
        guard let first = try archiveImageEntries(in: archiveURL).first else {
            throw ArchiveReadError.noImages
        }
        return try archiveImageData(
            archiveURL: archiveURL,
            entryPath: first.path,
            encodingRawValue: first.encodingRawValue,
            format: first.format
        )
    }

    nonisolated static func archiveFirstPageURLForDiagnostics(at archiveURL: URL) throws -> URL {
        guard let first = try archiveImageEntries(in: archiveURL).first else {
            throw ArchiveReadError.noImages
        }
        return archivePageURL(archiveURL: archiveURL, entry: first, index: 0)
    }

    nonisolated static func archivePageDataForDiagnostics(at archiveURL: URL, index: Int) throws -> Data {
        let entries = try archiveImageEntries(in: archiveURL)
        guard entries.indices.contains(index) else {
            throw ArchiveReadError.noImages
        }
        let pageURL = archivePageURL(archiveURL: archiveURL, entry: entries[index], index: index)
        guard let data = imageData(forArchivePageURL: pageURL) else {
            throw ArchiveReadError.damagedArchive
        }
        return data
    }

    nonisolated private static func archiveImageData(archiveURL: URL, entryPath: String, encodingRawValue: UInt?, format: ArchiveFormat) throws -> Data {
        switch format {
        case .zip:
            return try zipImageData(archiveURL: archiveURL, entryPath: entryPath, encodingRawValue: encodingRawValue)
        }
    }

    nonisolated private static func archiveFormat(for _: URL) -> ArchiveFormat {
        return .zip
    }

    nonisolated private static func zipImageEntries(in archiveURL: URL) throws -> [ArchiveImageEntry] {
        guard FileManager.default.isReadableFile(atPath: archiveURL.path) else {
            throw ArchiveReadError.permissionDenied
        }

        var lastError: Error?
        for encoding in zipPathEncodings() {
            do {
                let archive = try compatibleZIPArchive(url: archiveURL, pathEncoding: encoding)
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
        let archive = try compatibleZIPArchive(url: archiveURL, pathEncoding: encoding)
        return try zipEntryData(archive: archive, entryPath: entryPath, encoding: encoding, maximumBytes: maxArchiveImageBytes)
    }

    nonisolated private static func zipEntryData(
        archive: Archive,
        entryPath: String,
        encoding: String.Encoding?,
        maximumBytes: UInt64
    ) throws -> Data {
        let normalizedTarget = normalizedArchivePath(entryPath)
        guard let entry = archive.first(where: { entry in
            let path = encoding.map { entry.path(using: $0) } ?? entry.path
            return normalizedArchivePath(path).caseInsensitiveCompare(normalizedTarget) == .orderedSame
        }) else {
            let samplePaths = archive.prefix(8).map { entry in
                encoding.map { entry.path(using: $0) } ?? entry.path
            }
            logger.error(
                "zip-entry-not-found target=\(entryPath, privacy: .public) samples=\(samplePaths.joined(separator: " | "), privacy: .public)"
            )
            throw ArchiveReadError.encodingFailed
        }
        guard entry.uncompressedSize <= maximumBytes else {
            throw ArchiveReadError.memoryLimit
        }
        var data = Data()
        data.reserveCapacity(Int(min(entry.uncompressedSize, UInt64(Int.max))))
        do {
            _ = try archive.extract(entry, skipCRC32: false) { chunk in
                guard UInt64(data.count) + UInt64(chunk.count) <= maximumBytes else {
                    throw ArchiveReadError.memoryLimit
                }
                data.append(chunk)
            }
            return data
        } catch let error as ArchiveReadError {
            throw error
        } catch {
            throw ArchiveReadError.damagedArchive
        }
    }

    nonisolated private static func epubImageEntries(in archiveURL: URL) throws -> [ArchiveImageEntry] {
        var lastError: Error?
        for encoding in zipPathEncodings() {
            do {
                let archive = try compatibleZIPArchive(url: archiveURL, pathEncoding: encoding)
                let paths = archive.compactMap { entry -> String? in
                    guard entry.type == .file else { return nil }
                    return encoding.map { entry.path(using: $0) } ?? entry.path
                }
                let pathLookup = paths.reduce(into: [String: String]()) { result, path in
                    result[path.lowercased()] = result[path.lowercased()] ?? path
                }

                // 1. 解析 container.xml 获取 OPF 路径
                let containerData = try zipEntryData(
                    archive: archive,
                    entryPath: pathLookup["meta-inf/container.xml"] ?? "META-INF/container.xml",
                    encoding: encoding,
                    maximumBytes: 2_000_000
                )
                guard let containerXML = decodedXMLText(containerData) else {
                    throw ArchiveReadError.encodingFailed
                }

                // 尝试多种方式提取 OPF 路径
                var opfPathValue: String? = nil
                // 标准方式: <rootfile full-path="..." media-type="...">
                opfPathValue = firstRegexCapture(#"<rootfile\b[^>]*\bfull-path\s*=\s*["']([^"']+)["']"#, in: containerXML)
                // 备选: 直接找 .opf 文件
                if opfPathValue == nil {
                    opfPathValue = firstRegexCapture(#"["']([^"']*\.opf)["']"#, in: containerXML)
                }
                // 备选: 遍历所有 <rootfile> 标签
                if opfPathValue == nil {
                    for rootfileTag in regexMatches(#"<rootfile\b[^>]*>"#, in: containerXML) {
                        if let path = xmlAttribute("full-path", in: rootfileTag) {
                            opfPathValue = path
                            break
                        }
                    }
                }
                guard let opfPathValue else {
                    throw ArchiveReadError.encodingFailed
                }

                let opfPath = pathLookup[opfPathValue.lowercased()] ?? opfPathValue
                let opfData = try zipEntryData(
                    archive: archive,
                    entryPath: opfPath,
                    encoding: encoding,
                    maximumBytes: 5_000_000
                )
                guard let opfXML = decodedXMLText(opfData) else {
                    throw ArchiveReadError.encodingFailed
                }

                let opfFolder = (opfPath as NSString).deletingLastPathComponent

                // 2. 解析 manifest（所有资源项）
                var manifest: [String: (path: String, mediaType: String, properties: String)] = [:]
                var manifestOrder: [String] = []
                for tag in regexMatches(#"<item\b[^>]*>"#, in: opfXML) {
                    guard let id = xmlAttribute("id", in: tag),
                          let href = xmlAttribute("href", in: tag) else { continue }
                    let resolved = resolveArchivePath(baseFolder: opfFolder, relativePath: href)
                    manifest[id] = (
                        path: pathLookup[resolved.lowercased()] ?? resolved,
                        mediaType: xmlAttribute("media-type", in: tag) ?? "",
                        properties: xmlAttribute("properties", in: tag) ?? ""
                    )
                    manifestOrder.append(id)
                }

                // 3. 解析 spine（页面顺序）
                let spineTags = regexMatches(#"<itemref\b[^>]*>"#, in: opfXML)
                var orderedPaths: [String] = []
                var resolvedSpineItems = 0
                var xhtmlImageReferenceCount = 0
                for tag in spineTags {
                    guard let idref = xmlAttribute("idref", in: tag),
                          let item = manifest[idref] else { continue }
                    resolvedSpineItems += 1

                    // 直接是图片类型
                    if item.mediaType.lowercased().hasPrefix("image/") || isValidArchiveImagePath(item.path) {
                        orderedPaths.append(item.path)
                        continue
                    }

                    // HTML/XHTML 页面 → 提取其中引用的图片
                    if item.mediaType.lowercased().contains("html") ||
                       item.mediaType.lowercased().contains("xml") ||
                       item.path.lowercased().hasSuffix(".html") ||
                       item.path.lowercased().hasSuffix(".xhtml") ||
                       item.path.lowercased().hasSuffix(".htm") {
                        guard let pageData = try? zipEntryData(
                            archive: archive,
                            entryPath: item.path,
                            encoding: encoding,
                            maximumBytes: 3_000_000
                        ),
                        let pageText = decodedXMLText(pageData) else {
                            logger.warning(
                                "epub-xhtml-read-failed archive=\(archiveURL.lastPathComponent, privacy: .public) entry=\(item.path, privacy: .public)"
                            )
                            continue
                        }
                        let pageFolder = (item.path as NSString).deletingLastPathComponent

                        // 提取 <img src="..."> 引用
                        let imgRefs = regexMatches(#"<img\b[^>]*\bsrc\s*=\s*["']([^"']+)["']"#, in: pageText, captureGroup: 1)
                        // 提取 <image xlink:href="..."> 引用（SVG）
                        let svgRefs = regexMatches(#"<image\b[^>]*\bxlink:href\s*=\s*["']([^"']+)["']"#, in: pageText, captureGroup: 1)
                        // 提取 CSS url(...) 引用
                        let cssRefs = regexMatches(#"url\s*\(\s*["']?([^"')]+)["']?\s*\)"#, in: pageText, captureGroup: 1)
                        // 宽松兜底：兼容 namespace、属性顺序和部分不规范 XHTML。
                        let genericRefs = regexMatches(
                            #"(?:src|href|xlink:href)\s*=\s*["']([^"']+)["']"#,
                            in: pageText,
                            captureGroup: 1
                        )

                        let allRefs = Array(Set(imgRefs + svgRefs + cssRefs + genericRefs))
                        var foundImageInPage = false
                        for reference in allRefs {
                            let resolved = resolveArchivePath(baseFolder: pageFolder, relativePath: reference)
                            if let actual = pathLookup[resolved.lowercased()],
                               isValidArchiveImagePath(actual) {
                                orderedPaths.append(actual)
                                foundImageInPage = true
                                xhtmlImageReferenceCount += 1
                            }
                        }
                        // 如果 HTML 里没找到有效图片，但 HTML 本身可能是一个图片页（如全页图）
                        if !foundImageInPage && isValidArchiveImagePath(item.path) {
                            orderedPaths.append(item.path)
                        }
                    }
                }

                // 4. 处理 cover-image（确保封面在最前面）
                let coverID = regexMatches(#"<meta\b[^>]*>"#, in: opfXML)
                    .first(where: { xmlAttribute("name", in: $0)?.lowercased() == "cover" })
                    .flatMap { xmlAttribute("content", in: $0) }
                let coverFromProps = manifest.first(where: { $0.value.properties.split(separator: " ").contains("cover-image") })?.value.path
                let coverFromMeta = coverID.flatMap { manifest[$0]?.path }
                let coverFromGuide = regexMatches(#"<reference\b[^>]*>"#, in: opfXML)
                    .first(where: { xmlAttribute("type", in: $0)?.lowercased().contains("cover") == true })
                    .flatMap { tag -> String? in
                        guard let href = xmlAttribute("href", in: tag) else { return nil }
                        let resolved = resolveArchivePath(baseFolder: opfFolder, relativePath: href)
                        return pathLookup[resolved.lowercased()] ?? resolved
                    }
                let coverPath = coverFromProps ?? coverFromMeta ?? coverFromGuide

                if let coverPath, isValidArchiveImagePath(coverPath) {
                    orderedPaths.removeAll { $0.caseInsensitiveCompare(coverPath) == .orderedSame }
                    orderedPaths.insert(coverPath, at: 0)
                }

                // 部分制作工具会生成不规范 XHTML。spine 无法完整解析时，仍按 OPF manifest
                // 中的图片声明顺序恢复图片页，避免整本书只剩封面。
                if orderedPaths.count <= 1 {
                    let manifestImages = manifestOrder.compactMap { id -> String? in
                        guard let item = manifest[id],
                              let actual = pathLookup[item.path.lowercased()],
                              (item.mediaType.lowercased().hasPrefix("image/") || isValidArchiveImagePath(actual)) else {
                            return nil
                        }
                        return actual
                    }
                    orderedPaths.append(contentsOf: manifestImages)
                }

                // 5. 去重并返回
                var seen = Set<String>()
                let uniquePaths = orderedPaths.filter { seen.insert($0.lowercased()).inserted }
                if !uniquePaths.isEmpty {
                    logger.info(
                        "epub-list path=\(archiveURL.lastPathComponent, privacy: .public) manifest=\(manifest.count, privacy: .public) spine=\(spineTags.count, privacy: .public) resolvedSpine=\(resolvedSpineItems, privacy: .public) xhtmlRefs=\(xhtmlImageReferenceCount, privacy: .public) images=\(uniquePaths.count, privacy: .public)"
                    )
                    return uniquePaths.map {
                        ArchiveImageEntry(path: $0, encodingRawValue: encoding?.rawValue, format: .zip)
                    }
                }

                // 6. 兜底：如果 spine 解析失败，直接扫描所有图片
                return try zipImageEntries(in: archiveURL)
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        throw ArchiveReadError.noImages
    }

    nonisolated private static func archiveCacheKey(path: String, fileSize: UInt64, modified: TimeInterval) -> String {
        // 持久缓存 key 必须是跨启动稳定的标识：不能用 hashValue，改用 SHA256(path+size+modified)
        let raw = "\(path)#\(fileSize)#\(Int(modified))"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func compatibleZIPArchive(
        url: URL,
        pathEncoding: String.Encoding?
    ) throws -> Archive {
        let offset = try zipLocalHeaderOffset(in: url)
        if offset == 0 {
            let directArchive = try Archive(url: url, accessMode: .read, pathEncoding: pathEncoding)
            if directArchive.makeIterator().next() != nil {
                return directArchive
            }
            guard let correction = try centralDirectoryCorrection(in: url) else {
                return directArchive
            }
            let patchedURL = try patchedCentralDirectoryArchiveURL(
                sourceURL: url,
                endRecordOffset: correction.endRecordOffset,
                centralDirectorySize: correction.centralDirectorySize,
                recordedCentralDirectoryOffset: correction.recordedOffset,
                correctedCentralDirectoryOffset: correction.correctedOffset
            )
            return try Archive(url: patchedURL, accessMode: .read, pathEncoding: pathEncoding)
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = archiveCacheKey(path: url.standardizedFileURL.path, fileSize: fileSize, modified: modified)
        let cacheRoot = archiveCompatibilityCacheRoot()
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let normalizedURL = cacheRoot.appendingPathComponent(
            "\(key)-\(fileSize)-\(Int(modified))-\(offset).zip"
        )

        if !FileManager.default.fileExists(atPath: normalizedURL.path) {
            let temporaryURL = normalizedURL.appendingPathExtension("partial")
            try? FileManager.default.removeItem(at: temporaryURL)
            FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)
            let reader = try FileHandle(forReadingFrom: url)
            let writer = try FileHandle(forWritingTo: temporaryURL)
            defer {
                try? reader.close()
                try? writer.close()
            }
            try reader.seek(toOffset: UInt64(offset))
            while autoreleasepool(invoking: {
                let chunk = try? reader.read(upToCount: 1_048_576)
                guard let chunk, !chunk.isEmpty else { return false }
                try? writer.write(contentsOf: chunk)
                return true
            }) {}
            try writer.synchronize()
            try FileManager.default.moveItem(at: temporaryURL, to: normalizedURL)
            logger.info(
                "zip-prefix-normalized path=\(url.lastPathComponent, privacy: .public) prefixBytes=\(offset, privacy: .public)"
            )
        }

        return try Archive(url: normalizedURL, accessMode: .read, pathEncoding: pathEncoding)
    }

    nonisolated private static func centralDirectoryCorrection(
        in url: URL
    ) throws -> (
        endRecordOffset: UInt64,
        centralDirectorySize: UInt32,
        recordedOffset: UInt32,
        correctedOffset: UInt32
    )? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        let tailSize = min(fileSize, 65_557)
        try handle.seek(toOffset: fileSize - tailSize)
        let tail = try handle.readToEnd() ?? Data()
        let endSignature = Data([0x50, 0x4B, 0x05, 0x06])
        guard let relativeRange = tail.range(of: endSignature, options: .backwards),
              relativeRange.lowerBound + 20 <= tail.count else {
            return nil
        }

        let recordOffset = fileSize - tailSize + UInt64(relativeRange.lowerBound)
        let centralDirectorySize = littleEndianUInt32(in: tail, offset: relativeRange.lowerBound + 12)
        let recordedOffset = littleEndianUInt32(in: tail, offset: relativeRange.lowerBound + 16)
        guard centralDirectorySize != UInt32.max, recordedOffset != UInt32.max else { return nil }
        let expectedEndRecordOffset = UInt64(recordedOffset) + UInt64(centralDirectorySize)
        guard recordOffset > expectedEndRecordOffset else { return nil }
        let delta = recordOffset - expectedEndRecordOffset
        guard delta <= UInt64(UInt32.max) - UInt64(recordedOffset) else { return nil }
        let correctedOffset = UInt32(UInt64(recordedOffset) + delta)

        try handle.seek(toOffset: UInt64(correctedOffset))
        let signature = try handle.read(upToCount: 4) ?? Data()
        guard signature == Data([0x50, 0x4B, 0x01, 0x02]) else { return nil }
        return (recordOffset, centralDirectorySize, recordedOffset, correctedOffset)
    }

    nonisolated private static func patchedCentralDirectoryArchiveURL(
        sourceURL: URL,
        endRecordOffset: UInt64,
        centralDirectorySize: UInt32,
        recordedCentralDirectoryOffset: UInt32,
        correctedCentralDirectoryOffset: UInt32
    ) throws -> URL {
        let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = archiveCacheKey(path: sourceURL.standardizedFileURL.path, fileSize: fileSize, modified: modified)
        let cacheRoot = archiveCompatibilityCacheRoot()
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let patchedURL = cacheRoot.appendingPathComponent(
            "\(key)-\(fileSize)-\(Int(modified))-cdv2-\(correctedCentralDirectoryOffset).zip"
        )
        guard !FileManager.default.fileExists(atPath: patchedURL.path) else {
            return patchedURL
        }

        let temporaryURL = patchedURL.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: temporaryURL)
        try FileManager.default.copyItem(at: sourceURL, to: temporaryURL)
        let handle = try FileHandle(forWritingTo: temporaryURL)
        defer { try? handle.close() }

        let reader = try FileHandle(forReadingFrom: sourceURL)
        defer { try? reader.close() }
        try reader.seek(toOffset: UInt64(correctedCentralDirectoryOffset))
        var centralDirectoryData = try reader.read(upToCount: Int(centralDirectorySize)) ?? Data()
        let offsetDelta = correctedCentralDirectoryOffset - recordedCentralDirectoryOffset
        var cursor = 0
        var patchedEntryCount = 0
        while cursor + 46 <= centralDirectoryData.count,
              centralDirectoryData[cursor..<(cursor + 4)] == Data([0x50, 0x4B, 0x01, 0x02]) {
            let fileNameLength = Int(littleEndianUInt16(in: centralDirectoryData, offset: cursor + 28))
            let extraLength = Int(littleEndianUInt16(in: centralDirectoryData, offset: cursor + 30))
            let commentLength = Int(littleEndianUInt16(in: centralDirectoryData, offset: cursor + 32))
            let localOffset = littleEndianUInt32(in: centralDirectoryData, offset: cursor + 42)
            if localOffset != UInt32.max {
                try reader.seek(toOffset: UInt64(localOffset))
                let recordedSignature = try reader.read(upToCount: 4) ?? Data()
                if recordedSignature != Data([0x50, 0x4B, 0x03, 0x04]) {
                    let correctedLocalOffset = localOffset + offsetDelta
                    try reader.seek(toOffset: UInt64(correctedLocalOffset))
                    let correctedSignature = try reader.read(upToCount: 4) ?? Data()
                    if correctedSignature == Data([0x50, 0x4B, 0x03, 0x04]) {
                        replaceLittleEndianUInt32(
                            in: &centralDirectoryData,
                            offset: cursor + 42,
                            value: correctedLocalOffset
                        )
                        patchedEntryCount += 1
                    }
                }
            }
            cursor += 46 + fileNameLength + extraLength + commentLength
        }

        try handle.seek(toOffset: UInt64(correctedCentralDirectoryOffset))
        try handle.write(contentsOf: centralDirectoryData)
        try handle.seek(toOffset: endRecordOffset + 16)
        var littleEndianOffset = correctedCentralDirectoryOffset.littleEndian
        let offsetData = withUnsafeBytes(of: &littleEndianOffset) { Data($0) }
        try handle.write(contentsOf: offsetData)
        try handle.synchronize()
        try FileManager.default.moveItem(at: temporaryURL, to: patchedURL)
        logger.info(
            "zip-central-directory-corrected path=\(sourceURL.lastPathComponent, privacy: .public) correctedOffset=\(correctedCentralDirectoryOffset, privacy: .public) localEntries=\(patchedEntryCount, privacy: .public)"
        )
        return patchedURL
    }

    nonisolated private static func littleEndianUInt16(in data: Data, offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        return data[offset..<(offset + 2)].enumerated().reduce(UInt16.zero) { result, element in
            result | (UInt16(element.element) << UInt16(element.offset * 8))
        }
    }

    nonisolated private static func littleEndianUInt32(in data: Data, offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return data[offset..<(offset + 4)].enumerated().reduce(UInt32.zero) { result, element in
            result | (UInt32(element.element) << UInt32(element.offset * 8))
        }
    }

    nonisolated private static func replaceLittleEndianUInt32(
        in data: inout Data,
        offset: Int,
        value: UInt32
    ) {
        guard offset >= 0, offset + 4 <= data.count else { return }
        var littleEndianValue = value.littleEndian
        withUnsafeBytes(of: &littleEndianValue) { bytes in
            data.replaceSubrange(offset..<(offset + 4), with: bytes)
        }
    }

    nonisolated private static func zipLocalHeaderOffset(in url: URL) throws -> Int {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let signatures = [
            Data([0x50, 0x4B, 0x03, 0x04]),
            Data([0x50, 0x4B, 0x05, 0x06]),
            Data([0x50, 0x4B, 0x07, 0x08])
        ]
        var consumed = 0
        var overlap = Data()
        let maximumPrefixBytes = 32 * 1_048_576

        while consumed < maximumPrefixBytes {
            guard let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty else { break }
            var searchData = overlap
            searchData.append(chunk)
            for signature in signatures {
                if let range = searchData.range(of: signature) {
                    return max(0, consumed - overlap.count + range.lowerBound)
                }
            }
            consumed += chunk.count
            overlap = searchData.suffix(3)
        }
        throw ArchiveReadError.damagedArchive
    }

    nonisolated private static func resolveArchivePath(baseFolder: String, relativePath: String) -> String {
        let decoded = relativePath.removingPercentEncoding ?? relativePath
        let withoutFragment = decoded.split(separator: "#", maxSplits: 1).first.map(String.init) ?? decoded
        let withoutQuery = withoutFragment.split(separator: "?", maxSplits: 1).first.map(String.init) ?? withoutFragment
        let combined = baseFolder.isEmpty ? withoutQuery : baseFolder + "/" + withoutQuery
        return canonicalArchivePath(combined)
    }

    nonisolated private static func normalizedArchivePath(_ path: String) -> String {
        canonicalArchivePath(path)
    }

    nonisolated private static func canonicalArchivePath(_ path: String) -> String {
        let slashPath = path.replacingOccurrences(of: "\\", with: "/")
        var components: [Substring] = []
        for component in slashPath.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if !components.isEmpty {
                    components.removeLast()
                }
            default:
                components.append(component)
            }
        }
        return components.joined(separator: "/")
    }

    nonisolated private static func decodedXMLText(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let text = String(data: data, encoding: .utf16) {
            return text
        }
        if let text = String(data: data, encoding: .utf16LittleEndian) {
            return text
        }
        if let text = String(data: data, encoding: .utf16BigEndian) {
            return text
        }
        if let text = String(data: data, encoding: .windowsCP1252) {
            return text
        }
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated private static func xmlAttribute(_ name: String, in tag: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        return firstRegexCapture(
            "(?:^|\\s)" + escapedName + "\\s*=\\s*[\"']([^\"']+)[\"']",
            in: tag
        )
    }

    nonisolated private static func firstRegexCapture(_ pattern: String, in value: String) -> String? {
        regexMatches(pattern, in: value, captureGroup: 1).first
    }

    nonisolated private static func regexMatches(_ pattern: String, in value: String, captureGroup: Int = 0) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.matches(in: value, range: range).compactMap { match in
            guard captureGroup < match.numberOfRanges,
                  let resultRange = Range(match.range(at: captureGroup), in: value) else { return nil }
            return String(value[resultRange])
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

    nonisolated private static func cacheCoverImage(from sourceURL: URL?, cacheKey: String, forceOverwrite: Bool = false) -> String? {
        guard let sourceURL else { return nil }
        let destination = coverCacheURL(cacheKey: cacheKey)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path), !forceOverwrite {
                return destination.path
            }
            if forceOverwrite {
                try? FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            return destination.path
        } catch {
            return nil
        }
    }

    nonisolated private static func cacheCoverData(_ data: Data?, cacheKey: String, forceOverwrite: Bool = false) -> String? {
        guard let data, isDecodableImageData(data) else {
            logger.warning("cover-cache-rejected-invalid-image key=\(cacheKey, privacy: .public)")
            return nil
        }
        let destination = coverCacheURL(cacheKey: cacheKey)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path), !forceOverwrite {
                if isDecodableImageFile(destination) {
                    return destination.path
                }
                try? FileManager.default.removeItem(at: destination)
            }
            if forceOverwrite {
                try? FileManager.default.removeItem(at: destination)
            }
            try data.write(to: destination, options: .atomic)
            return destination.path
        } catch {
            return nil
        }
    }

    nonisolated private static func isDecodableImageData(_ data: Data) -> Bool {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return false
        }
        return CGImageSourceGetCount(source) > 0
    }

    nonisolated private static func isDecodableImageFile(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return false
        }
        return CGImageSourceGetCount(source) > 0
    }

    nonisolated private static func coverCacheURL(cacheKey: String) -> URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let encoded = Data(cacheKey.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return applicationSupport.appendingPathComponent("MReaderCoverCache", isDirectory: true)
            .appendingPathComponent(encoded + ".jpg")
    }

    nonisolated private static func coverCacheKey(for url: URL, suffix: String) -> String {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = values?.fileSize ?? 0
        return "\(url.path)#\(suffix)#\(size)#\(mtime)"
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
        accessToken?.stop()
        accessToken = nil
        pages.removeAll()
    }
}
