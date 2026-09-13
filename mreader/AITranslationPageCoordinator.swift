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
    /// 外层实时译文缓存包含 OCR 的 boundingBox、字号尺度和文字方向，也携带表面布局
    /// 所依赖的 translation-unit 契约；几何或分组契约升级时必须失效，不能复用旧结果。
    /// v19：没有可靠 bubbleBox 的连续 OCR line 形成 measured paragraph；它仍不
    /// 创建 bubbleBox，但会改变 translation unit 数量，必须隔离旧的逐行结果。
    /// v22：Vision 增加跨切片原文拼接与可疑 block 的 text-first 原文复核，
    /// 会改写 sourceText 与 translation unit 数量，旧缓存必须失效。
    static let translationCacheRevision = "translation-v22-vision-slice-merge-and-source-review"
    static let ocrGeometryRevision = "physical-axis-v11-canonical-bubble-region-measured-paragraph"

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
    var previousContext: String
    /// Stable scope/page identity for chapter-local context. Existing callers
    /// remain source-compatible because both additions have defaults.
    var contextScopeID: String? = nil
    var pageIndex: Int? = nil

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
                ? "text=\(configuration.textModel)|text-protocol=\(configuration.textModelDescriptor.apiProtocol.rawValue)|vision=\(configuration.visionModel)|vision-protocol=\(configuration.visionModelDescriptor.apiProtocol.rawValue)"
                : "text=\(configuration.textModel)|text-protocol=\(configuration.textModelDescriptor.apiProtocol.rawValue)"
        case .vision:
            modelIdentity = "vision=\(configuration.visionModel)|vision-protocol=\(configuration.visionModelDescriptor.apiProtocol.rawValue)|text=\(configuration.textModel)|text-protocol=\(configuration.textModelDescriptor.apiProtocol.rawValue)"
        }
        let rawValue = [
            Self.translationCacheRevision,
            "ocr-geometry=\(Self.ocrGeometryRevision)",
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
            contextScopeID ?? "unscoped",
            pageIndex.map(String.init) ?? "no-page",
            previousContext,
            translationPromptTemplate,
            visionPromptTemplate
        ].joined(separator: "|")
        return SHA256.hash(data: Data(rawValue.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated struct AITranslationOCRResult: Sendable {
    let blocks: [TextBlock]
    let missingBlockIDs: [UUID]
}

nonisolated struct AITranslationPipelineResult: Sendable {
    let blocks: [TextBlock]
    let isComplete: Bool
}

nonisolated private struct CachedTranslationBlock: Codable, Sendable {
    let id: UUID
    let text: String
    let translation: String?
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let bubbleX: Double?
    let bubbleY: Double?
    let bubbleWidth: Double?
    let bubbleHeight: Double?
    let confidence: Double
    let ocrSource: String
    let estimatedFontScale: Double
    let textColorHex: String?
    let textOrientation: TextOrientation?
    let layoutRole: TranslationLayoutRole?
    let sourceLineCount: Int?
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
        bubbleX = block.bubbleBox.map { Double($0.minX) }
        bubbleY = block.bubbleBox.map { Double($0.minY) }
        bubbleWidth = block.bubbleBox.map { Double($0.width) }
        bubbleHeight = block.bubbleBox.map { Double($0.height) }
        confidence = block.confidence
        ocrSource = block.ocrSource
        estimatedFontScale = block.estimatedFontScale
        textColorHex = block.textColorHex
        textOrientation = block.textOrientation
        layoutRole = block.layoutRole
        sourceLineCount = block.sourceLineCount
        polygon = block.polygon.map(CachedPoint.init)
        translationLines = block.translationLines
    }

    var textBlock: TextBlock {
        let bubbleBox: CGRect?
        if let bubbleX, let bubbleY, let bubbleWidth, let bubbleHeight {
            bubbleBox = CGRect(x: bubbleX, y: bubbleY, width: bubbleWidth, height: bubbleHeight)
        } else {
            bubbleBox = nil
        }
        return TextBlock(
            id: id,
            text: text,
            boundingBox: CGRect(x: x, y: y, width: width, height: height),
            translation: translation,
            confidence: confidence,
            ocrSource: ocrSource,
            estimatedFontScale: estimatedFontScale,
            textColorHex: textColorHex,
            bubbleBox: bubbleBox,
            polygon: polygon.map(\.point),
            translationLines: translationLines,
            textOrientation: textOrientation,
            layoutRole: layoutRole,
            sourceLineCount: sourceLineCount ?? 1
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
    private var inFlight: [String: Task<AITranslationPipelineResult, Error>] = [:]
    private let memoryPageLimit = 80
    private let diskByteLimit: Int64 = 50 * 1024 * 1024

    init() {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDirectory = root.appendingPathComponent("AITranslationPages", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func translatedBlocks(for request: AITranslationPageRequest) async throws -> [TextBlock] {
        var contextualRequest = request
        contextualRequest.previousContext = await TranslationContextRegistry.shared.context(
            scopeID: request.contextScopeID,
            pageIndex: request.pageIndex,
            seed: request.previousContext
        )
        let key = contextualRequest.cacheKey
        if let cached = cachedBlocks(forKey: key) {
            print("MReader AI translation cache hit key=\(key.prefix(10)) blocks=\(cached.count)")
            await TranslationContextRegistry.shared.record(
                scopeID: contextualRequest.contextScopeID,
                pageIndex: contextualRequest.pageIndex,
                blocks: cached
            )
            return cached
        }
        if let existing = inFlight[key] {
            print("MReader AI translation joined in-flight key=\(key.prefix(10))")
            return try await existing.value.blocks
        }

        let task = Task.detached(priority: .userInitiated) {
            try await AITranslationPagePipeline.translate(contextualRequest)
        }
        inFlight[key] = task
        do {
            let result = try await task.value
            inFlight[key] = nil
            if result.isComplete {
                store(result.blocks, forKey: key)
                await TranslationContextRegistry.shared.record(
                    scopeID: contextualRequest.contextScopeID,
                    pageIndex: contextualRequest.pageIndex,
                    blocks: result.blocks
                )
            } else {
                print("MReader AI translation cache skipped explicit partial key=\(key.prefix(10)) blocks=\(result.blocks.count)")
            }
            return result.blocks
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
        let isComplete = blocks.allSatisfy { block in
            !(block.translation ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard isComplete else {
            print("MReader AI translation cache skipped partial key=\(key.prefix(10)) blocks=\(blocks.count)")
            return
        }
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
    static func translate(_ request: AITranslationPageRequest) async throws -> AITranslationPipelineResult {
        switch request.mode {
        case .ocr:
            let result = try await translateOCRPageWithStatus(request)
            return AITranslationPipelineResult(
                blocks: result.blocks,
                isComplete: result.missingBlockIDs.isEmpty
            )
        case .vision:
            let result = try await TranslationRuntimeService.translateVisionPageWithStatus(
                image: request.image,
                apiKey: request.configuration.apiKey,
                baseURL: request.configuration.baseURL,
                visionModel: request.configuration.visionModel,
                textFallbackModel: request.configuration.textModel,
                targetLanguage: request.target.rawValue,
                promptTemplate: request.visionPromptTemplate,
                isRightToLeft: request.isRightToLeft,
                viewportAspect: request.viewportAspect,
                sourceLanguage: request.sourceLanguagePreference,
                previousContext: request.previousContext,
                visionModelDescriptor: request.configuration.visionModelDescriptor,
                textFallbackModelDescriptor: request.configuration.textModelDescriptor
            )
            // Vision 的 sourceText 与 textBox 出自同一个模型，没有独立证据源。
            // 对可疑 block 做一次局部 text-first 复核，只重译被修正的 block（审查 #3）。
            var blocks = result.blocks
            var missingBlockIDs = result.missingBlockIDs
            do {
                let review = try await TranslationRuntimeService.reverifyVisionSourceTexts(
                    image: request.image,
                    blocks: blocks,
                    apiKey: request.configuration.apiKey,
                    baseURL: request.configuration.baseURL,
                    visionModel: request.configuration.visionModel,
                    visionModelDescriptor: request.configuration.visionModelDescriptor,
                    sourceLanguagePreference: request.sourceLanguagePreference,
                    maximumRegionCount: AITranslator.VisionSourceReviewPolicy.maximumRegionCount
                )
                if !review.correctedBlockIDs.isEmpty {
                    blocks = review.blocks
                    let correctedIndexes = blocks.indices.filter {
                        review.correctedBlockIDs.contains(blocks[$0].id)
                    }
                    try await applyBatchTranslationSafely(
                        to: &blocks,
                        indexes: correctedIndexes,
                        request: request
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                print("MReader vision source review fallback reason=\(error.localizedDescription)")
            }
            missingBlockIDs = blocks.compactMap { block in
                (block.translation ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? block.id
                    : nil
            }
            return AITranslationPipelineResult(
                blocks: blocks,
                isComplete: result.failedSlices == 0 && missingBlockIDs.isEmpty
            )
        }
    }

    /// Vision 明确返回空页但本地 OCR 已经识别到正文时，复用该 OCR 结果走 Text Model。
    /// 这避免将有文字的页静默写成 noText，也避免为了补译再跑一次 OCR。
    static func translateExistingOCRBubbles(
        _ bubbles: [TextBlock],
        request: AITranslationPageRequest
    ) async throws -> AITranslationOCRResult {
        var translated = bubbles
        guard !translated.isEmpty else {
            return AITranslationOCRResult(blocks: [], missingBlockIDs: [])
        }

        try await applyBatchTranslationSafely(
            to: &translated,
            indexes: Array(translated.indices),
            request: request
        )
        let missing = translated.indices.filter {
            (translated[$0].translation ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if !missing.isEmpty {
            try await applyBatchTranslationSafely(
                to: &translated,
                indexes: missing,
                request: request
            )
        }
        let completed = translated.filter {
            !($0.translation ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !completed.isEmpty else {
            throw AITranslationRequestError.invalidResponse(model: request.configuration.textModel)
        }
        let missingIDs = translated.indices.compactMap { index in
            let translation = (translated[index].translation ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return translation.isEmpty ? translated[index].id : nil
        }
        return AITranslationOCRResult(blocks: translated, missingBlockIDs: missingIDs)
    }

    private static func translateOCR(_ request: AITranslationPageRequest) async throws -> [TextBlock] {
        try await translateOCRPageWithStatus(request).blocks
    }

    static func translateOCRPageWithStatus(_ request: AITranslationPageRequest) async throws -> AITranslationOCRResult {
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
        let localResult = try await OCRRuntimeService.recognize(for: cacheRequest)
        let resolvedBlocks: [TextBlock]
        if request.usesVisualOCRVerification {
            let ocrImage = await OCRPreprocessor.highResolutionImage(
                from: request.pageURL,
                fallback: request.image
            ) ?? request.image
            // Rejected candidates retain geometry/reason and must remain visible
            // to visual review; otherwise weak but real text can never re-enter the
            // translation pipeline.
            let reviewBlocks = localResult.resolvedBlocks + localResult.rejectedBlocks
            resolvedBlocks = try await TranslationRuntimeService.visualVerifyOCRRegions(
                image: ocrImage,
                blocks: reviewBlocks,
                apiKey: request.configuration.apiKey,
                baseURL: request.configuration.baseURL,
                model: request.configuration.visionModel,
                isRightToLeft: request.isRightToLeft,
                modelDescriptor: request.configuration.visionModelDescriptor,
                sourceLanguagePreference: request.sourceLanguagePreference,
                detectedLanguage: localResult.detectedLanguage,
                visualVerificationEnabled: request.usesVisualOCRVerification,
                coverageRecoveryRequested: localResult.quality?.isSuspicious == true
                    || !localResult.rejectedBlocks.isEmpty
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
        guard !translated.isEmpty else {
            return AITranslationOCRResult(blocks: [], missingBlockIDs: [])
        }

        try await applyBatchTranslationSafely(to: &translated, indexes: Array(translated.indices), request: request)
        let missing = translated.indices.filter {
            (translated[$0].translation ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if !missing.isEmpty {
            try await applyBatchTranslationSafely(to: &translated, indexes: missing, request: request)
        }
        let completed = translated.filter {
            !($0.translation ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let missingBlockIDs = translated.compactMap { block in
            let translation = (block.translation ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return translation.isEmpty ? block.id : nil
        }
        return AITranslationOCRResult(blocks: translated, missingBlockIDs: missingBlockIDs)
    }

    /// Vision=noText 的复核必须复用正常 OCR 的 annotate -> filter -> segment 链路，
    /// 不能直接把低阈值识别出的原始 bubble 当正文。
    static func filteredOCRBubbles(
        from localResult: OCRPipelineResult,
        minimumTextHeight: Double,
        isRightToLeft: Bool
    ) -> [TextBlock] {
        let annotated = AITranslator.annotatedMangaTextBlocks(
            localResult.resolvedBlocks,
            safeAreaInset: 0,
            minimumTextHeight: minimumTextHeight,
            isRightToLeft: isRightToLeft
        )
        return MangaTextSegmenter.segment(
            annotated.filter { !$0.isFiltered },
            isRightToLeft: isRightToLeft
        ).bubbles
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
        } catch let error as AITranslationRequestError
            where error.isFormatFailure || error.isTranslationContentFailure {
            print("MReader OCR 整页翻译需要逐气泡恢复: \(error.localizedDescription)")
            try await applyPerBubbleTranslation(to: &blocks, indexes: indexes, request: request)
        }
    }

    private static func applyPerBubbleTranslation(
        to blocks: inout [TextBlock],
        indexes: [Int],
        request: AITranslationPageRequest
    ) async throws {
        guard !indexes.isEmpty else { return }
        // A malformed page gets one repair request first. Keep the final
        // per-bubble fallback deliberately small so a slow provider does not
        // turn one page failure into a request burst.
        let maximumConcurrentRequests = min(2, indexes.count)
        let configuration = request.configuration
        let target = request.target
        var successCount = 0
        var firstError: Error?
        try await withThrowingTaskGroup(of: (Int, Result<String, Error>).self) { group in
            var nextIndex = 0

            func submit(_ localIndex: Int) {
                let index = indexes[localIndex]
                let block = blocks[index]
                let pageContext = TranslationContextBuilder.promptContext(
                    previousContext: request.previousContext,
                    pageBlocks: blocks,
                    requestedIndexes: [index]
                )
                group.addTask {
                    do {
                let text = try await TranslationRuntimeService.translate(
                            text: block.text,
                            ocrMetadata: AITranslator.ocrMetadata(for: block),
                            pageContext: pageContext,
                            apiKey: configuration.apiKey,
                            baseURL: configuration.baseURL,
                            model: configuration.textModel,
                            targetLanguage: target,
                            promptTemplate: request.translationPromptTemplate,
                            requestTimeout: AITranslationRequestPolicy.bubbleRequestTimeout,
                            modelDescriptor: configuration.textModelDescriptor
                        )
                        return (index, .success(text))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }

            while nextIndex < maximumConcurrentRequests {
                submit(nextIndex)
                nextIndex += 1
            }
            while let (index, result) = try await group.next() {
                if Task.isCancelled {
                    group.cancelAll()
                    throw CancellationError()
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
            // 保留原始错误类型及其 statusCode/retryAfter，交给离线重试策略处理
            // 429、503、鉴权失败和内容策略拒绝，而不是降级成字符串错误。
            throw firstError
        }
    }

    private static func applyBatchTranslation(
        to blocks: inout [TextBlock],
        indexes: [Int],
        request: AITranslationPageRequest
    ) async throws {
        guard !indexes.isEmpty else { return }
        let requestedBlocks = indexes.map { blocks[$0] }
        let fullPageContext = TranslationContextBuilder.promptContext(
            previousContext: request.previousContext,
            pageBlocks: blocks,
            requestedIndexes: indexes
        )
        let result = try await TranslationRuntimeService.translatePage(
            blocks: requestedBlocks,
            apiKey: request.configuration.apiKey,
            baseURL: request.configuration.baseURL,
            model: request.configuration.textModel,
            target: request.target,
            promptTemplate: request.translationPromptTemplate,
            sourceLanguage: request.sourceLanguagePreference,
            previousContext: fullPageContext,
            modelDescriptor: request.configuration.textModelDescriptor
        )
        // 线上 ID 是 b0/b1/...，顺序 = requestedBlocks（即 indexes）中的位置
        for (position, index) in indexes.enumerated() {
            guard let value = result.translation(for: "b\(position)") else { continue }
            blocks[index].translation = value.translation
            blocks[index].translationLines = value.translationLines
        }
    }
}
