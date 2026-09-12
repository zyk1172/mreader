from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text()
    if old not in text:
        raise SystemExit(f"missing patch anchor in {path}: {old[:120]!r}")
    if text.count(old) != 1:
        raise SystemExit(f"non-unique patch anchor in {path}: {text.count(old)} matches")
    p.write_text(text.replace(old, new, 1))


# ---------------------------------------------------------------------------
# Shared translation context contract
# ---------------------------------------------------------------------------
Path("mreader/TranslationContext.swift").write_text(r'''import CryptoKit
import Foundation

/// Immutable, deterministic context formatting shared by realtime, prefetch,
/// offline, supplement, text-model and vision-model translation paths.
nonisolated enum TranslationContextBuilder {
    static let revision = "translation-context-v1"
    static let maximumContextCharacters = 5_000

    static func scopeID(
        comicID: UUID?,
        target: TranslationTargetLanguage
    ) -> String? {
        guard let comicID else { return nil }
        return "comic=\(comicID.uuidString)|target=\(target.rawValue)"
    }

    static func mergeContexts(_ values: [String]) -> String {
        let merged = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return bounded(merged)
    }

    static func versionedContext(_ values: [String]) -> String {
        let merged = mergeContexts(values)
        guard !merged.isEmpty else { return "" }
        let digest = SHA256.hash(data: Data(merged.utf8))
            .prefix(6)
            .map { String(format: "%02x", $0) }
            .joined()
        return "contextVersion=\(revision)-\(digest)\n\(merged)"
    }

    /// Adds the full current-page semantic picture even when only a subset of
    /// IDs is being retried. Already translated neighbours remain evidence,
    /// while requested IDs are clearly marked as pending.
    static func promptContext(
        previousContext: String,
        pageBlocks: [TextBlock],
        requestedIndexes: [Int]? = nil
    ) -> String {
        let requested = requestedIndexes.map(Set.init)
        let pageLines = pageBlocks.enumerated().compactMap { index, block -> String? in
            let source = compact(block.text)
            guard !source.isEmpty else { return nil }
            let translation = compact(block.translation ?? "")
            let state: String
            if let requested {
                state = requested.contains(index) ? "待翻译" : (translation.isEmpty ? "同页参考" : "已译")
            } else {
                state = translation.isEmpty ? "待翻译" : "已译"
            }
            let rect = block.boundingBox
            let geometry = String(
                format: "x=%.3f,y=%.3f,w=%.3f,h=%.3f",
                Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)
            )
            let translatedPart = translation.isEmpty ? "" : " | 译文=\(translation)"
            return "#\(index + 1) [\(state)] 原文=\(source)\(translatedPart) | \(geometry) | \(block.textOrientation.rawValue)"
        }
        let pageSection = pageLines.isEmpty
            ? ""
            : "本页完整语义与阅读顺序（只作翻译依据，不得复述）：\n" + pageLines.joined(separator: "\n")
        return mergeContexts([previousContext, pageSection])
    }

    static func visionPrompt(basePrompt: String, previousContext: String) -> String {
        let context = previousContext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !context.isEmpty else { return basePrompt }
        return """
        \(basePrompt)

        上下文快照（仅用于称呼、术语、代词、语气和指代消歧；不得把上下文文字复制成当前页 item，也不得新增剧情事实）：
        \(bounded(context))
        无法从当前页文字、画面线索或上下文可靠判断代词指向时，不得凭空补人名。
        """
    }

    static func sourceTranslationSummary(pageIndex: Int, blocks: [TextBlock]) -> String {
        let pairs = blocks.compactMap { block -> String? in
            let source = compact(block.text)
            let translation = compact(block.translation ?? "")
            guard !source.isEmpty, !translation.isEmpty else { return nil }
            return "原文=\(source) → 译文=\(translation)"
        }
        guard !pairs.isEmpty else { return "" }
        return "第\(pageIndex + 1)页已确认对照：\n" + pairs.joined(separator: "\n")
    }

    static func sourceOnlySummary(pageIndex: Int, blocks: [TextBlock]) -> String {
        let sources = blocks
            .map { compact($0.text) }
            .filter { !$0.isEmpty }
        guard !sources.isEmpty else { return "" }
        return "第\(pageIndex + 1)页原文预识别（尚未依赖该页译文）：\n" + sources.joined(separator: "\n")
    }

    private static func compact(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func bounded(_ value: String) -> String {
        guard value.count > maximumContextCharacters else { return value }
        return String(value.suffix(maximumContextCharacters))
    }
}

/// Recent translated-page memory for live Reader and prefetch. Pages are keyed
/// by page index, never by completion order, so the same available page set
/// produces the same snapshot and version.
actor TranslationContextRegistry {
    static let shared = TranslationContextRegistry()

    private var pagesByScope: [String: [Int: String]] = [:]
    private let lookBackPageCount = 2

    func context(
        scopeID: String?,
        pageIndex: Int?,
        seed: String = ""
    ) -> String {
        guard let scopeID, let pageIndex, pageIndex > 0 else {
            return TranslationContextBuilder.versionedContext([seed])
        }
        let pages = pagesByScope[scopeID] ?? [:]
        let start = max(0, pageIndex - lookBackPageCount)
        let ordered = (start..<pageIndex).compactMap { pages[$0] }
        return TranslationContextBuilder.versionedContext([seed] + ordered)
    }

    func record(
        scopeID: String?,
        pageIndex: Int?,
        blocks: [TextBlock]
    ) {
        guard let scopeID, let pageIndex else { return }
        let summary = TranslationContextBuilder.sourceTranslationSummary(
            pageIndex: pageIndex,
            blocks: blocks
        )
        guard !summary.isEmpty else { return }
        var pages = pagesByScope[scopeID] ?? [:]
        pages[pageIndex] = summary
        // Keep a small bounded chapter-local working set without coupling the
        // context version to task completion order.
        if pages.count > 12 {
            let keep = Set(pages.keys.sorted().suffix(12))
            pages = pages.filter { keep.contains($0.key) }
        }
        pagesByScope[scopeID] = pages
    }

    func resetForDiagnostics() {
        pagesByScope.removeAll()
    }
}
''')

