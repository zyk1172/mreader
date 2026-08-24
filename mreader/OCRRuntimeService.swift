import Foundation

/// OCR 识别缓存、搜索索引与持久化的单一运行时入口。
nonisolated enum OCRRuntimeService {
    static func recognize(for request: OCRRecognitionCacheRequest) async throws -> OCRPipelineResult {
        try await OCRRecognitionCache.shared.result(for: request)
    }

    static func index(comicID: UUID, pageIndex: Int, blocks: [TextBlock]) async {
        await OCRSearchIndex.shared.index(comicID: comicID, pageIndex: pageIndex, blocks: blocks)
    }

    static func search(_ query: String, comics: [ComicBook]) async -> [OCRSearchResult] {
        await OCRSearchIndex.shared.search(query, comics: comics)
    }

    static func remove(comicID: UUID) async {
        await OCRSearchIndex.shared.remove(comicID: comicID)
    }

    static func flush() async {
        await OCRSearchIndex.shared.flush()
    }
}
