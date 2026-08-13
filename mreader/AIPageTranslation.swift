import CoreGraphics
import Foundation

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
            id: block.id.uuidString.lowercased(),
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
    static func prompt(
        items: [AIPageTranslationItem],
        target: TranslationTargetLanguage,
        additionalInstructions: String = ""
    ) throws -> String {
        let payload = ["items": items.map(\.jsonObject)]
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
        guard let json = String(data: data, encoding: .utf8) else {
            throw AIPageTranslationParserError.invalidJSON
        }
        let extra = additionalInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        你是漫画整页对白翻译器。把下列 items 翻译为 \(target.modelInstruction)。
        先通读整页，统一人名、称呼、人物关系、代词、术语、语气和情绪，再逐项返回。
        每个 id 表示已经确定的独立原始气泡：绝对不能合并不同 id，也不能拆分或改写 id。
        只翻译 sourceText，不描述画面，不续写、总结、评价或添加剧情。
        网址、广告、水印、版权和页码不应出现在输入；如仍出现，对应 translation 返回空字符串。
        译文必须使用 \(target.modelInstruction)，不得夹杂其他语言的解释；人名或必要专有名词除外。
        保留自然漫画口语、称呼、拟声词与情绪，不要逐字硬译。
        \(extra.isEmpty ? "" : "附加翻译要求：\n\(extra)")

        输入 JSON：
        \(json)

        只输出严格 JSON，不要 Markdown、说明或思考过程：
        {"items":[{"id":"原 id","translation":"译文","translationLines":["建议第一行","建议第二行"]}]}
        """
    }
}

nonisolated enum AIPageTranslationParserError: LocalizedError, Sendable {
    case invalidJSON
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .invalidJSON: return "整页翻译返回格式无效"
        case .emptyResult: return "整页翻译没有返回可用文本"
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
            guard let id = stringValue(rawItem, keys: ["id", "blockID", "block_id"]),
                  expectedByID[id] != nil,
                  accepted[id] == nil,
                  let translation = stringValue(rawItem, keys: ["translation", "translatedText", "translated_text"])?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !translation.isEmpty,
                  translation != expectedByID[id]?.sourceText,
                  TranslationOutputValidator.isCompatible(translation, target: target) else {
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
}