# ---------------------------------------------------------------------------
# Whole-page text prompt: preserve geometry/order and broaden context semantics
# ---------------------------------------------------------------------------
replace_once(
    "mreader/AIPageTranslation.swift",
    '''        let wireItems = items.map { item -> [String: Any] in\n            ["id": item.id, "sourceText": item.sourceText]\n        }''',
    '''        // Keep the already-known page geometry and reading order in the wire\n        // payload. This lets the model resolve nearby references without changing\n        // the one-id-in / one-id-out contract.\n        let wireItems = items.map(\\.jsonObject)'''
)
replace_once(
    "mreader/AIPageTranslation.swift",
    '''        每个 id 必须返回一次。translation 只放译文；不确定时使用空字符串。translationLines 不确定时使用空数组。\n        不要输出思考过程、词义分析或任何 JSON 之外的字符。''',
    '''        每个 id 必须返回一次。translation 只放译文；不确定时使用空字符串。translationLines 不确定时使用空数组。\n        可以利用 items 的 order、textBox、fontScale 和同页相邻原文来判断断句、称呼、代词和语气，但不得改变、合并或拆分 id。\n        无法从原文或上下文确定代词指向时，保留自然的代词表达，不得凭空补人名或剧情事实。\n        不要输出思考过程、词义分析或任何 JSON 之外的字符。'''
)
replace_once(
    "mreader/AIPageTranslation.swift",
    '''        上下文（只用于术语一致，不要复述）：''',
    '''        上下文快照（用于称呼、术语、代词、语气和跨气泡指代消歧；不要复述或新增事实）：'''
)

