import CoreGraphics
import Foundation
import NaturalLanguage

nonisolated enum AITranslationRequestPolicy {
    static let pageModelAttempts = 1
    static let fallbackModelAttempts = 1
    static let connectionTestTimeout: TimeInterval = 25
    static let bubbleRequestTimeout: TimeInterval = 60
    static let visionRequestTimeout: TimeInterval = 150
    static let jsonRepairRequestTimeout: TimeInterval = 90
    static let maximumPageRequestTimeout: TimeInterval = 180

    /// Compatibility alias for older callers. New page requests must provide
    /// their item count so the timeout reflects the amount of JSON to produce.
    static var pageRequestTimeout: TimeInterval {
        pageRequestTimeout(itemCount: 1)
    }

    /// Compatibility alias for the old fallback name.
    static var fallbackRequestTimeout: TimeInterval {
        bubbleRequestTimeout
    }

    static func pageRequestTimeout(itemCount: Int) -> TimeInterval {
        let count = max(itemCount, 1)
        return min(
            maximumPageRequestTimeout,
            max(90, 60 + Double(count) * 6)
        )
    }

    static func timeout(for kind: AIRequestKind, itemCount: Int = 1) -> TimeInterval {
        switch kind {
        case .page:
            return pageRequestTimeout(itemCount: itemCount)
        case .bubble:
            return bubbleRequestTimeout
        case .vision:
            return visionRequestTimeout
        case .connectionTest:
            return connectionTestTimeout
        case .jsonRepair:
            return jsonRepairRequestTimeout
        }
    }

    /// A transport attempt plus at most one retry. Connection tests and JSON
    /// repair stay single-shot to avoid making a settings probe or a malformed
    /// page response fan out into more requests.
    static func maximumAttempts(for kind: AIRequestKind) -> Int {
        switch kind {
        case .connectionTest, .jsonRepair:
            return 1
        case .page, .bubble, .vision:
            return 1 + max(pageModelAttempts, 1)
        }
    }

    static func shouldRetry(error: Error) -> Bool {
        if let urlError = error as? URLError {
            return urlError.code == .timedOut || urlError.code == .networkConnectionLost
        }
        guard let requestError = error as? AITranslationRequestError,
              let statusCode = requestError.statusCode else {
            return false
        }
        return [408, 429, 502, 503, 504].contains(statusCode)
    }

    static func retryDelay(for error: Error) -> TimeInterval {
        if case let requestError as AITranslationRequestError = error {
            if let retryAfter = requestError.retryAfterSeconds {
                // Respect the provider's backoff. Cap only pathological server
                // values so one malformed header cannot suspend a page task for
                // hours; this is still far longer than the normal retry delay.
                return min(Double(retryAfter), 300)
            }
            if requestError.statusCode == 429 {
                return 5
            }
        }
        return 1.5
    }

    static var maximumOCRWaitBeforeResult: TimeInterval {
        pageRequestTimeout(itemCount: 20)
            + Double(fallbackModelAttempts) * fallbackRequestTimeout
    }

    static func shouldUsePageTranslation(blockCount: Int) -> Bool {
        blockCount > 1
    }
}

nonisolated struct AIPageTranslationItem: Sendable, Equatable {
    let id: String
    let sourceText: String
    let order: Int
    let boundingBox: CGRect
    let estimatedFontScale: Double
    let textColorHex: String?

    init(
        id: String,
        sourceText: String,
        order: Int,
        boundingBox: CGRect = .zero,
        estimatedFontScale: Double = 0,
        textColorHex: String? = nil
    ) {
        self.id = id
        self.sourceText = sourceText
        self.order = order
        self.boundingBox = boundingBox
        self.estimatedFontScale = estimatedFontScale
        self.textColorHex = textColorHex
    }

    init(block: TextBlock, order: Int) {
        self.init(
            // 线上 ID 用短序号 b0/b1/...，避免让便宜模型抄写长 UUID（审查 #5）
            id: "b\(order)",
            sourceText: block.text,
            order: order,
            boundingBox: block.boundingBox,
            estimatedFontScale: block.estimatedFontScale,
            textColorHex: block.textColorHex
        )
    }

    var jsonObject: [String: Any] {
        [
            "id": id,
            "order": order,
            "sourceText": sourceText,
            "textBox": [
                "x": boundingBox.minX,
                "y": boundingBox.minY,
                "width": boundingBox.width,
                "height": boundingBox.height
            ],
            "fontScale": estimatedFontScale,
            "textColor": textColorHex ?? "unknown"
        ]
    }
}

