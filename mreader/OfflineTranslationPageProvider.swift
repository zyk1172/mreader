import Foundation
import UIKit

nonisolated enum OfflineTranslationPageProviderError: LocalizedError, Sendable {
    case sourceUnavailable
    case pageUnavailable(Int)
    case imageDecodeFailed(Int)

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable:
            return "漫画源当前不可用"
        case .pageUnavailable(let page):
            return "无法读取第 \(page + 1) 页原图"
        case .imageDecodeFailed(let page):
            return "第 \(page + 1) 页图片无法解码"
        }
    }
}

/// 统一处理本地文件、归档、Komga 和 OPDS 页面。它只读取原始页数据，不写入 ReaderImageCache。
nonisolated enum OfflineTranslationPageProvider {
    final class SourceSession: @unchecked Sendable {
        private let scopedURL: URL?
        private let didStart: Bool

        init(comic: ComicBook) {
            guard comic.sourceType == .local,
                  let resolvedURL = try? ComicManager.resolveBookmark(comic.bookmarkData) else {
                scopedURL = nil
                didStart = false
                return
            }
            scopedURL = resolvedURL
            didStart = resolvedURL.startAccessingSecurityScopedResource()
        }

        deinit {
            if didStart { scopedURL?.stopAccessingSecurityScopedResource() }
        }

        nonisolated var hasActiveSecurityScope: Bool { didStart }
        nonisolated var resolvedURL: URL? { scopedURL }
    }

    static func sourceSession(for comic: ComicBook) -> SourceSession {
        SourceSession(comic: comic)
    }

    /// 目录漫画的 revision 会读取每张图片并汇总内容哈希；与 CBZ/PDF 的单文件 stat
    /// 不同，不能在每个并发 batch 都重复调用。它仅在建任务、恢复和最终激活前完整核验。
    static func usesExpensiveSourceRevision(
        for comic: ComicBook,
        session: SourceSession? = nil
    ) -> Bool {
        switch comic.sourceType {
        case .local:
            // 文件夹需要汇总所有页面字节，CBZ/PDF/EPUB 需要读取整个归档文件；两者
            // 都不能放进每个小 batch 的 revision 校验热路径。session 参数保留给
            // 调用方统一传递源访问上下文，但这里按源类型直接判定成本。
            return true
        case .komga, .opds:
            // 远程 revision 需要请求 Book 元数据或 HTTP headers，同样不能按每 3 页轮询。
            return true
        }
    }

    static func isReliableSourceRevision(_ revision: String?) -> Bool {
        guard let revision else { return false }
        return !revision.contains("-unverified:")
    }

    static func shouldPeriodicallyValidateSourceRevision(for comic: ComicBook) -> Bool {
        switch comic.sourceType {
        case .komga, .opds:
            return true
        case .local:
            return false
        }
    }

    static func sourceRevision(for comic: ComicBook, session: SourceSession? = nil) async throws -> String {
        try Task.checkCancellation()
        switch comic.sourceType {
        case .local:
            let resolvedURL = session.flatMap({ $0.hasActiveSecurityScope ? $0.resolvedURL : nil })
                ?? (try? ComicManager.resolveBookmark(comic.bookmarkData))
            guard let resolvedURL else {
                return "local-file-unverified:\(comic.libraryPath ?? "")#pages=\(comic.totalPages)"
            }
            let fallbackPath = comic.libraryPath ?? resolvedURL.standardizedFileURL.path
            let pageCount = comic.totalPages
            let fallbackRevision = resolvedURL.hasDirectoryPath
                ? "local-folder-unverified:\(fallbackPath)#pages=\(pageCount)"
                : "local-file-unverified:\(fallbackPath)#pages=\(pageCount)"
            let worker = Task.detached(priority: .utility) { [resolvedURL, fallbackPath, pageCount, session] () throws -> String in
                // 保持 SourceSession 存活，确保整个 detached worker 生命周期内 security-scoped
                // resource 仍然有效。具体 hash 工作在非 MainActor 上执行。
                _ = session
                if resolvedURL.hasDirectoryPath {
                    return try localFolderSourceRevisionThrowing(
                        at: resolvedURL,
                        fallbackPath: fallbackPath,
                        pageCount: pageCount
                    )
                }
                return try localFileSourceRevisionThrowing(
                    at: resolvedURL,
                    fallbackPath: fallbackPath,
                    pageCount: pageCount
                )
            }
            do {
                let revision = try await withTaskCancellationHandler(
                    operation: { try await worker.value },
                    onCancel: { worker.cancel() }
                )
                try Task.checkCancellation()
                return revision
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return fallbackRevision
            }
        case .komga:
            return await komgaSourceRevision(for: comic)
        case .opds:
            return await OPDSProvider.sourceRevision(for: comic)
        }
    }

    private static func komgaSourceRevision(for comic: ComicBook) async -> String {
        let fallback = "komga-unverified:\(comic.mediaSourceID?.uuidString ?? "")#\(comic.komgaBookID ?? "")#\(comic.remotePageCount ?? comic.totalPages)#\(comic.sourceURL ?? "")"
        guard let sourceID = comic.mediaSourceID,
              let bookID = comic.komgaBookID,
              let source = KomgaProvider.loadSources().first(where: { $0.id == sourceID && $0.type == .komga && $0.isEnabled }),
              let apiKey = KomgaProvider.apiKey(for: sourceID) else {
            return fallback
        }
        do {
            let resolvedURL = await KomgaProvider.resolveBestURL(source: source)
            let client = try KomgaAPIClient(baseURLString: resolvedURL, apiKey: apiKey)
            let book = try await client.book(bookID: bookID)
            guard let revision = book.contentRevision else { return fallback }
            return "komga:\(sourceID.uuidString)#\(bookID)#\(revision)"
        } catch {
            return fallback
        }
    }

    /// 文件夹漫画的父目录 mtime 不会随着内部图片内容替换而稳定更新；每个条目必须以
    /// 实际字节 SHA256 标识，避免同尺寸、恢复 mtime 的原地替换绕过版本检查。
    static func localFolderSourceRevision(
        at rootURL: URL,
        fallbackPath: String,
        pageCount: Int
    ) -> String {
        (try? localFolderSourceRevisionThrowing(
            at: rootURL,
            fallbackPath: fallbackPath,
            pageCount: pageCount
        )) ?? "local-folder-unverified:\(fallbackPath)#pages=\(pageCount)"
    }

    private static func localFolderSourceRevisionThrowing(
        at rootURL: URL,
        fallbackPath: String,
        pageCount: Int
    ) throws -> String {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return "local-folder:\(fallbackPath)#unavailable#pages=\(pageCount)"
        }

        let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "bmp", "heic", "heif", "tif", "tiff"]
        let rootPath = rootURL.standardizedFileURL.path
        var descriptors: [String] = []
        var couldNotHashEveryPage = false
        for case let fileURL as URL in enumerator {
            try Task.checkCancellation()
            guard imageExtensions.contains(fileURL.pathExtension.lowercased()),
                  let values = try? fileURL.resourceValues(forKeys: keys),
                  values.isRegularFile == true else {
                continue
            }
            let absolutePath = fileURL.standardizedFileURL.path
            let relativePath = absolutePath.hasPrefix(rootPath + "/")
                ? String(absolutePath.dropFirst(rootPath.count + 1))
                : absolutePath
            guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
                couldNotHashEveryPage = true
                break
            }
            descriptors.append("\(relativePath)#\(OfflineTranslationFingerprint.sha256(for: data))")
        }
        guard !couldNotHashEveryPage else {
            return "local-folder-unverified:\(fallbackPath)#pages=\(pageCount)"
        }
        descriptors.sort()
        let metadata = descriptors.joined(separator: "\n")
        let digest = OfflineTranslationFingerprint.sha256(for: Data(metadata.utf8))
        return "local-folder:\(fallbackPath)#\(digest)#pages=\(pageCount)"
    }

    /// 单文件漫画（CBZ/PDF/EPUB）的整本身份必须对应实际文件字节；仅使用 path、size 和
    /// mtime 会被同尺寸原地替换且恢复 mtime 的外部工具绕过。调用方只在建任务、恢复和
    /// 最终激活前执行，不放进逐页 batch 热路径。
    static func localFileSourceRevision(
        at fileURL: URL,
        fallbackPath: String,
        pageCount: Int
    ) -> String {
        (try? localFileSourceRevisionThrowing(
            at: fileURL,
            fallbackPath: fallbackPath,
            pageCount: pageCount
        )) ?? "local-file-unverified:\(fallbackPath)#pages=\(pageCount)"
    }

    private static func localFileSourceRevisionThrowing(
        at fileURL: URL,
        fallbackPath: String,
        pageCount: Int
    ) throws -> String {
        let digest = try OfflineTranslationFingerprint.sha256(fileAt: fileURL)
        return "local-file:\(fallbackPath)#\(digest)#pages=\(pageCount)"
    }
    static func loadPages(for comic: ComicBook) async -> [ComicPage]? {
        switch comic.sourceType {
        case .local:
            return await Task.detached(priority: .userInitiated) {
                ComicManager.loadPages(bookmarkData: comic.bookmarkData)?.pages
            }.value
        case .komga:
            return await RemotePageLoader.loadPages(for: comic)?.pages
        case .opds:
            return await OPDSProvider.loadPages(for: comic)?.pages
        }
    }

    static func data(for comic: ComicBook, page: ComicPage, session: SourceSession? = nil) async throws -> Data {
        try Task.checkCancellation()
        let data: Data?
        switch comic.sourceType {
        case .local:
            data = await localData(for: comic, pageURL: page.url, session: session)
        case .komga:
            data = RemotePageLoader.isRemotePageURL(page.url)
                ? await RemotePageLoader.imageData(forRemotePageURL: page.url)
                : try? Data(contentsOf: page.url)
        case .opds:
            data = ComicManager.isArchivePageURL(page.url)
                ? ComicManager.imageData(forArchivePageURL: page.url)
                : try? Data(contentsOf: page.url)
        }
        guard let data, !data.isEmpty else {
            throw OfflineTranslationPageProviderError.pageUnavailable(page.index)
        }
        return data
    }

    static func image(for data: Data, pageIndex: Int) throws -> UIImage {
        guard let image = UIImage(data: data) else {
            throw OfflineTranslationPageProviderError.imageDecodeFailed(pageIndex)
        }
        return image
    }

    /// 数据已经为 OCR/翻译读取到内存；直接计算内容哈希比信任 path + size + mtime 更可靠。
    /// 外部工具可以原地替换同尺寸图片并恢复 mtime，metadata 缓存会把新图误判为旧图。
    static func fingerprint(for data: Data, pageURL: URL? = nil) -> String {
        return OfflineTranslationFingerprint.sha256(for: data)
    }

    private static func localData(for comic: ComicBook, pageURL: URL, session: SourceSession?) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            let fallbackURL: URL?
            if session == nil, let resolvedURL = try? ComicManager.resolveBookmark(comic.bookmarkData) {
                fallbackURL = resolvedURL
            } else {
                fallbackURL = nil
            }
            let fallbackStarted = fallbackURL?.startAccessingSecurityScopedResource() ?? false
            defer {
                if fallbackStarted { fallbackURL?.stopAccessingSecurityScopedResource() }
            }
            if ComicManager.isArchivePageURL(pageURL) {
                return ComicManager.imageData(
                    forArchivePageURL: pageURL,
                    securityScopedAccessHeld: session?.hasActiveSecurityScope == true
                )
            }
            return try? Data(contentsOf: pageURL)
        }.value
    }
}