# ---------------------------------------------------------------------------
# Coordinator: immutable context snapshot, same-page supplement semantics,
# visual recovery gets rejected candidates too.
# ---------------------------------------------------------------------------
replace_once(
    "mreader/AITranslationPageCoordinator.swift",
    'static let translationCacheRevision = "translation-v20-partial-aware-canonical-translation"',
    'static let translationCacheRevision = "translation-v21-context-recovery"'
)
replace_once(
    "mreader/AITranslationPageCoordinator.swift",
    '''    let sourceLanguagePreference: TranslationSourceLanguage?\n    let previousContext: String''',
    '''    let sourceLanguagePreference: TranslationSourceLanguage?\n    var previousContext: String\n    /// Stable scope/page identity for chapter-local context. Existing callers\n    /// remain source-compatible because both additions have defaults.\n    let contextScopeID: String? = nil\n    let pageIndex: Int? = nil'''
)
replace_once(
    "mreader/AITranslationPageCoordinator.swift",
    '''            sourceLanguagePreference?.rawValue ?? "auto",\n            previousContext,\n            translationPromptTemplate,''',
    '''            sourceLanguagePreference?.rawValue ?? "auto",\n            contextScopeID ?? "unscoped",\n            pageIndex.map(String.init) ?? "no-page",\n            previousContext,\n            translationPromptTemplate,'''
)
replace_once(
    "mreader/AITranslationPageCoordinator.swift",
    '''    func translatedBlocks(for request: AITranslationPageRequest) async throws -> [TextBlock] {\n        let key = request.cacheKey\n        if let cached = cachedBlocks(forKey: key) {\n            print("MReader AI translation cache hit key=\\(key.prefix(10)) blocks=\\(cached.count)")\n            return cached\n        }\n        if let existing = inFlight[key] {\n            print("MReader AI translation joined in-flight key=\\(key.prefix(10))")\n            return try await existing.value.blocks\n        }\n\n        let task = Task.detached(priority: .userInitiated) {\n            try await AITranslationPagePipeline.translate(request)\n        }\n        inFlight[key] = task\n        do {\n            let result = try await task.value\n            inFlight[key] = nil\n            if result.isComplete {\n                store(result.blocks, forKey: key)\n            } else {\n                print("MReader AI translation cache skipped explicit partial key=\\(key.prefix(10)) blocks=\\(result.blocks.count)")\n            }\n            return result.blocks\n        } catch {\n            inFlight[key] = nil\n            throw error\n        }\n    }''',
    '''    func translatedBlocks(for request: AITranslationPageRequest) async throws -> [TextBlock] {\n        var contextualRequest = request\n        contextualRequest.previousContext = await TranslationContextRegistry.shared.context(\n            scopeID: request.contextScopeID,\n            pageIndex: request.pageIndex,\n            seed: request.previousContext\n        )\n        let key = contextualRequest.cacheKey\n        if let cached = cachedBlocks(forKey: key) {\n            print("MReader AI translation cache hit key=\\(key.prefix(10)) blocks=\\(cached.count)")\n            await TranslationContextRegistry.shared.record(\n                scopeID: contextualRequest.contextScopeID,\n                pageIndex: contextualRequest.pageIndex,\n                blocks: cached\n            )\n            return cached\n        }\n        if let existing = inFlight[key] {\n            print("MReader AI translation joined in-flight key=\\(key.prefix(10))")\n            return try await existing.value.blocks\n        }\n\n        let task = Task.detached(priority: .userInitiated) {\n            try await AITranslationPagePipeline.translate(contextualRequest)\n        }\n        inFlight[key] = task\n        do {\n            let result = try await task.value\n            inFlight[key] = nil\n            if result.isComplete {\n                store(result.blocks, forKey: key)\n                await TranslationContextRegistry.shared.record(\n                    scopeID: contextualRequest.contextScopeID,\n                    pageIndex: contextualRequest.pageIndex,\n                    blocks: result.blocks\n                )\n            } else {\n                print("MReader AI translation cache skipped explicit partial key=\\(key.prefix(10)) blocks=\\(result.blocks.count)")\n            }\n            return result.blocks\n        } catch {\n            inFlight[key] = nil\n            throw error\n        }\n    }'''
)
replace_once(
    "mreader/AITranslationPageCoordinator.swift",
    '''                sourceLanguage: request.sourceLanguagePreference,\n                visionModelDescriptor: request.configuration.visionModelDescriptor,''',
    '''                sourceLanguage: request.sourceLanguagePreference,\n                previousContext: request.previousContext,\n                visionModelDescriptor: request.configuration.visionModelDescriptor,'''
)
replace_once(
    "mreader/AITranslationPageCoordinator.swift",
    '''            resolvedBlocks = try await TranslationRuntimeService.visualVerifyOCRRegions(\n                image: ocrImage,\n                blocks: localResult.resolvedBlocks,''',
    '''            // Rejected candidates retain geometry/reason and must remain visible\n            // to visual review; otherwise weak but real text can never re-enter the\n            // translation pipeline.\n            let reviewBlocks = localResult.resolvedBlocks + localResult.rejectedBlocks\n            resolvedBlocks = try await TranslationRuntimeService.visualVerifyOCRRegions(\n                image: ocrImage,\n                blocks: reviewBlocks,'''
)
replace_once(
    "mreader/AITranslationPageCoordinator.swift",
    '''                detectedLanguage: localResult.detectedLanguage,\n                visualVerificationEnabled: request.usesVisualOCRVerification\n            )''',
    '''                detectedLanguage: localResult.detectedLanguage,\n                visualVerificationEnabled: request.usesVisualOCRVerification,\n                coverageRecoveryRequested: localResult.quality?.isSuspicious == true\n                    || !localResult.rejectedBlocks.isEmpty\n            )'''
)
replace_once(
    "mreader/AITranslationPageCoordinator.swift",
    '''                let localContext = blocks.count > 1\n                    ? AITranslator.pageContextDescription(blocks: blocks, currentIndex: index)\n                    : ""\n                let pageContext = [request.previousContext, localContext]\n                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }\n                    .filter { !$0.isEmpty }\n                    .joined(separator: "\\n")''',
    '''                let pageContext = TranslationContextBuilder.promptContext(\n                    previousContext: request.previousContext,\n                    pageBlocks: blocks,\n                    requestedIndexes: [index]\n                )'''
)
replace_once(
    "mreader/AITranslationPageCoordinator.swift",
    '''        let requestedBlocks = indexes.map { blocks[$0] }\n        let result = try await TranslationRuntimeService.translatePage(''',
    '''        let requestedBlocks = indexes.map { blocks[$0] }\n        let fullPageContext = TranslationContextBuilder.promptContext(\n            previousContext: request.previousContext,\n            pageBlocks: blocks,\n            requestedIndexes: indexes\n        )\n        let result = try await TranslationRuntimeService.translatePage('''
)
replace_once(
    "mreader/AITranslationPageCoordinator.swift",
    '''            sourceLanguage: request.sourceLanguagePreference,\n            previousContext: request.previousContext,\n            modelDescriptor: request.configuration.textModelDescriptor''',
    '''            sourceLanguage: request.sourceLanguagePreference,\n            previousContext: fullPageContext,\n            modelDescriptor: request.configuration.textModelDescriptor'''
)

