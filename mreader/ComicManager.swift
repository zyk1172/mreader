import PDFKit
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

        init(
            title: String,
            pagesCount: Int,
            bookmarkData: Data,
            coverImagePath: String?,
            fileSize: Int64,
            libraryPath: String,
            sourceTypeRaw: String = ComicSourceType.local.rawValue,
            sourceURL: String? = nil,
            smbPath: String? = nil
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
        }
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

    nonisolated private static let libraryRootBookmarkKey = "mreader.libraryRootBookmark"
    nonisolated private static let scanBatchSize = 25
    nonisolated private static let logger = Logger(subsystem: "MReader", category: "LibraryIO")

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
            let sortedURLs = getAllImages(from: url)
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
        let ext = sourceURL.pathExtension.lowercased()
        let pageSourceURL: URL

        if ext == "zip" || ext == "cbz" {
            guard let extractedURL = unzipArchive(sourceURL) else { return nil }
            pageSourceURL = extractedURL
        } else if ext == "pdf" {
            guard let extractedURL = extractImagesFromPDFSynchronously(sourceURL) else { return nil }
            pageSourceURL = extractedURL
        } else {
            pageSourceURL = sourceURL
        }

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

        let imageSourceURL: URL
        var temporaryExtractionURL: URL?

        if ext == "7z" {
            return nil
        } else if ext == "zip" || ext == "cbz" {
            guard let extractedURL = unzipArchive(url) else {
                return nil
            }
            temporaryExtractionURL = extractedURL
            imageSourceURL = extractedURL
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
                libraryPath: destinationFolder.path
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
        for batchStart in stride(from: 0, to: children.count, by: scanBatchSize) {
            let batchEnd = min(batchStart + scanBatchSize, children.count)
            autoreleasepool {
                for child in children[batchStart..<batchEnd] {
                    let ext = child.pathExtension.lowercased()
                    if ext == "zip" || ext == "cbz" {
                        if let imported = importArchiveAlreadyInLibrary(child) {
                            comics.append(imported)
                        }
                        continue
                    }

                    if ext == "pdf" {
                        if let imported = importPDFAlreadyInLibrary(child) {
                            comics.append(imported)
                        }
                        continue
                    }

                    if isDirectory(child), hasDirectImages(in: child), let result = importResultForLocalFolder(child) {
                        comics.append(result)
                        continue
                    }

                    if isDirectory(child) {
                        let childComics = scanSeriesFolder(child)
                        if !childComics.isEmpty {
                            series.append(ScannedSeries(title: child.lastPathComponent, libraryPath: child.path, comics: childComics))
                        }
                    }
                }
            }
            logMemory("scan-batch \(batchEnd)/\(children.count)")
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
            libraryPath: targetFolder.path
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
            libraryPath: folderURL.path
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

    nonisolated private static let supportedImageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "heic", "heif"]

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
            return isDirectory(child) || ["zip", "cbz", "pdf", "7z"].contains(ext)
        }
    }

    nonisolated private static func scanSeriesFolder(_ seriesURL: URL) -> [ImportResult] {
        guard let children = try? FileManager.default.contentsOfDirectory(at: seriesURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        var results: [ImportResult] = []
        for child in children {
            let ext = child.pathExtension.lowercased()
            if ext == "zip" || ext == "cbz" {
                if let imported = importArchiveAlreadyInLibrary(child) {
                    results.append(imported)
                }
            } else if ext == "pdf" {
                if let imported = importPDFAlreadyInLibrary(child) {
                    results.append(imported)
                }
            } else if isDirectory(child), let result = importResultForLocalFolder(child) {
                results.append(result)
            }
        }
        return results.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
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
