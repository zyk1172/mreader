import CryptoKit
import Foundation
import UIKit

nonisolated enum AITranslationPrefetchPolicy {
    static func pageIndices(
        currentPageIndex: Int,
        pageCount: Int,
        isAutoTranslationEnabled: Bool,
        lookAheadCount: Int = 2
    ) -> [Int] {
        guard isAutoTranslationEnabled, pageCount > 0, lookAheadCount > 0 else { return [] }
        return (1...lookAheadCount).compactMap { distance in
            let index = currentPageIndex + distance
            return (0..<pageCount).contains(index) ? index : nil
        }
    }
}

nonisolated struct AITranslationPageRequest: @unchecked Sendable {
    let pageURL: URL
    let image: UIImage
    let mode: AITranslationMode
    let configuration: AIActiveConfiguration
    let target: TranslationTargetLanguage
    let translationPromptTemplate: String
    let visionPromptTemplate: String
    let isRightToLeft: Bool
    let minimumTextHeight: Double
    let ocrRecognitionMode: OCRRecognitionMode
    let safeAreaInset: Double
    let usesVisualOCRVerification: Bool
    let viewportAspect: CGFloat
    let sourceLanguagePreference: TranslationSourceLanguage?

    var cacheKey: String {
        let sourceIdentity: String
        if pageURL.isFileURL {
            let values = try? pageURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            sourceIdentity = "\(pageURL.path)#\(values?.fileSize ?? 0)#\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        } else {
            sourceIdentity = pageURL.absoluteString
        }
        // 模型按角色（text/vision）进入缓存 key：纯 OCR 翻译只依赖 textModel，
        // 开启视觉复核后依赖 text+vision，Vision 模式依赖 vision+text。
        let modelIdentity: String
        switch mode {
        case .ocr:
            modelIdentity = usesVisualOCRVerification
                ? "text=\(configuration.textModel)|vision=\(configuration.visionModel)"
                : "text=\(configuration.textModel)"
        case .vision:
            modelIdentity = "vision=\(configuration.visionModel)|text=\(configuration.textModel)"
        }
        let rawValue = [
            "v5",
            sourceIdentity,
            mode.rawValue,
            configuration.profileID.uuidString,
            configuration.baseURL,
            modelIdentity,
            target.rawValue,
            isRightToLeft ? "rtl" : "ltr",
            String(format: "%.5f", minimumTextHeight),
            ocrRecognitionMode.rawValue,
            String(format: "%.4f", safeAreaInset),
            usesVisualOCRVerification ? "visual-review" : "local-only",
            String(format: "%.3f", Double(viewportAspect)),
            sourceLanguagePreference?.rawValue ?? "auto",
            translationPromptTemplate,
            visionPromptTemplate
        ].joined(separator: "|")
        return SHA256.hash(data: Data(rawValue.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated private struct CachedTranslationBlock: Codable, Sendable {
    let id: UUID
    let text: String
    let translation: String?
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let confidence: Double
    let ocrSource: String
    let estimatedFontScale: Double
    let textColorHex: String?
    let polygon: [CachedPoint]
    let translationLines: [String]

    init(_ block: TextBlock) {
        id = block.id
        text = block.text
        translation = block.translation
        x = block.boundingBox.minX
        y = block.boundingBox.minY
        width = block.boundingBox.width
        height = block.boundingBox.height
        confidence = block.confidence
        ocrSource = block.ocrSource
        estimatedFontScale = block.estimatedFontScale
        textColorHex = block.textColorHex
        polygon = block.polygon.map(CachedPoint.init)
        translationLines = block.translationLines
    }

    var textBlock: TextBlock {
        TextBlock(
            id: id,
            text: text,
            boundingBox: CGRect(x: x, y: y, width: width, height: height),
            translation: translation,
            confidence: confidence,
            ocrSource: ocrSource,
            estimatedFontScale: estimatedFontScale,
            textColorHex: textColorHex,
            polygon: polygon.map(\.point),
            translationLines: translationLines
        )
    }
}

nonisolated private struct CachedPoint: Codable, Sendable {
    let x: Double
    let y: Double

    init(_ point: CGPoint) {
        x = point.x
        y = point.y
    }

    var point: CGPoint { CGPoint(x: x, y: y) }
}

nonisolated private struct CachedTranslationPage: Codable, Sendable {
    let createdAt: Date
    let blocks: [CachedTranslationBlock]
}

actor AITranslationPageCoordinator {
    static let shared = AITranslationPageCoordinator()

    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private var memoryCache: [String: [TextBlock]] = [:]
    private var memoryOrder: [String] = []
    private var inFlight: [String: Task<[TextBlock], Error>] = [:]
    private let memoryPageLimit = 80
    private let diskByteLimit: Int64 = 50 * 1024 * 1024

    init() {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDirectory = root.appendingPathComponent("AITranslationPages", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func translatedBlocks(for request: AITranslationPageRequest) async throws -> [TextBlock] {
        let key = request.cacheKey
        if let cached = cachedBlocks(forKey: key) {
            print("MReader AI translation cache hit key=\(key.prefix(10)) blocks=\(cached.count)")
            return cached
        }
        if let existing = inFlight[key] {
            print("MReader AI translation joined in-flight key=\(key.prefix(10))")
            return try await existing.value
        }

        let task = Task.detached(priority: .userInitiated) {
            try await AITranslationPagePipeline.translate(request)
        }
        inFlight[key] = task
        do {
            let blocks = try await task.value
            inFlight[key] = nil
            store(blocks, forKey: key)
            return blocks
        } catch {
            inFlight[key] = nil
            throw error
        }
    }

    func isCached(_ request: AITranslationPageRequest) -> Bool {
        let key = request.cacheKey
        if memoryCache[key] != nil { return true }
        return fileManager.fileExists(atPath: fileURL(forKey: key).path)
    }

    func clearCache() {
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        memoryCache.removeAll()
        memoryOrder.removeAll()
        try? fileManager.removeItem(at: cacheDirectory)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    private func cachedBlocks(forKey key: String) -> [TextBlock]? {
        if let blocks = memoryCache[key] {
            touchMemoryKey(key)
            return blocks
        }
        let url = fileURL(forKey: key)
        guard let data = try? Data(contentsOf: url),
              let page = try? JSONDecoder().decode(CachedTranslationPage.self, from: data) else {
            return nil
        }
        let blocks = page.blocks.map(\.textBlock)
        insertIntoMemory(blocks, forKey: key)
        return blocks
    }

    private func store(_ blocks: [TextBlock], forKey key: String) {
        guard !blocks.isEmpty else { return }
        insertIntoMemory(blocks, forKey: key)
        let page = CachedTranslationPage(
            createdAt: Date(),
            blocks: blocks.map(CachedTranslationBlock.init)
        )
        guard let data = try? JSONEncoder().encode(page) else { return }
        try? data.write(to: fileURL(forKey: key), options: .atomic)
        pruneDiskCacheIfNeeded()
        print("MReader AI translation cache stored key=\(key.prefix(10)) blocks=\(blocks.count)")
    }

    private func insertIntoMemory(_ blocks: [TextBlock], forKey key: String) {
        memoryCache[key] = blocks
        touchMemoryKey(key)
        while memoryOrder.count > memoryPageLimit {
            let removed = memoryOrder.removeFirst()
            memoryCache[removed] = nil
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

nonisolated enum AITranslationPagePipeline {
    static func translate(_ request: AITranslationPageRequest) async throws -> [TextBlock] {
        switch request.mode {
        case .ocr:
            return try await translateOCR(request)
        case .vision:
            return try await AITranslator.translateVisionPage(
                image: request.image,
                apiKey: request.configuration.apiKey,
                baseURL: request.configuration.baseURL,
                visionModel: request.configuration.visionModel,
                textFallbackModel: request.configuration.textModel,
                targetLanguage: request.target.rawValue,
                promptTemplate: request.visionPromptTemplate,
                isRightToLeft: request.isRightToLeft,
                viewportAspect: request.viewportAspect,
                sourceLanguage: request.sourceLanguagePreference
            )
        }
    }

    private static func translateOCR(_ request: AITranslationPageRequest) async throws -> [TextBlock] {
        let options = OCRPreprocessor.Options(
            isRightToLeft: request.isRightToLeft,
            minimumTextHeight: request.minimumTextHeight,
            recognitionMode: request.ocrRecognitionMode,
            sourceLanguagePreference: request.sourceLanguagePreference
        )
        let cacheRequest = OCRRecognitionCacheRequest(
            pageURL: request.pageURL,
            fallbackImage: request.image,
            options: options
        )
        let localResult = try await OCRRecognitionCache.shared.result(for: cacheRequest)
        let resolvedBlocks: [TextBlock]
        if request.usesVisualOCRVerification {
            let ocrImage = await OCRPreprocessor.highResolutionImage(
                from: request.pageURL,
                fallback: request.image
            ) ?? request.image
            resolvedBlocks = await AITranslator.visualVerifyOCRRegions(
                image: ocrImage,
                blocks: localResult.resolvedBlocks,
                apiKey: request.configuration.apiKey,
                baseURL: request.configuration.baseURL,
                model: request.configuration.visionModel,
                isRightToLeft: request.isRightToLeft
            )
        } else {
            resolvedBlocks = localResult.resolvedBlocks
        }
        let annotated = AITranslator.annotatedMangaTextBlocks(
            resolvedBlocks,
            safeAreaInset: request.safeAreaInset,
            minimumTextHeight: request.minimumTextHeight,
            isRightToLeft: request.isRightToLeft
        )
        let visibleBlocks = annotated.filter { !$0.isFiltered }
        var translated = MangaTextSegmenter.segment(
            visibleBlocks,
            isRightToLeft: request.isRightToLeft
        ).bubbles
        guard !translated.isEmpty else { return [] }

        try await applyBatchTranslationSafely(to: &translated, indexes: Array(translated.indices), request: request)
        let missing = translated.indices.filter {
            (translated[$0].translation ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if !missing.isEmpty {
            try await applyBatchTranslationSafely(to: &translated, indexes: missing, request: request)
        }
        return translated.filter {
            !($0.translation ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// 整页 JSON 翻译，失败时若属于“格式/协议类”错误，则缩小为逐气泡纯文本兜底（审查 #7），
    /// 让格式遵循能力差但翻译能力正常的便宜模型仍然可用。
    private static func applyBatchTranslationSafely(
        to blocks: inout [TextBlock],
        indexes: [Int],
        request: AITranslationPageRequest
    ) async throws {
        do {
            try await applyBatchTranslation(to: &blocks, indexes: indexes, request: request)
        } catch let error as AITranslationRequestError where error.isFormatFailure {
            print("MReader OCR 整页翻译格式失败，逐气泡兜底: \(error.localizedDescription)")
            try await applyPerBubbleTranslation(to: &blocks, indexes: indexes, request: request)
        }
    }

    private static func applyPerBubbleTranslation(
        to blocks: inout [TextBlock],
        indexes: [Int],
        request: AITranslationPageRequest
    ) async throws {
        guard !indexes.isEmpty else { return }
        let maximumConcurrentRequests = min(3, indexes.count)
        let configuration = request.configuration
        let target = request.target
        var successCount = 0
        var firstError: Error?
        await withTaskGroup(of: (Int, Result<String, Error>).self) { group in
            var nextIndex = 0

            func submit(_ localIndex: Int) {
                let index = indexes[localIndex]
                let block = blocks[index]
                let pageContext = blocks.count > 1
                    ? AITranslator.pageContextDescription(blocks: blocks, currentIndex: index)
                    : ""
                group.addTask {
                    do {
                        let text = try await AITranslator.translate(
                            text: block.text,
                            ocrMetadata: AITranslator.ocrMetadata(for: block),
                            pageContext: pageContext,
                            apiKey: configuration.apiKey,
                            baseURL: configuration.baseURL,
                            model: configuration.textModel,
                            targetLanguage: target.modelInstruction,
                            promptTemplate: request.translationPromptTemplate,
                            requestTimeout: AITranslationRequestPolicy.fallbackRequestTimeout
                        )
                        return (index, .success(text))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }

            while nextIndex < maximumConcurrentRequests {
                submit(nextIndex)
                nextIndex += 1
            }
            while let (index, result) = await group.next() {
                if Task.isCancelled {
                    group.cancelAll()
                    return
                }
                switch result {
                case .success(let text):
                    if blocks.indices.contains(index) {
                        blocks[index].translation = text
                        blocks[index].translationLines = [text]
                        successCount += 1
                    }
                case .failure(let error):
                    if firstError == nil { firstError = error }
                }
                if nextIndex < indexes.count {
                    submit(nextIndex)
                    nextIndex += 1
                }
            }
        }
        // 全部失败必须向上抛错（项2），不允许“全失败却像成功一样结束”。
        if successCount == 0, let firstError {
            throw AITranslationRequestError.invalidConfiguration(
                "逐气泡翻译全部失败：\(firstError.localizedDescription)"
            )
        }
    }

    private static func applyBatchTranslation(
        to blocks: inout [TextBlock],
        indexes: [Int],
        request: AITranslationPageRequest
    ) async throws {
        guard !indexes.isEmpty else { return }
        let requestedBlocks = indexes.map { blocks[$0] }
        let result = try await AITranslator.translatePage(
            blocks: requestedBlocks,
            apiKey: request.configuration.apiKey,
            baseURL: request.configuration.baseURL,
            model: request.configuration.textModel,
            target: request.target,
            promptTemplate: request.translationPromptTemplate,
            sourceLanguage: request.sourceLanguagePreference
        )
        // 线上 ID 是 b0/b1/...，顺序 = requestedBlocks（即 indexes）中的位置
        for (position, index) in indexes.enumerated() {
            guard let value = result.translation(for: "b\(position)") else { continue }
            blocks[index].translation = value.translation
            blocks[index].translationLines = value.translationLines
        }
    }
}