# ---------------------------------------------------------------------------
# AITranslator: context reaches vision; candidate review becomes geometry/
# rejection aware; generic page recovery can recover weak horizontal text.
# ---------------------------------------------------------------------------
replace_once(
    "mreader/AITranslator.swift",
    '''        blocks\n            .filter { block in\n                block.confidence < confidenceThreshold || appearsGarbled(block.text)\n            }\n            .sorted { lhs, rhs in\n                if lhs.confidence != rhs.confidence { return lhs.confidence < rhs.confidence }\n                return lhs.boundingBox.minY < rhs.boundingBox.minY\n            }\n            .prefix(max(maximumCount, 0))\n            .map { block in\n                let horizontalPadding = max(block.boundingBox.width * 0.15, 0.008)\n                let verticalPadding = max(block.boundingBox.height * 0.15, 0.006)''',
    '''        blocks\n            .filter { block in\n                block.isFiltered\n                    || block.textOrientation == .vertical\n                    || block.confidence < confidenceThreshold\n                    || appearsGarbled(block.text)\n            }\n            .sorted { lhs, rhs in\n                if lhs.isFiltered != rhs.isFiltered { return lhs.isFiltered }\n                let lhsVertical = lhs.textOrientation == .vertical\n                let rhsVertical = rhs.textOrientation == .vertical\n                if lhsVertical != rhsVertical { return lhsVertical }\n                if lhs.confidence != rhs.confidence { return lhs.confidence < rhs.confidence }\n                return lhs.boundingBox.minY < rhs.boundingBox.minY\n            }\n            .prefix(max(maximumCount, 0))\n            .map { block in\n                // A vertical crop needs enough horizontal neighbourhood to see\n                // sibling columns and the physical bubble instead of reviewing\n                // one isolated column forever.\n                let horizontalPadding = block.textOrientation == .vertical\n                    ? max(block.boundingBox.width * 1.25, 0.04)\n                    : max(block.boundingBox.width * 0.20, 0.010)\n                let verticalPadding = block.textOrientation == .vertical\n                    ? max(block.boundingBox.height * 0.20, 0.010)\n                    : max(block.boundingBox.height * 0.20, 0.008)'''
)
replace_once(
    "mreader/AITranslator.swift",
    '''        maximumCount: Int = 3''',
    '''        maximumCount: Int = 6'''
)
replace_once(
    "mreader/AITranslator.swift",
    '''    你是一个漫画图片文字识别与翻译助手。请只处理图片中的文字，不要描述画面、人物、动作、身体、场景或剧情，不要评价、总结、续写或添加任何新细节。''',
    '''    你是一个漫画图片文字识别与翻译助手。可以利用画面中的指代方向、说话者位置和表情等视觉线索消歧，但这些线索只能用于判断文字含义；最终只处理图片中的文字，不要描述画面、人物、动作、身体、场景或剧情，不要评价、总结、续写或添加任何新细节。无法确定代词指向时不要凭空补人名。'''
)
# Public vision wrappers: add and forward previousContext.
replace_once(
    "mreader/AITranslator.swift",
    '''        sourceLanguage: TranslationSourceLanguage? = nil,\n        visionModelDescriptor: AIModelDescriptor? = nil,''',
    '''        sourceLanguage: TranslationSourceLanguage? = nil,\n        previousContext: String = "",\n        visionModelDescriptor: AIModelDescriptor? = nil,'''
)
replace_once(
    "mreader/AITranslator.swift",
    '''            sourceLanguage: sourceLanguage,\n            visionModelDescriptor: visionModelDescriptor,''',
    '''            sourceLanguage: sourceLanguage,\n            previousContext: previousContext,\n            visionModelDescriptor: visionModelDescriptor,'''
)
# Same signature pattern occurs again for translateVisionPageWithStatus.
replace_once(
    "mreader/AITranslator.swift",
    '''        sourceLanguage: TranslationSourceLanguage? = nil,\n        visionModelDescriptor: AIModelDescriptor? = nil,''',
    '''        sourceLanguage: TranslationSourceLanguage? = nil,\n        previousContext: String = "",\n        visionModelDescriptor: AIModelDescriptor? = nil,'''
)
replace_once(
    "mreader/AITranslator.swift",
    '''            translationTarget: target,\n            translationPromptTemplate: promptTemplate,\n            strictTranslationGeometry: false''',
    '''            translationTarget: target,\n            translationPromptTemplate: TranslationContextBuilder.visionPrompt(\n                basePrompt: promptTemplate,\n                previousContext: previousContext\n            ),\n            strictTranslationGeometry: false'''
)
replace_once(
    "mreader/AITranslator.swift",
    '''                promptTemplate: defaultTranslationPromptTemplate,\n                sourceLanguage: sourceLanguage,\n                modelDescriptor: textFallbackModelDescriptor''',
    '''                promptTemplate: defaultTranslationPromptTemplate,\n                sourceLanguage: sourceLanguage,\n                previousContext: TranslationContextBuilder.promptContext(\n                    previousContext: previousContext,\n                    pageBlocks: translated,\n                    requestedIndexes: missingIndexes\n                ),\n                modelDescriptor: textFallbackModelDescriptor'''
)
# Verification signature + recovered candidates.
replace_once(
    "mreader/AITranslator.swift",
    '''        detectedLanguage: String? = nil,\n        visualVerificationEnabled: Bool = true\n    ) async throws -> [TextBlock] {''',
    '''        detectedLanguage: String? = nil,\n        visualVerificationEnabled: Bool = true,\n        coverageRecoveryRequested: Bool = false\n    ) async throws -> [TextBlock] {'''
)
replace_once(
    "mreader/AITranslator.swift",
    '''                    isFiltered: original.isFiltered,\n                    filterReason: original.filterReason,''',
    '''                    // A rejected/uncertain local candidate that passed a\n                    // visual text+geometry match is explicitly recovered.\n                    isFiltered: false,\n                    filterReason: nil,'''
)
replace_once(
    "mreader/AITranslator.swift",
    '''        if JapaneseVerticalOCRService.shouldRequestPageRecovery(\n            in: image,\n            existingBlocks: corrected,\n            isRightToLeft: isRightToLeft,\n            sourceLanguagePreference: effectiveSourceLanguage\n        ) {\n            do {''',
    '''        let japanesePageRecoveryRequested = JapaneseVerticalOCRService.shouldRequestPageRecovery(\n            in: image,\n            existingBlocks: corrected.filter { !$0.isFiltered },\n            isRightToLeft: isRightToLeft,\n            sourceLanguagePreference: effectiveSourceLanguage\n        )\n        if japanesePageRecoveryRequested || coverageRecoveryRequested {\n            do {'''
)
replace_once(
    "mreader/AITranslator.swift",
    '''                    additionalInstructions: "这是日文竖排页面的整页补漏。请识别页面中所有可读文字，包括本地 OCR 没有产生 block 的整列竖排文字；不要因为已有识别结果而省略任何文字。",''',
    '''                    additionalInstructions: japanesePageRecoveryRequested\n                        ? "这是日文竖排页面的整页补漏。请识别页面中所有可读文字，包括本地 OCR 没有产生 block 的整列竖排文字；不要因为已有识别结果而省略任何文字。"\n                        : "这是 OCR 覆盖补漏。请重新检查整页所有可读文字，特别关注被本地质量门排除的弱对比、小字号、英文或韩文横排区域；只返回图中真实存在的文字，不要根据上下文猜字。",'''
)
replace_once(
    "mreader/AITranslator.swift",
    '''            if let duplicateIndex {\n                if candidate.confidence > merged[duplicateIndex].confidence {\n                    merged[duplicateIndex] = candidate\n                }\n            } else {''',
    '''            if let duplicateIndex {\n                if merged[duplicateIndex].isFiltered\n                    || candidate.confidence > merged[duplicateIndex].confidence {\n                    merged[duplicateIndex] = candidate\n                }\n            } else {'''
)

