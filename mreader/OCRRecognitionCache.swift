import CryptoKit
import Foundation
import UIKit
import os

nonisolated struct OCRRecognitionCacheRequest: @unchecked Sendable {
    let pageURL: URL
    let fallbackImage: UIImage
    let options: OCRPreprocessor.Options
    var comicID: UUID? = nil
    var pageIndex: Int? = nil

    var analysisIdentity: String = "unprepared"
    var sourceIdentityOverride: String? = nil

    var cacheKey: String {
        let sourceIdentity = sourceIdentityOverride ?? PageContentIdentityResolver.identity(for: pageURL).fingerprint
        let rawValue = [
            // v11 keeps Manga Vision text ROI discovery and adds first-class
            // balloon/layout geometry. Do not reuse pages written before that
            // translation-unit contract existed.
            "local-ocr-v13-contours-width-preserving",
            MangaVisionService.analysisRevision,
            analysisIdentity,
            JapaneseVerticalOCRService.revision,
            sourceIdentity,
            options.isRightToLeft ? "rtl" : "ltr",
            String(format: "%.5f", options.minimumTextHeight),
            options.recognitionMode.rawValue,
            options.languages.joined(separator: ","),
            options.sourceLanguagePreference?.rawValue ?? "auto"
        ].joined(separator: "|")
        return SHA256.hash(data: Data(rawValue.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// Complete immutable recognition decisions survive cold cache restores unchanged.
nonisolated struct CachedOCRPage: Codable, Sendable {
    let createdAt: Date
    let result: OCRPipelineResult
}

actor OCRRecognitionCache {
    static let shared = OCRRecognitionCache()

    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private let memoryPageLimit = 48
    private let diskByteLimit: Int64 = 30 * 1024 * 1024
    private var memoryCache: [String: OCRPipelineResult] = [:]
    private var memoryOrder: [String] = []
    private struct PreparedResult: Sendable {
        let result: OCRPipelineResult
        let identity: String
        let isPersistent: Bool
    }
    private let workPool = SharedPageTaskPool<PreparedResult>()
    private var generation = UUID()
    private var activeReaderSessionID: UUID?

    init(cacheDirectory: URL? = nil) {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.cacheDirectory = cacheDirectory ?? root.appendingPathComponent("LocalOCR", isDirectory: true)
        try? fileManager.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
    }

    func result(for request: OCRRecognitionCacheRequest) async throws -> OCRPipelineResult {
        let epoch = generation
        let sourceSize = await OCRPreprocessor.sourcePixelSize(from: request.pageURL, fallback: request.fallbackImage)
        try Task.checkCancellation()
        guard epoch == generation else { throw CancellationError() }
        var preparedRequest = request
        let sourceIdentity = PageContentIdentityResolver.identity(for: request.pageURL).fingerprint
        preparedRequest.sourceIdentityOverride = sourceIdentity
        preparedRequest.analysisIdentity = await MangaVisionService.shared.expectedDependencyIdentity(
            sourceSize: OCRPreprocessor.preparedPixelSize(sourceSize: sourceSize)
        )
        guard PageContentIdentityResolver.identity(for: request.pageURL).fingerprint == sourceIdentity else {
            throw CancellationError()
        }
        let key = preparedRequest.cacheKey
        if let cached = cachedResult(forKey: key) { return cached }
        // Coalesce preparation as well as OCR. Concurrent consumers must not each
        // decode the high-resolution source before discovering the shared work.
        let prepared = try await workPool.value(forKey: key) {
            let image = await OCRPreprocessor.highResolutionImage(from: request.pageURL, fallback: request.fallbackImage)
                ?? request.fallbackImage
            try Task.checkCancellation()
            let analysis = try? await MangaVisionService.shared.analysis(comicID: request.comicID,
                pageIndex: request.pageIndex, pageURL: request.pageURL, image: image)
            try Task.checkCancellation()
            let identity = await MangaVisionService.shared.dependencyIdentity(for: analysis)
            let result = try await MangaOCRPipeline.recognize(in: image, options: request.options, mangaAnalysis: analysis, sourceURL: request.pageURL)
            return PreparedResult(result: result, identity: identity, isPersistent: analysis != nil)
        }
        try Task.checkCancellation()
        guard epoch == generation else { throw CancellationError() }
        // Source reads span suspension points. Never return or persist a mixture
        // of revisions, or label an old result with the file's new cache key.
        guard PageContentIdentityResolver.identity(for: request.pageURL).fingerprint == sourceIdentity else {
            throw CancellationError()
        }
        preparedRequest.analysisIdentity = prepared.identity
        if prepared.isPersistent { store(prepared.result, forKey: preparedRequest.cacheKey) }
        return prepared.result
    }

    func beginReaderSession(sessionID: UUID) async {
        guard await ReaderSessionRegistry.shared.isActive(sessionID) else { return }
        activeReaderSessionID = sessionID
    }

    /// Reader 会话结束只释放 OCR 内存结果。Reader 自己的 consumer 会随
    /// Task 取消退出；不能 cancelAll，因为离线翻译/后台 OCR 索引共用这个 workPool。
    func releaseReaderSessionMemory(sessionID: UUID? = nil) {
        if let sessionID {
            guard activeReaderSessionID == sessionID else { return }
        }
        activeReaderSessionID = nil
        memoryCache.removeAll()
        memoryOrder.removeAll()
        MReaderLog.aiVision.debug("OCR reader-session memory released")
    }

    func clearCache() async {
        generation = UUID()
        memoryCache.removeAll()
        memoryOrder.removeAll()
        await workPool.cancelAll()
        try? fileManager.removeItem(at: cacheDirectory)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    private func cachedResult(forKey key: String) -> OCRPipelineResult? {
        if let result = memoryCache[key] {
            touchMemoryKey(key)
            return result
        }
        let url = fileURL(forKey: key)
        guard let data = try? Data(contentsOf: url),
              let page = try? JSONDecoder().decode(CachedOCRPage.self, from: data) else {
            return nil
        }
        let result = page.result
        insertIntoMemory(result, forKey: key)
        return result
    }

    private func store(_ result: OCRPipelineResult, forKey key: String) {
        guard !result.rawBlocks.isEmpty else { return }
        insertIntoMemory(result, forKey: key)
        let page = CachedOCRPage(createdAt: Date(), result: result)
        guard let data = try? JSONEncoder().encode(page) else { return }
        try? data.write(to: fileURL(forKey: key), options: .atomic)
        pruneDiskCacheIfNeeded()
        MReaderLog.aiVision.debug(
            "local OCR cache stored key=\(key.prefix(10), privacy: .public) blocks=\(result.resolvedBlocks.count, privacy: .public)"
        )
    }

    private func insertIntoMemory(_ result: OCRPipelineResult, forKey key: String) {
        memoryCache[key] = result
        touchMemoryKey(key)
        while memoryOrder.count > memoryPageLimit {
            memoryCache[memoryOrder.removeFirst()] = nil
        }
    }

    private func touchMemoryKey(_ key: String) {
        memoryOrder.removeAll { $0 == key }
        memoryOrder.append(key)
    }

    private func fileURL(forKey key: String) -> URL {
        cacheDirectory.appendingPathComponent(key).appendingPathExtension("json")
    }

    private func pruneDiskCacheIfNeeded() {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let entries = urls.compactMap { url -> (URL, Int64, Date)? in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
                return nil
            }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
        var totalBytes = entries.reduce(Int64(0)) { $0 + $1.1 }
        guard totalBytes > diskByteLimit else { return }
        for entry in entries.sorted(by: { $0.2 < $1.2 }) where totalBytes > diskByteLimit {
            try? fileManager.removeItem(at: entry.0)
            totalBytes -= entry.1
        }
    }
}