nonisolated struct AIPageTranslatedItem: Sendable, Equatable {
    let id: String
    let translation: String
    let translationLines: [String]
}

nonisolated struct AIPageTranslationResult: Sendable, Equatable {
    let items: [AIPageTranslatedItem]
    let missingIDs: [String]

    func translation(for id: String) -> AIPageTranslatedItem? {
        items.first { $0.id == id }
    }
}

nonisolated enum AIPageTranslationPromptBuilder {
    static let strictSystemPrompt = """
    你是无对话能力的 JSON 翻译函数。只翻译输入 items 的 sourceText。
    不得输出分析、推理、解释、前言、Markdown 或代码围栏。整个响应必须是且仅是一个 JSON 对象，
    第一个字符必须是 {，最后一个字符必须是 }。每个输入 id 必须原样返回一次；无法翻译时 translation=""、translationLines=[]。
    """

    /// V2 固定协议：协议部分不可被用户提示词覆盖；用户只能编辑“翻译风格要求”。
    static func prompt(
        items: [AIPageTranslationItem],
        sourceLanguage: TranslationSourceLanguage?,
        target: TranslationTargetLanguage,
        styleInstructions: String,
        previousContext: String = ""
    ) throws -> String {
        let wireItems = items.map { item -> [String: Any] in
            ["id": item.id, "sourceText": item.sourceText]
        }
        let payload: [String: Any] = ["items": wireItems]
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        )
        guard let json = String(data: data, encoding: .utf8) else {
            throw AIPageTranslationParserError.invalidJSON
        }
        let source = sourceLanguage?.rawValue ?? "auto"
        let style = styleInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = previousContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let contextSection = context.isEmpty ? "（无）" : context
        return """
        原文语言：\(source)
        目标语言：\(target.modelInstruction)
        输入 items 已完成 OCR；不要识别图片，不要讨论 OCR 是否正确，不要合并、拆分、新增或遗漏 id。
        每个 id 必须返回一次。translation 只放译文；不确定时使用空字符串。translationLines 不确定时使用空数组。
        不要输出思考过程、词义分析或任何 JSON 之外的字符。

        翻译风格要求（只能影响措辞）：
        \(style)

        上下文（只用于术语一致，不要复述）：
        \(contextSection)

        输入：\(json)
        """
    }
}

