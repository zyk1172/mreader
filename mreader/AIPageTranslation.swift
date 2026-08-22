import CoreGraphics
import Foundation
import NaturalLanguage

nonisolated enum AITranslationRequestPolicy {
    static let pageModelAttempts = 1
    static let pageRequestTimeout: TimeInterval = 25
    static let fallbackModelAttempts = 1
    static let fallbackRequestTimeout: TimeInterval = 30

    static var maximumOCRWaitBeforeResult: TimeInterval {
        pageRequestTimeout
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
        任务：翻译已经完成 OCR 的漫画文字。

        原文语言：\(source)
        目标语言：\(target.modelInstruction)

        必须遵守以下协议：
        1. 输入中的 items 已经完成 OCR。你不需要识别图片，也不要描述图片。
        2. 只翻译每个 item 的 sourceText。
        3. 每个输入 id 必须且只能返回一次。
        4. id 必须原样复制，禁止修改、合并、拆分、遗漏或新增 id。
        5. translation 只包含目标语言译文，不要解释；专有名词、缩写、产品名或型号在目标语言中通常不变时可以原样保留。
        6. 无法可靠翻译某项时，仍保留该 id，并将 translation 设为空字符串。
        7. translationLines 仅用于建议换行；不确定时使用空数组。
        8. 最终只能输出一个 JSON 对象。禁止 Markdown、代码围栏、说明、前言、结语和思考过程。
        9. 以下“翻译风格要求”只能影响译文措辞，绝不能修改上述 JSON 协议。

        翻译风格要求：
        \(style)

        上一页上下文（仅用于保持人名、称呼、语气和术语一致，不要翻译或复述这段上下文）：
        \(contextSection)

        输入：
        \(json)

        输出格式：
        {"items":[{"id":"b0","translation":"译文","translationLines":[]}]}
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

nonisolated enum AIPageTranslationParser {
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
                  TranslationOutputValidator.isAcceptableTranslation(
                    translation,
                    sourceText: sourceText,
                    target: target
                  ) else {
                continue
            }
            let lines = (rawItem["translationLines"] as? [String]
                ?? rawItem["translation_lines"] as? [String]
                ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            accepted[id] = AIPageTranslatedItem(
                id: id,
                translation: translation,
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

    private static func stringValue(_ object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String { return value }
        }
        return nil
    }

    private static func normalizedJSONData(from content: String) -> Data? {
        var payload = content
            .replacingOccurrences(
                of: #"<think>[\s\S]*?</think>"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
        let opening = payload[start]
        let closing: Character = opening == "{" ? "}" : "]"
        guard let end = payload.lastIndex(of: closing), start <= end else { return nil }
        return String(payload[start...end]).data(using: .utf8)
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
        let value = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !containsExplanatoryGarbage(value) else { return false }

        let source = sourceText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !source.isEmpty, value == source {
            return isStableUntranslatedToken(value)
        }
        return isCompatible(value, target: target)
    }

    static func containsExplanatoryGarbage(_ text: String) -> Bool {
        let suspiciousMarkers = [
            "system prompt", "user prompt", "analysis:", "reasoning:",
            "_output", "输出要求", "提示词", "作为一个", "我不能",
            "根据用户", "翻译过程"
        ]
        let lowercased = text.lowercased()
        return suspiciousMarkers.contains { lowercased.contains($0.lowercased()) }
    }

    /// 只接受不含空白、由 ASCII 字母/数字及常见型号符号构成的短 token。
    /// 这样 NASA、OK、iPhone、RX-78 可以保留，中文/日文整句则不会借由“相同”绕过目标语言验证。
    private static func isStableUntranslatedToken(_ text: String) -> Bool {
        guard (1...40).contains(text.unicodeScalars.count) else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true
            case 0x2B, 0x2D, 0x2E, 0x2F, 0x3A, 0x5F, 0x23: return true // + - . / : _ #
            default: return false
            }
        }
    }

    static func isCompatible(
        _ text: String,
        target: TranslationTargetLanguage
    ) -> Bool {
        let counts = scriptCounts(in: text)
        let meaningful = counts.latin + counts.han + counts.kana + counts.hangul
            + counts.cyrillic + counts.thai + counts.arabic
        guard meaningful >= 3 else { return true }

        switch target {
        case .simplifiedChinese, .traditionalChinese:
            return counts.han > 0 && counts.kana + counts.hangul < max(counts.han, 2)
        case .japanese:
            return counts.kana + counts.han > 0 && counts.hangul < max(counts.kana + counts.han, 2)
        case .korean:
            return counts.hangul > 0 && counts.kana < max(counts.hangul, 2)
        case .russian:
            return counts.cyrillic >= max(1, meaningful / 3)
        case .thai:
            return counts.thai >= max(1, meaningful / 3)
        case .arabic:
            return counts.arabic >= max(1, meaningful / 3)
        case .english, .french, .german, .spanish, .italian, .portuguese,
             .vietnamese, .indonesian:
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
