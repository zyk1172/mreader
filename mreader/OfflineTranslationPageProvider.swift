import Foundation
import UIKit

nonisolated private final class OfflineTranslationFingerprintCache: @unchecked Sendable {
    static let shared = OfflineTranslationFingerprintCache()

    private let lock = NSLock()
    private var values: [String: String] = [:]

    func value(for key: String, data: Data) -> String {
        lock.lock()
        if let cached = values[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let fingerprint = OfflineTranslationFingerprint.sha256(for: data)
        lock.lock()
        values[key] = fingerprint
        if values.count > 512 {
            values.removeValue(forKey: values.keys.first!)
        }
        lock.unlock()
        return fingerprint
    }
}

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

    static func sourceRevision(for comic: ComicBook, session: SourceSession? = nil) -> String {
        switch comic.sourceType {
        case .local:
            let resolvedURL = session.flatMap({ $0.hasActiveSecurityScope ? $0.resolvedURL : nil })
                ?? (try? ComicManager.resolveBookmark(comic.bookmarkData))
            let values = resolvedURL.flatMap {
                try? $0.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            }
            let path = resolvedURL?.standardizedFileURL.path ?? comic.libraryPath ?? ""
            let size = values?.fileSize ?? Int(comic.fileSize)
            let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            return "local:\(path)#\(size)#\(modified)#pages=\(comic.totalPages)"
        case .komga:
            return "komga:\(comic.mediaSourceID?.uuidString ?? "")#\(comic.komgaBookID ?? "")#\(comic.remotePageCount ?? comic.totalPages)#\(comic.sourceURL ?? "")"
        case .opds:
            return "opds:\(comic.sourceURL ?? comic.chapterPath ?? "")#pages=\(comic.totalPages)"
        }
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

    static func fingerprint(for data: Data, pageURL: URL? = nil) -> String {
        if let pageURL,
           let key = cacheKey(for: pageURL) {
            return OfflineTranslationFingerprintCache.shared.value(for: key, data: data)
        }
        return OfflineTranslationFingerprint.sha256(for: data)
    }

    private static func cacheKey(for pageURL: URL) -> String? {
        if ComicManager.isArchivePageURL(pageURL) {
            return ComicManager.archivePageCacheKey(for: pageURL)
        }
        guard !RemotePageLoader.isRemotePageURL(pageURL),
              let values = try? pageURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else {
            return nil
        }
        return "\(pageURL.path)#\(values.fileSize ?? 0)#\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
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

/// Reader 优先检查运行中 Set 的当前页，再回退到旧 active Set；关闭开关时完全不触碰 Translation Store。
enum OfflineTranslationOverlayProvider {
    static func validOverlay(
        comic: ComicBook,
        page: ComicPage,
        targetLanguage: TranslationTargetLanguage,
        sourceLanguage: TranslationSourceLanguage
    ) async -> OfflineTranslationOverlayResult {
        let storage = OfflineTranslationStorageManager.shared
        var candidateManifests: [OfflineTranslationSetManifest] = []
        if let inProgress = await storage.inProgressManifest(
            for: comic.id,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        ) {
            candidateManifests.append(inProgress)
        }
        if let active = await storage.activeManifest(for: comic.id, targetLanguage: targetLanguage),
           active.id != candidateManifests.first?.id {
            candidateManifests.append(active)
        }

        for candidate in candidateManifests {
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
                let blocks = savedPage.blocks.map { $0.textBlock() }
                if savedPage.state == .noText {
                    return .confirmedNoText(setID: candidate.id)
                }
                return .displayed(blocks: blocks, setID: candidate.id)
            } catch {
                // 原图暂时不可读时不污染旧译文，继续尝试回退 Set。
                continue
            }
        }
        return .unavailable
    }
}