nonisolated enum AIPageTranslationSchemaBuilder {
    static func responseFormat(for items: [AIPageTranslationItem]) -> AITransportResponseFormat? {
        guard let schema = try? schema(for: items.map(\.id)) else { return nil }
        return .jsonSchema(name: "mreader_page_translation_v1", schema: schema)
    }

    static func schema(for expectedIDs: [String]) throws -> Data {
        let itemSchema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": ["id", "translation", "translationLines"],
            "properties": [
                "id": ["type": "string", "enum": expectedIDs],
                "translation": ["type": "string"],
                "translationLines": [
                    "type": "array",
                    "items": ["type": "string"]
                ]
            ]
        ]
        let object: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": ["items"],
            "properties": [
                "items": [
                    "type": "array",
                    "minItems": expectedIDs.count,
                    "maxItems": expectedIDs.count,
                    "items": itemSchema
                ]
            ]
        ]
        guard JSONSerialization.isValidJSONObject(object) else {
            throw AIPageTranslationParserError.invalidJSON
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

nonisolated enum AIPageTranslationRepairPromptBuilder {
    static let systemPrompt = """
    你不是翻译模型，而是 JSON 修复器。只能把已有响应重组为指定 JSON。
    禁止重新分析、重新翻译、解释或输出 Markdown。只能输出一个 JSON 对象；缺失内容使用空字符串和空数组。
    """

    static func prompt(
        items: [AIPageTranslationItem],
        malformedResponse: String,
        target: TranslationTargetLanguage
    ) throws -> String {
        let expected = items.map { ["id": $0.id, "sourceText": $0.sourceText] }
        let data = try JSONSerialization.data(withJSONObject: ["items": expected], options: [.sortedKeys])
        guard let expectedJSON = String(data: data, encoding: .utf8) else {
            throw AIPageTranslationParserError.invalidJSON
        }
        let boundedResponse = String(malformedResponse.prefix(12_000))
        return """
        目标语言：\(target.modelInstruction)
        必须返回 expected items 中每个 id 一次，不得增加、删除、合并或拆分 id。
        只保留原响应中已经出现的译文；缺失内容填空字符串，translationLines 缺失填空数组。
        expected items：
        \(expectedJSON)

        malformed response（仅作已有内容来源）：
        <response>
        \(boundedResponse)
        </response>
        """
    }
}

nonisolated enum AIPageTranslationParserError: LocalizedError, Sendable {
    case invalidJSON
    case emptyResult
    case pageLanguageMismatch

    var errorDescription: String? {
        switch self {
        case .invalidJSON: return "整页翻译返回格式无效"
        case .emptyResult: return "整页翻译没有返回可用文本"
        case .pageLanguageMismatch: return "整页翻译语言与目标语言不一致"
        }
    }
}

nonisolated enum AIPageTranslationResponseClassification: String, Sendable, Equatable {
    case jsonLike
    case pureProse
}

nonisolated enum AIPageTranslationParser {
    /// Distinguishes a response which contains recoverable translation JSON
    /// from reasoning/prose. This is deliberately separate from strict parsing:
    /// a 200 response with prose is a provider/model semantic capability issue,
    /// while a malformed object should get the single repair request.
    static func classifyResponse(
        _ content: String,
        expectedItems: [AIPageTranslationItem]
    ) -> AIPageTranslationResponseClassification {
        let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedJSONData(from: normalized) != nil {
            return .jsonLike
        }
        let lowered = normalized.lowercased()
        let hasContainerSignal = lowered.contains("{") || lowered.contains("[")
        let hasJSONKeySignal = normalized.range(
            of: #""(?:items|translations?|id|translation(?:lines?)?)"\s*:"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
        let hasExpectedIDSignal = expectedItems.contains { item in
            let quotedID = "\"\(item.id)\""
            return normalized.contains(quotedID) && normalized.contains(":")
        }
        // Mentioning “JSON”, “items”, or an id in ordinary reasoning is not
        // enough to trigger a repair request. Repair is reserved for content
        // that still has an object/array or a JSON key/value shape.
        return hasContainerSignal || hasJSONKeySignal || hasExpectedIDSignal
            ? .jsonLike
            : .pureProse
    }

    static func parse(
        _ content: String,
        expectedItems: [AIPageTranslationItem],
        target: TranslationTargetLanguage
    ) throws -> AIPageTranslationResult {
        guard let data = normalizedJSONData(from: content),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw AIPageTranslationParserError.invalidJSON
        }

        let rawItems: [[String: Any]]
        if let dictionary = object as? [String: Any] {
            rawItems = (dictionary["items"] as? [[String: Any]])
                ?? (dictionary["translations"] as? [[String: Any]])
                ?? []
        } else if let array = object as? [[String: Any]] {
            rawItems = array
        } else {
            throw AIPageTranslationParserError.invalidJSON
        }

        let expectedByID = Dictionary(uniqueKeysWithValues: expectedItems.map { ($0.id, $0) })
        var accepted: [String: AIPageTranslatedItem] = [:]
        for rawItem in rawItems {
            guard let rawID = stringValue(rawItem, keys: ["id", "blockID", "block_id"]) else { continue }
            // 防御：模型可能返回带空格或大小写变体的 id，统一 trim + lowercase 后匹配
            let id = rawID
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard expectedByID[id] != nil,
                  accepted[id] == nil,
                  let translation = stringValue(rawItem, keys: ["translation", "translatedText", "translated_text"])?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  let sourceText = expectedByID[id]?.sourceText,
                  let normalizedTranslation = TranslationOutputValidator.normalizedAcceptableTranslation(
                    translation,
                    sourceText: sourceText,
                    target: target
                  ) else {
                continue
            }
            let rawLines = (rawItem["translationLines"] as? [String]
                ?? rawItem["translation_lines"] as? [String]
                ?? [])
            let lines = TranslationOutputValidator.validatedTranslationLines(
                rawLines,
                canonicalTranslation: normalizedTranslation,
                sourceText: sourceText,
                target: target
            )
            accepted[id] = AIPageTranslatedItem(
                id: id,
                translation: normalizedTranslation,
                translationLines: lines
            )
        }

        let orderedItems = expectedItems.compactMap { accepted[$0.id] }
        let missingIDs = expectedItems.filter { accepted[$0.id] == nil }.map(\.id)
        guard !orderedItems.isEmpty else { throw AIPageTranslationParserError.emptyResult }
        // 拉丁语言（英/法/德/西/意/葡/越/印尼）逐气泡只校验拉丁字母，
        // 整页再用 NLLanguageRecognizer 二次校验，避免法语/荷兰语结果被当成英语通过。
        if !TranslationOutputValidator.pageIsCompatible(
            orderedItems.map(\.translation),
            target: target
        ) {
            throw AIPageTranslationParserError.pageLanguageMismatch
        }
        return AIPageTranslationResult(items: orderedItems, missingIDs: missingIDs)
    }

    /// Strict parser used by the page transport. Unlike the legacy tolerant
    /// parser (kept for older settings/tests), this validates the exact object
    /// shape and exact requested IDs before any translation is applied.
    static func parseStrict(
        _ content: String,
        expectedItems: [AIPageTranslationItem],
        target: TranslationTargetLanguage
    ) throws -> AIPageTranslationResult {
        guard let data = normalizedJSONData(from: content),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              Set(dictionary.keys) == ["items"],
              let rawItems = dictionary["items"] as? [[String: Any]],
              rawItems.count == expectedItems.count else {
            throw AIPageTranslationParserError.invalidJSON
        }

        let expectedIDs = expectedItems.map(\.id)
        guard Set(expectedIDs).count == expectedIDs.count else {
            throw AIPageTranslationParserError.invalidJSON
        }
        let expectedByID = Dictionary(uniqueKeysWithValues: expectedItems.map { ($0.id, $0) })
        var accepted: [String: AIPageTranslatedItem] = [:]
        for rawItem in rawItems {
            guard Set(rawItem.keys) == ["id", "translation", "translationLines"],
                  let id = rawItem["id"] as? String,
                  expectedByID[id] != nil,
                  accepted[id] == nil,
                  let rawTranslation = rawItem["translation"] as? String,
                  let rawLines = rawItem["translationLines"] as? [String] else {
                throw AIPageTranslationParserError.invalidJSON
            }

            let translation = rawTranslation.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedTranslation: String
            if translation.isEmpty {
                normalizedTranslation = ""
            } else {
                guard let normalized = TranslationOutputValidator.normalizedAcceptableTranslation(
                    translation,
                    sourceText: expectedByID[id]?.sourceText,
                    target: target
                ) else {
                    throw AIPageTranslationParserError.pageLanguageMismatch
                }
                normalizedTranslation = normalized
            }
            let lines = TranslationOutputValidator.validatedTranslationLines(
                rawLines,
                canonicalTranslation: normalizedTranslation,
                sourceText: expectedByID[id]?.sourceText,
                target: target
            )
            accepted[id] = AIPageTranslatedItem(
                id: id,
                translation: normalizedTranslation,
                translationLines: lines
            )
        }

        guard Set(accepted.keys) == Set(expectedIDs) else {
            throw AIPageTranslationParserError.invalidJSON
        }
        let ordered = expectedItems.compactMap { accepted[$0.id] }
        let missing = ordered.filter { $0.translation.isEmpty }.map(\.id)
        let completedTranslations = ordered
            .map(\.translation)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !completedTranslations.isEmpty,
           !TranslationOutputValidator.pageIsCompatible(completedTranslations, target: target) {
            throw AIPageTranslationParserError.pageLanguageMismatch
        }
        return AIPageTranslationResult(items: ordered, missingIDs: missing)
    }

    private static func stringValue(_ object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String { return value }
        }
        return nil
    }

    private static func normalizedJSONData(from content: String) -> Data? {
        var payload = content
        for tag in ["think", "thinking", "analysis", "reasoning"] {
            payload = payload.replacingOccurrences(
                of: "<\(tag)(?:\\s[^>]*)?>[\\s\\S]*?</\(tag)>",
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        guard payload.range(
            of: #"</?(?:think|thinking|analysis|reasoning)(?:\s[^>]*)?>"#,
            options: [.regularExpression, .caseInsensitive]
        ) == nil else {
            return nil
        }
        payload = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if payload.hasPrefix("```") {
            payload = payload.replacingOccurrences(
                of: #"^```(?:json)?\s*|\s*```$"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        guard let start = payload.firstIndex(where: { $0 == "{" || $0 == "[" }) else {
            return nil
        }
        guard let end = balancedJSONEnd(in: payload, start: start) else {
            return nil
        }
        return String(payload[start...end]).data(using: .utf8)
    }

    /// Finds the end of the first balanced JSON object/array while respecting
    /// quoted strings and escapes. It never fabricates JSON from prose.
    private static func balancedJSONEnd(
        in payload: String,
        start: String.Index
    ) -> String.Index? {
        var stack: [Character] = []
        var inString = false
        var escaped = false
        var index = start
        while index < payload.endIndex {
            let character = payload[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                if character == "\"" {
                    inString = true
                } else if character == "{" || character == "[" {
                    stack.append(character)
                } else if character == "}" || character == "]" {
                    guard let last = stack.popLast(),
                          (last == "{" && character == "}")
                            || (last == "[" && character == "]") else {
                        return nil
                    }
                    if stack.isEmpty {
                        return index
                    }
                }
            }
            index = payload.index(after: index)
        }
        return nil
    }
}

nonisolated enum TranslationOutputValidator {
    /// 译文可与原文相同：缩写、产品名、型号等跨语言通常无需改写；但日文/中文整句原样
    /// 返回到另一目标语言仍应视为漏译。整页与逐气泡必须共用此规则。
    static func isAcceptableTranslation(
        _ translation: String,
        sourceText: String?,
        target: TranslationTargetLanguage
    ) -> Bool {
        normalizedAcceptableTranslation(
            translation,
            sourceText: sourceText,
            target: target
        ) != nil
    }

    /// 所有整页与逐气泡译文都经由同一入口：先规范化目标中文的字形，再判断是否是
    /// 合法译文。这样模型偶尔返回繁简混排时不会为了一个字重新请求，而明显的日/韩文
    /// 漏译仍会被拦下。
    static func normalizedAcceptableTranslation(
        _ translation: String,
        sourceText: String?,
        target: TranslationTargetLanguage
    ) -> String? {
        let value = normalize(
            translation.trimmingCharacters(in: .whitespacesAndNewlines),
            for: target
        )
        guard !value.isEmpty, !containsExplanatoryGarbage(value) else { return nil }

        let source = sourceText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !source.isEmpty,
           comparableForEcho(value, target: target) == comparableForEcho(source, target: target) {
            // 比较时忽略空白/标点并先做繁简规范化，拦住“只加句号”以及
            // 日文/繁体原文在目标中文中原样返回等漏译；短人名、产品名、型号
            // 等稳定 token 仍按既有规则放行。
            return isStableUntranslatedToken(value, target: target) ? value : nil
        }
        return isCompatible(value, target: target) ? value : nil
    }

    /// `translation` is the only canonical page result. Model-provided line
    /// breaks are retained only when every line is a valid target-language
    /// fragment and the whitespace-collapsed result is exactly equivalent to
    /// that canonical translation. Otherwise the caller must render the
    /// canonical translation without model-provided line breaks.
    static func validatedTranslationLines(
        _ rawLines: [String],
        canonicalTranslation: String,
        sourceText: String?,
        target: TranslationTargetLanguage
    ) -> [String] {
        let lines = rawLines.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !lines.isEmpty,
              lines.allSatisfy({ !$0.isEmpty }),
              !canonicalTranslation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              lines.allSatisfy({
                  normalizedAcceptableTranslation(
                      $0,
                      sourceText: nil,
                      target: target
                  ) != nil
              }),
              normalizedAcceptableTranslation(
                  lines.joined(),
                  sourceText: sourceText,
                  target: target
              ) != nil,
              comparableTranslation(lines.joined(), target: target)
                  == comparableTranslation(canonicalTranslation, target: target) else {
            return []
        }
        return lines.map { normalize($0, for: target) }
    }

    static func validatedDisplayTranslation(
        canonicalTranslation: String,
        translationLines: [String],
        sourceText: String?,
        target: TranslationTargetLanguage
    ) -> String {
        let canonical = canonicalTranslation.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = validatedTranslationLines(
            translationLines,
            canonicalTranslation: canonical,
            sourceText: sourceText,
            target: target
        )
        return lines.isEmpty ? canonical : lines.joined(separator: "\n")
    }

    private static func comparableTranslation(
        _ text: String,
        target: TranslationTargetLanguage
    ) -> String {
        normalize(text, for: target)
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
    }

    static func normalize(_ text: String, for target: TranslationTargetLanguage) -> String {
        switch target {
        case .simplifiedChinese:
            return text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? text
        case .traditionalChinese:
            return text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: true) ?? text
        default:
            return text
        }
    }

    static func containsExplanatoryGarbage(_ text: String) -> Bool {
        let protocolMarkers = [
            "system prompt", "user prompt", "analysis:", "reasoning:",
            "thinking:", "thought process:", "reasoning_content", "_output",
            "输出要求", "翻译过程",
            "<think", "</think>", "<thinking", "</thinking>", "<analysis", "</analysis>",
            "<reasoning", "</reasoning>"
        ]
        let lowercased = text.lowercased()
        guard !lowercased.contains("```") else { return true }
        if protocolMarkers.contains(where: { lowercased.contains($0.lowercased()) }) {
            return true
        }
        return text.range(
            of: #"^\s*(?:(?:answer|final answer|translation|translated text|译文|翻译(?:结果)?|以下是翻译(?:结果)?)\s*[:：]|(?:根据用户(?:要求|提示)|提示词(?:要求)?|作为(?:一个|一名).{0,20}(?:AI|人工智能)|我(?:不能|无法).{0,12}(?:协助|帮助|提供|完成).{0,12}(?:翻译|请求)))"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    /// 用于检测“原文原样返回”。它只忽略排版差异，不改变正常译文的实际内容；
    /// 先做目标中文繁简规范化，以免繁体原文在简体目标中通过字符串不相等绕过检查。
    private static func comparableForEcho(
        _ text: String,
        target: TranslationTargetLanguage
    ) -> String {
        normalize(text, for: target)
            .lowercased()
            .unicodeScalars
            .filter { scalar in
                !CharacterSet.whitespacesAndNewlines.contains(scalar)
                    && !CharacterSet.punctuationCharacters.contains(scalar)
                    && !CharacterSet.symbols.contains(scalar)
            }
            .map(String.init)
            .joined()
    }

    /// 只接受不含空白、由 ASCII 字母/数字及常见型号符号构成的短 token。
    /// 这样 NASA、OK、iPhone、RX-78 可以保留，中文/日文整句则不会借由“相同”绕过目标语言验证。
    private static func isStableUntranslatedToken(
        _ text: String,
        target: TranslationTargetLanguage
    ) -> Bool {
        guard (1...40).contains(text.unicodeScalars.count) else { return false }
        let isASCIIStableToken = text.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true
            case 0x2B, 0x2D, 0x2E, 0x2F, 0x3A, 0x5F, 0x23: return true // + - . / : _ #
            default: return false
            }
        }
        if isASCIIStableToken { return true }

        // 人名、地名等短纯汉字在日→中、繁简互转中通常无需改写；只对中文目标语言
        // 放行。韩文/日文目标把“大丈夫”“没有”原样返回通常是漏译，不能用此捷径。
        let counts = scriptCounts(in: text)
        let mayPreserveShortHan: Bool
        switch target {
        case .simplifiedChinese, .traditionalChinese:
            mayPreserveShortHan = true
        default:
            mayPreserveShortHan = false
        }
        return mayPreserveShortHan
            && text.unicodeScalars.count <= 3
            && counts.han == text.unicodeScalars.count
    }

    static func isCompatible(
        _ text: String,
        target: TranslationTargetLanguage
    ) -> Bool {
        let counts = scriptCounts(in: text)
        let meaningful = counts.latin + counts.han + counts.kana + counts.hangul
            + counts.cyrillic + counts.thai + counts.arabic

        switch target {
        case .simplifiedChinese, .traditionalChinese:
            // 脚本冲突与文本长度无关：はい、안녕 不能因为只有两字就被当作中文。
            return counts.han > 0 && counts.kana == 0 && counts.hangul == 0
        case .japanese:
            return counts.kana + counts.han > 0 && counts.hangul == 0
        case .korean:
            return counts.hangul > 0 && counts.kana == 0
        case .russian:
            guard meaningful >= 3 else { return true }
            return counts.cyrillic >= max(1, meaningful / 3)
        case .thai:
            guard meaningful >= 3 else { return true }
            return counts.thai >= max(1, meaningful / 3)
        case .arabic:
            guard meaningful >= 3 else { return true }
            return counts.arabic >= max(1, meaningful / 3)
        case .english, .french, .german, .spanish, .italian, .portuguese,
             .vietnamese, .indonesian:
            guard meaningful >= 3 else { return true }
            return counts.latin >= max(1, meaningful / 2)
        }
    }

    private static func scriptCounts(in text: String) -> (
        latin: Int, han: Int, kana: Int, hangul: Int,
        cyrillic: Int, thai: Int, arabic: Int
    ) {
        var result = (latin: 0, han: 0, kana: 0, hangul: 0, cyrillic: 0, thai: 0, arabic: 0)
        for scalar in text.unicodeScalars {
            let value = scalar.value
            switch value {
            case 0x0041...0x024F: result.latin += 1
            case 0x3040...0x30FF, 0x31F0...0x31FF: result.kana += 1
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: result.han += 1
            case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF: result.hangul += 1
            case 0x0400...0x052F: result.cyrillic += 1
            case 0x0E00...0x0E7F: result.thai += 1
            case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF: result.arabic += 1
            default: break
            }
        }
        return result
    }

    /// 对拉丁字母目标语言做整页语言二次校验：
    /// 仅凭“是否含拉丁字母”无法区分英语/法语/德语/荷兰语，逐气泡校验可能放过错误语言。
    /// 这里把整页译文聚合后用 NLLanguageRecognizer 判断，若确信是“另一种拉丁语言”，
    /// 则整页不兼容（交给调用方重试/兜底）。
    static func pageIsCompatible(
        _ translations: [String],
        target: TranslationTargetLanguage
    ) -> Bool {
        let latinTargets: Set<TranslationTargetLanguage> = [
            .english, .french, .german, .spanish, .italian,
            .portuguese, .vietnamese, .indonesian
        ]
        guard latinTargets.contains(target) else { return true }
        let joined = translations
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 文本太短时 NL 不可靠，保持原行为
        guard joined.unicodeScalars.count >= 12 else { return true }
        let targetLanguage = NLLanguage(rawValue: target.rawValue)
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(joined)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
            .sorted { $0.value > $1.value }
        guard let first = hypotheses.first else { return true }
        let second = hypotheses.dropFirst().first?.value ?? 0
        // 只有高置信、明显区分时才判定不兼容，避免误伤
        guard first.value >= 0.7, first.value - second >= 0.15 else { return true }
        return first.key == targetLanguage
    }
}