# ---------------------------------------------------------------------------
# Reader: scope live/prefetch context, let rejected blocks reach review, and
# feed direct OCR / Apple fallback paths the same context contract.
# ---------------------------------------------------------------------------
replace_once(
    "mreader/ReaderView.swift",
    '''                        sourceLanguagePreference: comic.translationSourceLanguage,\n                        previousContext: ""\n                    )''',
    '''                        sourceLanguagePreference: comic.translationSourceLanguage,\n                        previousContext: "",\n                        contextScopeID: TranslationContextBuilder.scopeID(\n                            comicID: comicID,\n                            target: target\n                        ),\n                        pageIndex: pageIndex\n                    )'''
)
replace_once(
    "mreader/ReaderView.swift",
    '''            sourceLanguagePreference: comicTranslationSourceLanguage,\n            previousContext: ""\n        )''',
    '''            sourceLanguagePreference: comicTranslationSourceLanguage,\n            previousContext: "",\n            contextScopeID: TranslationContextBuilder.scopeID(\n                comicID: comicID,\n                target: TranslationTargetLanguage.migrateLegacyValue(targetLanguage)\n            ),\n            pageIndex: pageIndex\n        )'''
)
replace_once(
    "mreader/ReaderView.swift",
    '''            let corrected = try await TranslationRuntimeService.visualVerifyOCRRegions(\n                image: ocrImage,\n                blocks: localResult.resolvedBlocks,''',
    '''            let reviewBlocks = localResult.resolvedBlocks + localResult.rejectedBlocks\n            let corrected = try await TranslationRuntimeService.visualVerifyOCRRegions(\n                image: ocrImage,\n                blocks: reviewBlocks,'''
)
replace_once(
    "mreader/ReaderView.swift",
    '''                detectedLanguage: localResult.detectedLanguage,\n                visualVerificationEnabled: ocrVisualVerificationEnabled\n            )\n            let segmentation = MangaTextSegmenter.segment(\n                corrected,''',
    '''                detectedLanguage: localResult.detectedLanguage,\n                visualVerificationEnabled: ocrVisualVerificationEnabled,\n                coverageRecoveryRequested: localResult.quality?.isSuspicious == true\n                    || !localResult.rejectedBlocks.isEmpty\n            )\n            let usableCorrected = corrected.filter { !$0.isFiltered }\n            let segmentation = MangaTextSegmenter.segment(\n                usableCorrected,'''
)
replace_once(
    "mreader/ReaderView.swift",
    '''                resolvedBlocks: corrected,\n                lineBlocks: segmentation.lines,\n                bubbleBlocks: segmentation.bubbles,\n                rejectedBlocks: localResult.rejectedBlocks,''',
    '''                resolvedBlocks: usableCorrected,\n                lineBlocks: segmentation.lines,\n                bubbleBlocks: segmentation.bubbles,\n                rejectedBlocks: corrected.filter(\\.isFiltered),'''
)
# Direct OCR path: snapshot context before page translation.
replace_once(
    "mreader/ReaderView.swift",
    '''        let requestTarget = TranslationTargetLanguage.migrateLegacyValue(targetLanguage)\n        let requestPromptTemplate = translationStyleInstructions\n        var translatedIndexes = Set<Int>()''',
    '''        let requestTarget = TranslationTargetLanguage.migrateLegacyValue(targetLanguage)\n        let requestPromptTemplate = translationStyleInstructions\n        let contextScopeID = TranslationContextBuilder.scopeID(comicID: comicID, target: requestTarget)\n        let inheritedContext = await TranslationContextRegistry.shared.context(\n            scopeID: contextScopeID,\n            pageIndex: pageIndex\n        )\n        var translatedIndexes = Set<Int>()'''
)
replace_once(
    "mreader/ReaderView.swift",
    '''                    sourceLanguage: comicTranslationSourceLanguage,\n                    modelDescriptor: activeConfiguration.textModelDescriptor\n                )''',
    '''                    sourceLanguage: comicTranslationSourceLanguage,\n                    previousContext: TranslationContextBuilder.promptContext(\n                        previousContext: inheritedContext,\n                        pageBlocks: blocks\n                    ),\n                    modelDescriptor: activeConfiguration.textModelDescriptor\n                )'''
)
replace_once(
    "mreader/ReaderView.swift",
    '''                let pageContext = blocks.count > 1\n                    ? AITranslator.pageContextDescription(blocks: blocks, currentIndex: blockIndex)\n                    : ""''',
    '''                let pageContext = TranslationContextBuilder.promptContext(\n                    previousContext: inheritedContext,\n                    pageBlocks: blocks,\n                    requestedIndexes: [blockIndex]\n                )'''
)
# Record direct OCR result at function end.
replace_once(
    "mreader/ReaderView.swift",
    '''        try Task.checkCancellation()\n    }\n\n    private func recognizedPipelineResult(for image: UIImage) async throws -> OCRPipelineResult {''',
    '''        try Task.checkCancellation()\n        await TranslationContextRegistry.shared.record(\n            scopeID: contextScopeID,\n            pageIndex: pageIndex,\n            blocks: textBlocks\n        )\n    }\n\n    private func recognizedPipelineResult(for image: UIImage) async throws -> OCRPipelineResult {'''
)
# Cloud fallback gets previous + full current-page semantics and records result.
replace_once(
    "mreader/ReaderView.swift",
    '''            let requestTarget = TranslationTargetLanguage.migrateLegacyValue(self.targetLanguage)\n            do {\n                // 纯文本兜底：用文本模型而不是昂贵的视觉模型（审查 #14）\n                let pageResult = try await TranslationRuntimeService.translatePage(''',
    '''            let requestTarget = TranslationTargetLanguage.migrateLegacyValue(self.targetLanguage)\n            let contextScopeID = TranslationContextBuilder.scopeID(comicID: self.comicID, target: requestTarget)\n            let inheritedContext = await TranslationContextRegistry.shared.context(\n                scopeID: contextScopeID,\n                pageIndex: self.pageIndex\n            )\n            let pageSnapshot = self.textBlocks\n            do {\n                // 纯文本兜底：用文本模型而不是昂贵的视觉模型（审查 #14）\n                let pageResult = try await TranslationRuntimeService.translatePage('''
)
replace_once(
    "mreader/ReaderView.swift",
    '''                    sourceLanguage: comicTranslationSourceLanguage,\n                    modelDescriptor: activeConfiguration.textModelDescriptor\n                )\n                try Task.checkCancellation()''',
    '''                    sourceLanguage: comicTranslationSourceLanguage,\n                    previousContext: TranslationContextBuilder.promptContext(\n                        previousContext: inheritedContext,\n                        pageBlocks: pageSnapshot,\n                        requestedIndexes: pageSnapshot.indices.filter { index in\n                            missingIDs.contains(pageSnapshot[index].id)\n                        }\n                    ),\n                    modelDescriptor: activeConfiguration.textModelDescriptor\n                )\n                try Task.checkCancellation()'''
)
replace_once(
    "mreader/ReaderView.swift",
    '''                    for (position, block) in missingBlocks.enumerated() {\n                        guard let index = self.textBlocks.firstIndex(where: { $0.id == block.id }),\n                              let value = pageResult.translation(for: "b\\(position)") else { continue }\n                        self.textBlocks[index].translation = value.translation\n                        self.textBlocks[index].translationLines = value.translationLines\n                    }\n                }\n            } catch {''',
    '''                    for (position, block) in missingBlocks.enumerated() {\n                        guard let index = self.textBlocks.firstIndex(where: { $0.id == block.id }),\n                              let value = pageResult.translation(for: "b\\(position)") else { continue }\n                        self.textBlocks[index].translation = value.translation\n                        self.textBlocks[index].translationLines = value.translationLines\n                    }\n                }\n                await TranslationContextRegistry.shared.record(\n                    scopeID: contextScopeID,\n                    pageIndex: self.pageIndex,\n                    blocks: self.textBlocks\n                )\n            } catch {'''
)
# Apple finished page should seed the same registry.
replace_once(
    "mreader/ReaderView.swift",
    '''                        Task {\n                            await AppleTranslationPageCache.shared.store(self.textBlocks, key: cacheKey)\n                        }''',
    '''                        Task {\n                            await AppleTranslationPageCache.shared.store(self.textBlocks, key: cacheKey)\n                            let target = TranslationTargetLanguage.migrateLegacyValue(bridgeTarget)\n                            await TranslationContextRegistry.shared.record(\n                                scopeID: TranslationContextBuilder.scopeID(\n                                    comicID: self.comicID,\n                                    target: target\n                                ),\n                                pageIndex: self.pageIndex,\n                                blocks: self.textBlocks\n                            )\n                        }'''
)