nonisolated enum OfflineTranslationOverlayResult: Sendable {
    case displayed(blocks: [TextBlock], setID: UUID)
    case confirmedNoText(setID: UUID)
    case unavailable
}

/// Reader 优先检查比 active 更新的工作 Set，再沿派生关系回退到旧 Set 和 active Set；关闭开关时完全不触碰 Translation Store。
enum OfflineTranslationOverlayProvider {
    static func validOverlay(
        comic: ComicBook,
        page: ComicPage,
        targetLanguage: TranslationTargetLanguage,
        sourceLanguage: TranslationSourceLanguage
    ) async -> OfflineTranslationOverlayResult {
        let storage = OfflineTranslationStorageManager.shared
        var roots: [OfflineTranslationSetManifest] = []
        if let latestWork = await storage.latestRenderableManifest(
            for: comic.id,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        ) {
            roots.append(latestWork)
        }
        if let active = await storage.activeManifest(for: comic.id, targetLanguage: targetLanguage),
           active.id != roots.first?.id {
            roots.append(active)
        }

        var candidateManifests: [OfflineTranslationSetManifest] = []
        var visitedSetIDs = Set<UUID>()
        for root in roots {
            let chain = await manifestChain(
                storage: storage,
                comicID: comic.id,
                startingFrom: root
            )
            for candidate in chain {
                guard visitedSetIDs.insert(candidate.id).inserted else { continue }
                candidateManifests.append(candidate)
            }
        }

        for (candidateIndex, candidate) in candidateManifests.enumerated() {
            guard candidate.sourceLanguage == sourceLanguage,
                  candidate.targetLanguage == targetLanguage,
                  let savedPage = await storage.page(
                    comicID: comic.id,
                    setID: candidate.id,
                    pageIndex: page.index
                  ),
                  savedPage.state.isUsableOverlay else {
                // 运行中 Set 当前页还未落盘时，继续尝试旧 active Set。
                continue
            }

            do {
                let session = OfflineTranslationPageProvider.sourceSession(for: comic)
                let sourceData = try await OfflineTranslationPageProvider.data(for: comic, page: page, session: session)
                let fingerprint = OfflineTranslationPageProvider.fingerprint(for: sourceData, pageURL: page.url)
                guard fingerprint == savedPage.sourceFingerprint else {
                    await storage.markPageStale(
                        comicID: comic.id,
                        setID: candidate.id,
                        pageIndex: page.index
                    )
                    continue
                }
                var pageToDisplay = savedPage
                if savedPage.state == .partial {
                    var fallbackPages: [OfflineTranslatedPage] = []
                    for fallbackManifest in candidateManifests.dropFirst(candidateIndex + 1)
                    where fallbackManifest.sourceLanguage == sourceLanguage
                        && fallbackManifest.targetLanguage == targetLanguage {
                        if let fallback = await storage.page(
                            comicID: comic.id,
                            setID: fallbackManifest.id,
                            pageIndex: page.index
                        ) {
                            fallbackPages.append(fallback)
                        }
                    }
                    pageToDisplay = preferredOverlayPage(
                        primary: savedPage,
                        fallbackPages: fallbackPages
                    )
                }

                let blocks = pageToDisplay.blocks.map { $0.textBlock() }
                if pageToDisplay.state == .noText {
                    return .confirmedNoText(setID: pageToDisplay.setID)
                }
                return .displayed(blocks: blocks, setID: pageToDisplay.setID)
            } catch {
                // 原图暂时不可读时不污染旧译文，继续尝试回退 Set。
                continue
            }
        }
        return .unavailable
    }

    /// partial 不能让旧译文中已完整翻译的气泡凭空消失。当前选择保守的整页回退：
    /// 只有存在相同原图版本的完整父页/active 页时才替换 partial；否则仍显示新页已完成部分。
    static func preferredOverlayPage(
        primary: OfflineTranslatedPage,
        fallbackPages: [OfflineTranslatedPage]
    ) -> OfflineTranslatedPage {
        guard primary.state == .partial else { return primary }
        return fallbackPages.first {
            $0.state == .completed
                && $0.sourceFingerprint == primary.sourceFingerprint
        } ?? primary
    }

    private static func manifestChain(
        storage: OfflineTranslationStorageManager,
        comicID: UUID,
        startingFrom manifest: OfflineTranslationSetManifest
    ) async -> [OfflineTranslationSetManifest] {
        var result: [OfflineTranslationSetManifest] = []
        var visited = Set<UUID>()
        var current: OfflineTranslationSetManifest? = manifest
        while let candidate = current, visited.insert(candidate.id).inserted {
            result.append(candidate)
            guard let parentID = candidate.derivedFromSetID else { break }
            current = await storage.manifest(comicID: comicID, setID: parentID)
        }
        return result
    }
}
