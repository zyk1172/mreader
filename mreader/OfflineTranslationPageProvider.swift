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
enum OfflineTranslationPageProvider {
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

    static func data(for comic: ComicBook, page: ComicPage) async throws -> Data {
        try Task.checkCancellation()
        let data: Data?
        switch comic.sourceType {
        case .local:
            data = await localData(for: comic, pageURL: page.url)
        case .komga:
            data = RemotePageLoader.isRemotePageURL(page.url)
                ? await RemotePageLoader.imageData(forRemotePageURL: page.url)
                : try? Data(contentsOf: page.url)
        case .opds:
            data = try? Data(contentsOf: page.url)
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

    static func fingerprint(for data: Data) -> String {
        OfflineTranslationFingerprint.sha256(for: data)
    }

    private static func localData(for comic: ComicBook, pageURL: URL) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            let scopedURL: URL?
            if let resolvedURL = try? ComicManager.resolveBookmark(comic.bookmarkData) {
                scopedURL = resolvedURL
            } else {
                scopedURL = nil
            }
            let started = scopedURL?.startAccessingSecurityScopedResource() ?? false
            defer {
                if started { scopedURL?.stopAccessingSecurityScopedResource() }
            }
            if ComicManager.isArchivePageURL(pageURL) {
                return ComicManager.imageData(forArchivePageURL: pageURL)
            }
            return try? Data(contentsOf: pageURL)
        }.value
    }
}

/// 阅读器只在开关开启且已存在 active set 时调用此检查；因此关闭开关时完全不触碰 Translation Store。
enum OfflineTranslationOverlayProvider {
    static func validOverlay(
        comic: ComicBook,
        page: ComicPage,
        targetLanguage: TranslationTargetLanguage,
        sourceLanguage: TranslationSourceLanguage
    ) async -> (blocks: [TextBlock], setID: UUID, isNoText: Bool)? {
        guard let active = await OfflineTranslationStorageManager.shared.activeManifest(for: comic.id),
              active.targetLanguage == targetLanguage,
              active.sourceLanguage == sourceLanguage,
              let savedPage = await OfflineTranslationStorageManager.shared.page(
                comicID: comic.id,
                setID: active.id,
                pageIndex: page.index
              ),
              savedPage.state.isUsableOverlay else {
            return nil
        }

        do {
            let sourceData = try await OfflineTranslationPageProvider.data(for: comic, page: page)
            let fingerprint = OfflineTranslationPageProvider.fingerprint(for: sourceData)
            guard fingerprint == savedPage.sourceFingerprint else {
                await OfflineTranslationStorageManager.shared.markPageStale(
                    comicID: comic.id,
                    setID: active.id,
                    pageIndex: page.index
                )
                return nil
            }
            let blocks = savedPage.blocks.map { $0.textBlock() }
            return (blocks, active.id, savedPage.state == .noText)
        } catch {
            // 原图暂时不可读时不污染旧译文，Reader 继续走既有实时逻辑。
            return nil
        }
    }
}