# ---------------------------------------------------------------------------
# Offline: source-first preflight for every concurrent batch, plus source→target
# pairs from already persisted pages. This makes context independent of which
# page finishes translation first.
# ---------------------------------------------------------------------------
replace_once(
    "mreader/OfflineTranslationCoordinator.swift",
    '''nonisolated private struct OfflineTranslationPageWorkerResult: @unchecked Sendable {''',
    '''nonisolated private struct OfflineTranslationSourceContextWork: @unchecked Sendable {\n    let page: ComicPage\n    let comic: ComicBook\n    let sourceSession: OfflineTranslationPageProvider.SourceSession\n    let sourceLanguage: TranslationSourceLanguage\n    let isRightToLeft: Bool\n    let ocrRecognitionMode: OCRRecognitionMode\n}\n\nnonisolated private struct OfflineTranslationPageWorkerResult: @unchecked Sendable {'''
)
replace_once(
    "mreader/OfflineTranslationCoordinator.swift",
    '''                let contextSnapshot = await fixedBatchContexts(\n                    for: batch,\n                    comicID: record.comicID,\n                    setID: record.setID,\n                    minimumPageIndex: record.pageIndexes.min() ?? 0\n                )\n                let processingMode = record.processingMode ?? .vision\n                let sourcePreference = TranslationSourceLanguage(rawValue: record.resolvedSourceLanguage ?? "")\n                    ?? record.sourceLanguage''',
    '''                let processingMode = record.processingMode ?? .vision\n                let sourcePreference = TranslationSourceLanguage(rawValue: record.resolvedSourceLanguage ?? "")\n                    ?? record.sourceLanguage\n                // Phase 1 of each concurrent batch: recognize source text first.\n                // Later pages can use earlier source dialogue without waiting for\n                // an earlier translation task to finish.\n                let batchSourceContext = await sourceFirstBatchContexts(\n                    for: batch,\n                    pages: pages,\n                    comic: comic,\n                    sourceSession: sourceSession,\n                    sourceLanguage: sourcePreference,\n                    isRightToLeft: record.readingDirectionRaw == "rightToLeft",\n                    ocrRecognitionMode: record.ocrRecognitionMode ?? .adaptive\n                )\n                let contextSnapshot = await fixedBatchContexts(\n                    for: batch,\n                    comicID: record.comicID,\n                    setID: record.setID,\n                    minimumPageIndex: record.pageIndexes.min() ?? 0\n                )'''
)
replace_once(
    "mreader/OfflineTranslationCoordinator.swift",
    '''                        previousContext: contextSnapshot[pageIndex] ?? "",''',
    '''                        previousContext: TranslationContextBuilder.versionedContext([\n                            contextSnapshot[pageIndex] ?? "",\n                            batchSourceContext[pageIndex] ?? ""\n                        ]),'''
)
# Insert source-first helper before fixedBatchContexts.
replace_once(
    "mreader/OfflineTranslationCoordinator.swift",
    '''    private func fixedBatchContexts(\n        for pageIndexes: [Int],''',
    r'''    private func sourceFirstBatchContexts(
        for pageIndexes: [Int],
        pages: [ComicPage],
        comic: ComicBook,
        sourceSession: OfflineTranslationPageProvider.SourceSession,
        sourceLanguage: TranslationSourceLanguage,
        isRightToLeft: Bool,
        ocrRecognitionMode: OCRRecognitionMode
    ) async -> [Int: String] {
        let works: [OfflineTranslationSourceContextWork] = pageIndexes.sorted().compactMap { pageIndex in
            guard let page = try? pageAt(pageIndex, pages: pages) else { return nil }
            return OfflineTranslationSourceContextWork(
                page: page,
                comic: comic,
                sourceSession: sourceSession,
                sourceLanguage: sourceLanguage,
                isRightToLeft: isRightToLeft,
                ocrRecognitionMode: ocrRecognitionMode
            )
        }
        var sourceByPage: [Int: String] = [:]
        await withTaskGroup(of: (Int, String).self) { group in
            for work in works {
                group.addTask {
                    do {
                        let data = try await OfflineTranslationPageProvider.data(
                            for: work.comic,
                            page: work.page,
                            session: work.sourceSession
                        )
                        let image = try OfflineTranslationPageProvider.image(
                            for: data,
                            pageIndex: work.page.index
                        )
                        let options = OCRPreprocessor.Options(
                            isRightToLeft: work.isRightToLeft,
                            minimumTextHeight: 0.008,
                            recognitionMode: work.ocrRecognitionMode,
                            sourceLanguagePreference: work.sourceLanguage
                        )
                        let cacheRequest = OCRRecognitionCacheRequest(
                            pageURL: work.page.url,
                            fallbackImage: image,
                            options: options
                        )
                        let result = try await OCRRuntimeService.recognize(for: cacheRequest)
                        return (
                            work.page.index,
                            TranslationContextBuilder.sourceOnlySummary(
                                pageIndex: work.page.index,
                                blocks: result.bubbleBlocks
                            )
                        )
                    } catch is CancellationError {
                        return (work.page.index, "")
                    } catch {
                        print("MReader offline source-context preflight skipped page=\(work.page.index + 1) reason=\(error.localizedDescription)")
                        return (work.page.index, "")
                    }
                }
            }
            for await (pageIndex, context) in group {
                sourceByPage[pageIndex] = context
            }
        }

        let sorted = pageIndexes.sorted()
        var result: [Int: String] = [:]
        for pageIndex in sorted {
            let priorSource = sorted
                .filter { $0 < pageIndex }
                .suffix(2)
                .compactMap { sourceByPage[$0] }
            result[pageIndex] = TranslationContextBuilder.mergeContexts(priorSource)
        }
        return result
    }

    private func fixedBatchContexts(
        for pageIndexes: [Int],'''
)
# Persisted context should preserve source↔translation pairs, not target-only text.
replace_once(
    "mreader/OfflineTranslationCoordinator.swift",
    '''                lines.append("第\\(index + 1)页：\\(translation)")''',
    '''                let source = block.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)\n                if source.isEmpty {\n                    lines.append("第\\(index + 1)页译文：\\(translation)")\n                } else {\n                    lines.append("第\\(index + 1)页：原文=\\(source) → 译文=\\(translation)")\n                }'''
)

# Offline prompt context semantics and revision.
replace_once(
    "mreader/OfflineTranslationPrompt.swift",
    'static let revision = "offline-vision-v3"',
    'static let revision = "offline-vision-v4-context"'
)
replace_once(
    "mreader/OfflineTranslationPrompt.swift",
    '''        仅用于理解称呼和上下文的前序页面译文（不得复制为新的气泡）：''',
    '''        上下文快照（可能同时包含前序原文、已确认原文→译文对照和同批次预识别原文；仅用于称呼、术语、代词、语气与指代消歧，不得复制为新的气泡）：'''
)
replace_once(
    "mreader/OfflineTranslationPrompt.swift",
    '''        同一气泡内的碎片应合并，不同气泡不能合并；translation 必须非空。translationLines 仅是换行建议，不需要时可输出空数组。''',
    '''        同一气泡内的碎片应合并，不同气泡不能合并；translation 必须非空。translationLines 仅是换行建议，不需要时可输出空数组。\n        可以利用当前画面中的指代方向、说话者位置和表情来消歧，但不得输出画面描述；无法可靠判断代词指向时不得凭空补人名。'''
)

# ---------------------------------------------------------------------------
# Regression tests
# ---------------------------------------------------------------------------
Path("mreaderTests/TranslationContextRecoveryRegressionTests.swift").write_text(r'''import XCTest
@testable import mreader

@MainActor
final class TranslationContextRecoveryRegressionTests: XCTestCase {
    private func block(
        _ text: String,
        translation: String? = nil,
        x: CGFloat = 0.1,
        confidence: Double = 0.95,
        filtered: Bool = false,
        orientation: TextOrientation = .horizontal
    ) -> TextBlock {
        TextBlock(
            text: text,
            boundingBox: CGRect(x: x, y: 0.2, width: 0.12, height: 0.08),
            translation: translation,
            confidence: confidence,
            ocrSource: "test",
            isFiltered: filtered,
            filterReason: filtered ? "OCR质量可疑" : nil,
            estimatedFontScale: 0.04,
            textOrientation: orientation
        )
    }

    func testPagePromptPreservesGeometryOrderAndContextSemantics() throws {
        let item = AIPageTranslationItem(block: block("行くぞ"), order: 0)
        let prompt = try AIPageTranslationPromptBuilder.prompt(
            items: [item],
            sourceLanguage: .japanese,
            target: .simplifiedChinese,
            styleInstructions: "自然对白",
            previousContext: "原文=兄さん → 译文=哥哥"
        )
        XCTAssertTrue(prompt.contains("\\\"order\\\":0"))
        XCTAssertTrue(prompt.contains("\\\"textBox\\\""))
        XCTAssertTrue(prompt.contains("称呼、术语、代词、语气"))
        XCTAssertTrue(prompt.contains("原文=兄さん → 译文=哥哥"))
        XCTAssertTrue(prompt.contains("不得凭空补人名"))
    }

    func testSubsetRetryContextContainsAlreadyTranslatedNeighbours() {
        let blocks = [
            block("兄さん", translation: "哥哥", x: 0.1),
            block("どこへ行く？", x: 0.3)
        ]
        let context = TranslationContextBuilder.promptContext(
            previousContext: "",
            pageBlocks: blocks,
            requestedIndexes: [1]
        )
        XCTAssertTrue(context.contains("#1 [已译] 原文=兄さん | 译文=哥哥"))
        XCTAssertTrue(context.contains("#2 [待翻译] 原文=どこへ行く？"))
        XCTAssertTrue(context.contains("x=0.300"))
    }

    func testContextRegistryIsPageOrderedNotCompletionOrdered() async {
        let scope = "test-scope"
        await TranslationContextRegistry.shared.resetForDiagnostics()
        await TranslationContextRegistry.shared.record(
            scopeID: scope,
            pageIndex: 1,
            blocks: [block("二", translation: "two")]
        )
        await TranslationContextRegistry.shared.record(
            scopeID: scope,
            pageIndex: 0,
            blocks: [block("一", translation: "one")]
        )
        let first = await TranslationContextRegistry.shared.context(
            scopeID: scope,
            pageIndex: 2
        )
        await TranslationContextRegistry.shared.resetForDiagnostics()
        await TranslationContextRegistry.shared.record(
            scopeID: scope,
            pageIndex: 0,
            blocks: [block("一", translation: "one")]
        )
        await TranslationContextRegistry.shared.record(
            scopeID: scope,
            pageIndex: 1,
            blocks: [block("二", translation: "two")]
        )
        let second = await TranslationContextRegistry.shared.context(
            scopeID: scope,
            pageIndex: 2
        )
        XCTAssertEqual(first, second)
        XCTAssertLessThan(first.range(of: "第1页")!.lowerBound, first.range(of: "第2页")!.lowerBound)
    }

    func testVisualReviewIncludesRejectedAndVerticalCandidates() {
        let rejected = block("faint", x: 0.05, filtered: true)
        let vertical = block("縦書き", x: 0.30, orientation: .vertical)
        let stable = block("stable", x: 0.60)
        let regions = AITranslator.visualVerificationRegionsForDiagnostics(
            [stable, vertical, rejected],
            maximumCount: 6
        )
        let ids = Set(regions.map(\\.blockID))
        XCTAssertTrue(ids.contains(rejected.id))
        XCTAssertTrue(ids.contains(vertical.id))
        XCTAssertFalse(ids.contains(stable.id))
        let verticalRegion = regions.first { $0.blockID == vertical.id }!
        XCTAssertGreaterThan(verticalRegion.sourceRect.width, vertical.boundingBox.width * 2)
    }
}
''')

# Temporary patch machinery must not survive in the branch diff.
Path("scripts/apply_phase3_translation_patch.py").unlink(missing_ok=True)
Path(".github/workflows/phase3-translation-patch.yml").unlink(missing_ok=True)
print("phase 3 translation patch applied")
