import Foundation
import UIKit
import os

private enum VisionResponseFormatMode: String {
    case jsonSchema
    case jsonObject
    case promptOnly

    var fallback: Self? {
        switch self {
        case .jsonSchema: return .jsonObject
        case .jsonObject: return .promptOnly
        case .promptOnly: return nil
        }
    }
}

private final class VisionResponseFormatCache: @unchecked Sendable {
    static let shared = VisionResponseFormatCache()

    private let lock = NSLock()
    private var values: [String: VisionResponseFormatMode] = [:]

    func mode(for key: String, default defaultMode: VisionResponseFormatMode) -> VisionResponseFormatMode {
        lock.lock()
        defer { lock.unlock() }
        return values[key] ?? defaultMode
    }

    func set(_ mode: VisionResponseFormatMode, for key: String) {
        lock.lock()
        values[key] = mode
        lock.unlock()
    }
}

private enum PageResponseFormatMode: String {
    case jsonSchema
    case jsonObject
    case promptOnly

    var fallback: Self? {
        switch self {
        case .jsonSchema: return .jsonObject
        case .jsonObject: return .promptOnly
        case .promptOnly: return nil
        }
    }
}

private final class PageResponseFormatCache: @unchecked Sendable {
    static let shared = PageResponseFormatCache()

    private let lock = NSLock()
    private var values: [String: PageResponseFormatMode] = [:]

    func mode(for key: String, default defaultMode: PageResponseFormatMode) -> PageResponseFormatMode {
        lock.lock()
        defer { lock.unlock() }
        return values[key] ?? defaultMode
    }

    func set(_ mode: PageResponseFormatMode, for key: String) {
        lock.lock()
        values[key] = mode
        lock.unlock()
    }
}

nonisolated enum TextOrientation: String, Codable, Sendable {
    case horizontal
    case vertical

    static func inferred(from rect: CGRect) -> Self {
        rect.width >= rect.height ? .horizontal : .vertical
    }
}

nonisolated enum TranslationLayoutRole: String, Codable, Sendable {
    case dialogue
    case standalone

    static func fromClassification(_ classification: String) -> Self {
        let normalized = classification
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        switch normalized {
        case "narration", "soundeffect", "sfx", "label", "url",
             "advertisement", "advertising", "watermark", "copyright", "pagenumber":
            return .standalone
        default:
            return .dialogue
        }
    }

    static func inferred(
        ocrSource: String,
        bubbleBox: CGRect?,
        polygon: [CGPoint],
        textOrientation: TextOrientation
    ) -> Self {
        let sourceClassification = ocrSource
            .split(separator: ":")
            .last?
            .split(separator: "+", maxSplits: 1)
            .first
            .map(String.init) ?? ocrSource
        if fromClassification(sourceClassification) == .standalone {
            return .standalone
        }

        // A normal dialogue block may also lack a bubbleBox. Only treat a
        // polygon as standalone evidence when its long axis is visibly
        // rotated away from the expected horizontal/vertical text axis.
        guard bubbleBox == nil, polygon.count >= 4,
              polygonIndicatesRotation(polygon, textOrientation: textOrientation) else {
            return .dialogue
        }
        return .standalone
    }

    private static func polygonIndicatesRotation(
        _ polygon: [CGPoint],
        textOrientation: TextOrientation
    ) -> Bool {
        var longestLength: CGFloat = 0
        var longestAngle: CGFloat = 0
        for index in polygon.indices {
            let next = polygon[(index + 1) % polygon.count]
            let point = polygon[index]
            let vector = CGPoint(x: next.x - point.x, y: next.y - point.y)
            let length = hypot(vector.x, vector.y)
            guard length > longestLength else { continue }
            longestLength = length
            longestAngle = atan2(vector.y, vector.x)
        }
        guard longestLength > 0 else { return false }

        var axialAngle = longestAngle.truncatingRemainder(dividingBy: .pi)
        if axialAngle < 0 { axialAngle += .pi }
        let expectedAngle: CGFloat = textOrientation == .horizontal ? 0 : .pi / 2
        let difference = abs(axialAngle - expectedAngle)
        let distanceFromAxis = min(difference, .pi - difference)
        return distanceFromAxis >= .pi / 12
    }
}

// 定义识别出的文本块模型
struct TextBlock: Identifiable, Sendable {
    let id: UUID
    let text: String
    let boundingBox: CGRect // 原图中的相对坐标 (0.0 ~ 1.0)
    var translation: String?
    var confidence: Double
    var ocrSource: String
    var isFiltered: Bool
    var filterReason: String?
    var estimatedFontScale: Double
    var textColorHex: String?
    /// Physical bubble bounds when a real bubble was detected. This is not a layout expansion hint.
    var bubbleBox: CGRect?
    /// Independent region in which translated text may be laid out. It may exist even when no physical bubble exists.
    var layoutSafeRegion: CGRect?
    /// textPolygon；保留旧属性名以兼容既有 OCR 调用。
    var polygon: [CGPoint]
    var bubblePolygon: [CGPoint]
    var translationLines: [String]
    /// 组成当前 translation unit 的原文横排 line 数；竖排通常仍为一列。
    /// line/bubble 合并时必须显式传递，不能从最终 union 的高度反推。
    var sourceLineCount: Int
    /// 在最初 OCR observation 阶段确定的文字方向；合并成 line/bubble 后必须继承。
    var textOrientation: TextOrientation
    /// 布局语义不能从 bubbleBox 是否存在反推；纯 OCR 对白同样可能没有 bubbleBox。
    var layoutRole: TranslationLayoutRole

    var isStandaloneText: Bool {
        layoutRole == .standalone
    }

    nonisolated init(id: UUID = UUID(), text: String, boundingBox: CGRect, translation: String? = nil, confidence: Double = 0, ocrSource: String = "vision", isFiltered: Bool = false, filterReason: String? = nil, estimatedFontScale: Double? = nil, textColorHex: String? = nil, bubbleBox: CGRect? = nil, layoutSafeRegion: CGRect? = nil, polygon: [CGPoint] = [], bubblePolygon: [CGPoint] = [], translationLines: [String] = [], textOrientation: TextOrientation? = nil, layoutRole: TranslationLayoutRole? = nil, sourceLineCount: Int = 1) {
        self.id = id
        self.text = text
        self.boundingBox = boundingBox
        self.translation = translation
        self.confidence = confidence
        self.ocrSource = ocrSource
        self.isFiltered = isFiltered
        self.filterReason = filterReason
        // 横排行的字号≈行高，竖排列的字号≈列宽；取较小边比恒取高度更接近真实字号
        self.estimatedFontScale = estimatedFontScale ?? Double(min(boundingBox.width, boundingBox.height))
        self.textColorHex = textColorHex
        self.bubbleBox = bubbleBox
        self.layoutSafeRegion = layoutSafeRegion
        self.polygon = polygon
        self.bubblePolygon = bubblePolygon
        self.translationLines = translationLines
        self.sourceLineCount = max(sourceLineCount, 1)
        let resolvedOrientation = textOrientation ?? .inferred(from: boundingBox)
        self.textOrientation = resolvedOrientation
        self.layoutRole = layoutRole ?? .inferred(
            ocrSource: ocrSource,
            bubbleBox: bubbleBox,
            polygon: polygon,
            textOrientation: resolvedOrientation
        )
    }

    /// OCR 字号尺度始终取原文短边：横排文字对应 textBox 高度，竖排文字对应宽度。
    /// 显示时必须用同一坐标轴的页面尺寸还原，不能统一乘图片短边。
    nonisolated func sourceFontSize(in imageRect: CGRect) -> CGFloat {
        let reference = textOrientation == .horizontal ? imageRect.height : imageRect.width
        return CGFloat(estimatedFontScale) * max(reference, 1)
    }
}

nonisolated struct OCRVerificationRegion: Sendable {
    let blockID: UUID
    let sourceRect: CGRect
}

nonisolated struct VisionRegionTextCandidate: Equatable, Sendable {
    let text: String
    let confidence: Double
}

nonisolated enum AITranslationRequestError: LocalizedError, Sendable {
    case invalidConfiguration(String)
    case server(model: String, statusCode: Int?, message: String)
    case serverWithRetryAfter(model: String, statusCode: Int?, message: String, retryAfterSeconds: UInt64?)
    case invalidResponse(model: String)
    case invalidResponseEnvelope(model: String, contentType: String?, excerpt: String)
    case missingAssistantContent(model: String, finishReason: String?)
    case invalidTranslationJSON(model: String, excerpt: String)
    case invalidTranslationLanguage(model: String)
    case incompleteResponse(model: String, finishReason: String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            return message
        case .server(let model, let statusCode, let message):
            if let statusCode {
                return "模型 \(model) 请求失败：HTTP \(statusCode)，\(message)"
            }
            return "模型 \(model) 请求失败：\(message)"
        case .serverWithRetryAfter(let model, let statusCode, let message, _):
            if let statusCode {
                return "模型 \(model) 请求失败：HTTP \(statusCode)，\(message)"
            }
            return "模型 \(model) 请求失败：\(message)"
        case .invalidResponse(let model):
            return "模型 \(model) 返回了无法识别的响应"
        case .invalidResponseEnvelope(let model, let contentType, let excerpt):
            let type = contentType ?? "未知类型"
            return "模型 \(model) 返回了无法识别的响应包（\(type)）：\(excerpt)"
        case .missingAssistantContent(let model, let finishReason):
            if let finishReason {
                return "模型 \(model) 返回了推理内容但没有最终答案（finish_reason=\(finishReason)）"
            }
            return "模型 \(model) 没有返回最终回答内容"
        case .invalidTranslationJSON(let model, let excerpt):
            return "模型 \(model) 返回的翻译 JSON 无效：\(excerpt)"
        case .invalidTranslationLanguage(let model):
            return "模型 \(model) 返回的译文不符合目标语言"
        case .incompleteResponse(let model, let finishReason):
            return "模型 \(model) 响应不完整（finish_reason=\(finishReason)）"
        }
    }

    var statusCode: Int? {
        switch self {
        case .server(_, let statusCode, _),
             .serverWithRetryAfter(_, let statusCode, _, _):
            return statusCode
        default:
            return nil
        }
    }

    var retryAfterSeconds: UInt64? {
        if case let .serverWithRetryAfter(_, _, _, retryAfterSeconds) = self {
            return retryAfterSeconds
        }
        return nil
    }

    var isTranslationContentFailure: Bool {
        if case .invalidTranslationLanguage = self { return true }
        return false
    }

    /// 是否属于“格式/协议类”失败：可以触发缩小 batch 或逐气泡兜底。
    var isFormatFailure: Bool {
        switch self {
        case .invalidResponseEnvelope, .missingAssistantContent,
             .invalidTranslationJSON, .incompleteResponse:
            return true
        case .server(_, _, let message),
             .serverWithRetryAfter(_, _, let message, _):
            let normalized = message.lowercased()
            let mentionsFormat = normalized.contains("response_format")
                || normalized.contains("text.format")
                || normalized.contains("json_schema")
                || normalized.contains("json schema")
                || normalized.contains("structured output")
            let unsupported = normalized.contains("unsupported")
                || normalized.contains("not support")
                || normalized.contains("not allowed")
                || normalized.contains("unknown parameter")
                || normalized.contains("invalid parameter")
            return mentionsFormat && unsupported
        default: return false
        }
    }
}

/// 共享的 Chat Completions endpoint 解析（项6）：生产与设置页测试共用，
/// 兼容 `https://xxx/v1` 与已填写完整 `/chat/completions` 的 Base URL。
nonisolated enum AIEndpointResolver {
    static func endpointURL(for apiProtocol: AIAPIProtocol, from baseURL: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let endpoint = switch apiProtocol {
        case .openAIChatCompletions: "chat/completions"
        case .openAIResponses: "responses"
        case .anthropicMessages: "messages"
        }
        let knownSuffixes = ["/chat/completions", "/responses", "/messages"]
        var root = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        for suffix in knownSuffixes where root.hasSuffix(suffix) {
            root.removeLast(suffix.count)
            break
        }
        guard let url = URL(string: "\(root)/\(endpoint)"), url.scheme != nil, url.host != nil else {
            return nil
        }
        return url
    }

    static func chatCompletionsURL(from baseURL: String) -> URL? {
        endpointURL(for: .openAIChatCompletions, from: baseURL)
    }
}

/// 统一解析各家文本接口的响应包，支持：
/// - Chat Completions: choices[].message.content (String / typed array)
/// - legacy: choices[].text
/// - Responses: 顶层 output_text / output[].content[].text
/// - Anthropic Messages: content[].text
///
/// 不同 provider 都可能把 reasoning/thinking 放在同一个 content 数组中。只有
/// 明确的 text/output_text part 才能成为译文；未知类型不再通过“只要有 text
/// 字段”这个宽松 fallback 混入结果。只有 reasoning/thinking 而没有最终文本时，
/// `hasReasoningOnly` 才为 true，供上层决定是否重试。
nonisolated enum AIChatResponseDecoder {
    struct Decoded: Sendable {
        let content: String?
        let finishReason: String?
        let hasReasoningOnly: Bool
    }

    private struct ExtractedParts {
        let text: String?
        let hasReasoning: Bool
    }

    private static let finalPartTypes: Set<String> = ["text", "output_text"]
    private static let responseItemTextTypes: Set<String> = ["message", "text", "output_text"]

    static func decode(_ data: Data) -> Decoded {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Decoded(content: nil, finishReason: nil, hasReasoningOnly: false)
        }
        let topFinish = (json["finish_reason"] as? String)
            ?? (json["finishReason"] as? String)
            ?? (json["status"] as? String)

        // Responses 顶层 output_text 是 API 已经聚合好的最终文本，不把它和
        // output[].content 的 reasoning part 再次拼接；但兼容某些 provider 把
        // <think>...</think> 直接包在这个字符串里的情况。
        var topOutputHadReasoning = false
        if let outputText = nonEmptyString(json["output_text"]) {
            let cleaned = cleanedFinalText(outputText)
            topOutputHadReasoning = cleaned.removedReasoning
            if let text = cleaned.text {
                return Decoded(content: text, finishReason: topFinish, hasReasoningOnly: false)
            }
        }

        // Responses: output[].content[].text / output[].text。reasoning item 即使
        // 携带 text（或 summary text）也必须被跳过。
        if let output = json["output"] as? [[String: Any]] {
            var texts: [String] = []
            var hasReasoning = false
            for item in output {
                if isReasoningPart(item) {
                    hasReasoning = true
                    continue
                }
                if let type = normalizedType(item["type"]),
                   !responseItemTextTypes.contains(type) {
                    // Responses 的 function/tool/unknown item 不是译文。
                    continue
                }
                if let contentArray = item["content"] as? [[String: Any]] {
                    let extracted = extractTextParts(contentArray)
                    if let text = extracted.text { texts.append(text) }
                    hasReasoning = hasReasoning || extracted.hasReasoning
                } else if let rawText = nonEmptyString(item["text"]) {
                    let cleaned = cleanedFinalText(rawText)
                    if let text = cleaned.text {
                        texts.append(text)
                    }
                    hasReasoning = hasReasoning || cleaned.removedReasoning
                }
            }
            if !texts.isEmpty {
                return Decoded(
                    content: texts.joined(separator: "\n"),
                    finishReason: topFinish,
                    hasReasoningOnly: false
                )
            }
            if hasReasoning || topOutputHadReasoning {
                return Decoded(content: nil, finishReason: topFinish, hasReasoningOnly: true)
            }
        } else if topOutputHadReasoning {
            return Decoded(content: nil, finishReason: topFinish, hasReasoningOnly: true)
        }

        // Anthropic Messages: thinking/redacted_thinking 不是译文；只能读取 type=text。
        if let content = json["content"] as? [[String: Any]] {
            let extracted = extractTextParts(content)
            if let text = extracted.text {
                return Decoded(
                    content: text,
                    finishReason: (json["stop_reason"] as? String) ?? topFinish,
                    hasReasoningOnly: false
                )
            }
            if extracted.hasReasoning {
                return Decoded(
                    content: nil,
                    finishReason: (json["stop_reason"] as? String) ?? topFinish,
                    hasReasoningOnly: true
                )
            }
        }

        guard let choices = json["choices"] as? [[String: Any]], let choice = choices.first else {
            let topHasReasoning = isReasoningValue(json["reasoning_content"])
                || isReasoningValue(json["reasoning"])
                || isReasoningValue(json["thinking"])
            return Decoded(content: nil, finishReason: topFinish, hasReasoningOnly: topHasReasoning)
        }
        let finishReason = (choice["finish_reason"] as? String) ?? topFinish
        let choiceHasReasoning = isReasoningValue(choice["reasoning_content"])
            || isReasoningValue(choice["reasoning"])
            || isReasoningValue(choice["thinking"])

        if let rawText = nonEmptyString(choice["text"]) {
            let cleaned = cleanedFinalText(rawText)
            if let text = cleaned.text {
                return Decoded(content: text, finishReason: finishReason, hasReasoningOnly: false)
            }
            if cleaned.removedReasoning {
                return Decoded(content: nil, finishReason: finishReason, hasReasoningOnly: true)
            }
        }

        if let message = choice["message"] as? [String: Any] {
            var messageHadReasoning = false
            if let rawContent = nonEmptyString(message["content"]) {
                let cleaned = cleanedFinalText(rawContent)
                messageHadReasoning = cleaned.removedReasoning
                if let text = cleaned.text {
                    return Decoded(content: text, finishReason: finishReason, hasReasoningOnly: false)
                }
            }
            if let content = message["content"] as? [[String: Any]] {
                let extracted = extractTextParts(content)
                if let text = extracted.text {
                    return Decoded(content: text, finishReason: finishReason, hasReasoningOnly: false)
                }
                let hasReasoning = extracted.hasReasoning
                    || isReasoningValue(message["reasoning_content"])
                    || isReasoningValue(message["reasoning"])
                    || isReasoningValue(message["thinking"])
                    || messageHadReasoning
                    || choiceHasReasoning
                return Decoded(
                    content: nil,
                    finishReason: finishReason,
                    hasReasoningOnly: hasReasoning
                )
            }

            // 不再把任意 dictionary/array 序列化成“译文”。这会把 provider 的
            // reasoning/tool payload 原样交给翻译 parser，既污染结果也绕过类型过滤。
            let hasReasoning = isReasoningValue(message["reasoning_content"])
                || isReasoningValue(message["reasoning"])
                || isReasoningValue(message["thinking"])
                || messageHadReasoning
                || choiceHasReasoning
            if hasReasoning {
                return Decoded(content: nil, finishReason: finishReason, hasReasoningOnly: true)
            }
        }
        return Decoded(
            content: nil,
            finishReason: finishReason,
            hasReasoningOnly: choiceHasReasoning
        )
    }

    private static func extractTextParts(_ parts: [[String: Any]]) -> ExtractedParts {
        var texts: [String] = []
        var hasReasoning = false
        for part in parts {
            if isReasoningPart(part) {
                hasReasoning = true
                continue
            }
            if let type = normalizedType(part["type"]), !finalPartTypes.contains(type) {
                // 不接受 tool/function/unknown part，即使它恰好含有 text/content。
                continue
            }
            if let rawText = nonEmptyString(part["text"]) {
                let cleaned = cleanedFinalText(rawText)
                if let text = cleaned.text {
                    texts.append(text)
                }
                hasReasoning = hasReasoning || cleaned.removedReasoning
            } else if normalizedType(part["type"]) == nil,
                      let rawContent = nonEmptyString(part["content"]) {
                // 保留部分 OpenAI-compatible provider 的无 type 兼容形态，
                // 但只有无 type 才允许 content/value fallback。
                let cleaned = cleanedFinalText(rawContent)
                if let content = cleaned.text {
                    texts.append(content)
                }
                hasReasoning = hasReasoning || cleaned.removedReasoning
            } else if normalizedType(part["type"]) == nil,
                      let rawValue = nonEmptyString(part["value"]) {
                let cleaned = cleanedFinalText(rawValue)
                if let value = cleaned.text {
                    texts.append(value)
                }
                hasReasoning = hasReasoning || cleaned.removedReasoning
            }
        }
        return ExtractedParts(
            text: texts.isEmpty ? nil : texts.joined(separator: "\n"),
            hasReasoning: hasReasoning
        )
    }

    private static func isReasoningPart(_ part: [String: Any]) -> Bool {
        if let type = normalizedType(part["type"]), isReasoningType(type) {
            return true
        }
        return isReasoningValue(part["thinking"])
            || isReasoningValue(part["reasoning"])
            || isReasoningValue(part["reasoning_content"])
            || isReasoningValue(part["analysis"])
    }

    private static func isReasoningValue(_ value: Any?) -> Bool {
        guard let string = value as? String else { return false }
        return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isReasoningType(_ type: String) -> Bool {
        type.contains("reason")
            || type.contains("think")
            || type.contains("analysis")
            || type.contains("reflection")
            || type == "summary_text"
            || type == "redacted_thinking"
    }

    private static func normalizedType(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func cleanedFinalText(_ text: String) -> (text: String?, removedReasoning: Bool) {
        var cleaned = text
        var removedReasoning = false
        for tag in ["think", "thinking", "analysis", "reasoning"] {
            let pattern = "<\(tag)(?:\\s[^>]*)?>[\\s\\S]*?</\(tag)>"
            let stripped = cleaned.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            if stripped != cleaned {
                removedReasoning = true
                cleaned = stripped
            }
        }
        if cleaned.range(
            of: #"</?(?:think|thinking|analysis|reasoning)(?:\s[^>]*)?>"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            // Unclosed reasoning markup is not a safe final answer either.
            return (nil, true)
        }
        return (nonEmptyString(cleaned), removedReasoning)
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }
}

nonisolated struct AIVisionTranslationResult: Sendable {
    let blocks: [TextBlock]
    let failedSlices: Int
    let missingBlockIDs: [UUID]
    /// 跨切片拼接 / 原文被修正后**定向重译失败**的 block id。
    /// 这些 block 可能带着一半的临时译文，因此页面不能算完整。
    var retranslationFailedBlockIDs: [UUID] = []

    var isComplete: Bool {
        failedSlices == 0 && missingBlockIDs.isEmpty && retranslationFailedBlockIDs.isEmpty
    }
}

class AITranslator {
    nonisolated static func visualVerificationRegionsForDiagnostics(
        _ blocks: [TextBlock],
        confidenceThreshold: Double = 0.72,
        maximumCount: Int = 6
    ) -> [OCRVerificationRegion] {
        blocks
            .filter { block in
                block.isFiltered
                    || block.textOrientation == .vertical
                    || block.confidence < confidenceThreshold
                    || appearsGarbled(block.text)
            }
            .sorted { lhs, rhs in
                if lhs.isFiltered != rhs.isFiltered { return lhs.isFiltered }
                let lhsVertical = lhs.textOrientation == .vertical
                let rhsVertical = rhs.textOrientation == .vertical
                if lhsVertical != rhsVertical { return lhsVertical }
                if lhs.confidence != rhs.confidence { return lhs.confidence < rhs.confidence }
                return lhs.boundingBox.minY < rhs.boundingBox.minY
            }
            .prefix(max(maximumCount, 0))
            .map { block in
                // A vertical crop needs enough horizontal neighbourhood to see
                // sibling columns and the physical bubble instead of reviewing
                // one isolated column forever.
                let horizontalPadding = block.textOrientation == .vertical
                    ? max(block.boundingBox.width * 1.25, 0.04)
                    : max(block.boundingBox.width * 0.20, 0.010)
                let verticalPadding = block.textOrientation == .vertical
                    ? max(block.boundingBox.height * 0.20, 0.010)
                    : max(block.boundingBox.height * 0.20, 0.008)
                let padded = block.boundingBox.insetBy(
                    dx: -horizontalPadding,
                    dy: -verticalPadding
                )
                return OCRVerificationRegion(
                    blockID: block.id,
                    sourceRect: padded.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                )
            }
    }

    nonisolated private static func appearsGarbled(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if trimmed.contains("�") { return true }
        let usefulCount = trimmed.unicodeScalars.filter {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
        }.count
        let symbolCount = max(trimmed.unicodeScalars.count - usefulCount, 0)
        return symbolCount > max(3, trimmed.unicodeScalars.count / 2)
    }

    /// 新版“翻译风格要求”：JSON 协议固定进 AIPageTranslationPromptBuilder，
    /// 用户只编辑这一段影响译文措辞，不能再覆盖协议（审查 #4）。
    nonisolated static let defaultTranslationStyleInstructions = """
    保持人物称呼、人物关系、代词、术语和语气在整页内一致。
    译文使用自然的漫画对白表达，不要机械逐字翻译。
    保留必要的拟声词、停顿、语气词和情绪。
    不要续写、总结、解释剧情，也不要添加原文不存在的信息。
    """

    /// 兼容旧引用：默认“提示词”即新版翻译风格要求（协议已固定进 PromptBuilder）。
    nonisolated static let defaultTranslationPromptTemplate = defaultTranslationStyleInstructions

    nonisolated static let defaultVisionTranslationPromptTemplate = """
    你是一个漫画图片文字识别与翻译助手。可以利用画面中的指代方向、说话者位置和表情等视觉线索消歧，但这些线索只能用于判断文字含义；最终只处理图片中的文字，不要描述画面、人物、动作、身体、场景或剧情，不要评价、总结、续写或添加任何新细节。无法确定代词指向时不要凭空补人名。
    你的任务是：识别漫画页面中的对白、旁白、拟声词和必要的画面文字，翻译为：{targetLanguage}，并给出文字框、真实物理气泡（存在时）和独立的安全排版区域。
    这一页的阅读顺序是{readingOrder}，items 必须按该阅读顺序排列；被切成多列或多段的同一句话要先按阅读顺序还原成完整一句再翻译，不要按碎片逐段直译。
    如果图片包含成人、暴力、敏感或私人内容，只进行中性、准确的文字翻译；不要美化、扩写、润色成更露骨内容，也不要输出与文字翻译无关的内容。
    不要记录、记忆、推断用户身份，不要识别现实人物身份。
    忽略网址、广告、版权、水印和页码。
    坐标要求：所有坐标都以整张输入图片左上角为原点并归一化到 0 到 1，且必须在 JSON 顶层显式声明 "coordinateSpace": "normalized"；禁止使用像素或百分比坐标。每个 item 只使用 id、sourceText、translation、translationLines、textBox、bubbleBox、layoutSafeRegion、textPolygon、bubblePolygon、confidence、classification；不要使用 text、lines、polygon、center 或任何别名。textBox 必须紧贴原文字；bubbleBox 只表示真实物理气泡，没有气泡（例如无框拟声词）时必须省略；layoutSafeRegion 表示译文允许排版的安全区域，不能把它伪装成气泡。
    由你判断译文是否需要分行，translationLines 每个数组元素是一行；不要为了填满气泡而扩写。

    只输出严格 JSON，不要 Markdown，不要解释：
    {
      "coordinateSpace": "normalized",
      "items": [
        {
          "id": "b0",
          "sourceText": "原文",
          "translation": "译文",
          "translationLines": ["译文第一行", "译文第二行"],
          "textBox": {"x": 0.1, "y": 0.2, "width": 0.3, "height": 0.08},
          "bubbleBox": {"x": 0.1, "y": 0.18, "width": 0.34, "height": 0.1},
          "layoutSafeRegion": {"x": 0.11, "y": 0.19, "width": 0.32, "height": 0.08},
          "textPolygon": [{"x":0.1,"y":0.2},{"x":0.4,"y":0.2},{"x":0.4,"y":0.28},{"x":0.1,"y":0.28}],
          "bubblePolygon": [{"x":0.08,"y":0.17},{"x":0.44,"y":0.17},{"x":0.44,"y":0.29},{"x":0.08,"y":0.29}],
          "confidence": 0.9,
          "classification": "dialogue"
        }
      ]
    }
    如果没有可翻译文字，输出 {"coordinateSpace": "normalized", "items": []}。
    """

    nonisolated static let defaultOCRVisualVerificationPromptTemplate = """
    你正在复核一小块漫画文字区域。只识别裁剪图中的原文并提供精确文字框，不要描述画面、人物、动作或剧情。
    请纠正本地 OCR 的错字、漏字和断句，但不得补写图片中不存在的内容。网址、广告、版权、水印和页码返回空 items。
    同一个气泡被切成多段时按阅读顺序恢复为一句；字号、颜色或方向明显不同的内容必须分成不同 items。
    同时把识别出的文字翻译为：{targetLanguage}，仅用于验证响应结构。
    坐标以当前裁剪图左上角为原点，归一化到 0 到 1，并在 JSON 顶层显式声明 "coordinateSpace": "normalized"；禁止像素或百分比坐标。
    只返回 JSON：
    {"coordinateSpace":"normalized","items":[{"text":"原文","translation":"译文","textBox":{"x":0.1,"y":0.1,"width":0.5,"height":0.2},"confidence":0.9}]}
    """
    
    // 1. 使用 Apple 原生 Vision 框架进行 OCR 识别 (极低内存占用，全本地执行)
    static func recognizeText(in image: UIImage, isRightToLeft: Bool = false, minimumTextHeight: Double = 0.008) async throws -> [TextBlock] {
        try await OCRPreprocessor.recognizeText(
            in: image,
            options: OCRPreprocessor.Options(
                isRightToLeft: isRightToLeft,
                minimumTextHeight: minimumTextHeight,
                languages: ["zh-Hans", "zh-Hant", "ja-JP", "ko-KR", "en-US"]
            )
        )
    }

    // 2. 调用 OpenAI 兼容接口进行翻译
    static func translate(text: String, ocrMetadata: String = "", pageContext: String = "", apiKey: String, baseURL: String, model: String, targetLanguage: TranslationTargetLanguage = .simplifiedChinese, promptTemplate: String = defaultTranslationPromptTemplate, requestTimeout: TimeInterval = AITranslationRequestPolicy.bubbleRequestTimeout, modelDescriptor: AIModelDescriptor? = nil) async throws -> String {
        try Task.checkCancellation()
        return try await translateTextUsingModel(
            text: text,
            apiKey: apiKey,
            baseURL: baseURL,
            model: model,
            modelDescriptor: modelDescriptor ?? AIModelProtocolCatalog.descriptor(for: model),
            targetLanguage: targetLanguage,
            promptTemplate: promptTemplate,
            ocrMetadata: ocrMetadata,
            pageContext: pageContext,
            requestTimeout: requestTimeout
        )
    }

    static func translatePage(
        blocks: [TextBlock],
        apiKey: String,
        baseURL: String,
        model: String,
        target: TranslationTargetLanguage,
        promptTemplate: String = defaultTranslationPromptTemplate,
        sourceLanguage: TranslationSourceLanguage? = nil,
        previousContext: String = "",
        modelDescriptor: AIModelDescriptor? = nil,
        session: URLSession = .shared,
        requestObserver: (@Sendable (URLRequest) -> Void)? = nil
    ) async throws -> AIPageTranslationResult {
        let items = blocks.enumerated().map { AIPageTranslationItem(block: $0.element, order: $0.offset) }
        guard !items.isEmpty else {
            throw AIPageTranslationParserError.emptyResult
        }
        try Task.checkCancellation()
        return try await translatePageUsingModel(
            items: items,
            apiKey: apiKey,
            baseURL: baseURL,
            model: model,
            modelDescriptor: modelDescriptor ?? AIModelProtocolCatalog.descriptor(for: model),
            target: target,
            promptTemplate: promptTemplate,
            sourceLanguage: sourceLanguage,
            previousContext: previousContext,
            requestTimeout: AITranslationRequestPolicy.pageRequestTimeout(itemCount: items.count),
            session: session,
            requestObserver: requestObserver
        )
    }

    private static func translatePageUsingModel(
        items: [AIPageTranslationItem],
        apiKey: String,
        baseURL: String,
        model: String,
        modelDescriptor: AIModelDescriptor,
        target: TranslationTargetLanguage,
        promptTemplate: String,
        sourceLanguage: TranslationSourceLanguage?,
        previousContext: String,
        requestTimeout: TimeInterval,
        session: URLSession,
        requestObserver: (@Sendable (URLRequest) -> Void)?
    ) async throws -> AIPageTranslationResult {
        guard !apiKey.isEmpty else { throw AITranslationRequestError.invalidConfiguration("未配置 API Key") }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AITranslationRequestError.invalidConfiguration("未配置模型")
        }
        // V2：固定 JSON 协议在 PromptBuilder 内，用户模板只作为“翻译风格要求”传入，
        // 旧整页/逐气泡提示词不再被原样注入新协议（审查 #3/#4）。
        let prompt = try AIPageTranslationPromptBuilder.prompt(
            items: items,
            sourceLanguage: sourceLanguage,
            target: target,
            styleInstructions: promptTemplate,
            previousContext: previousContext
        )

        let client = AITranslationClient(
            apiKey: apiKey,
            baseURL: baseURL,
            session: session,
            requestObserver: requestObserver
        )
        let cacheKey = "\(baseURL)|\(modelDescriptor.apiProtocol.rawValue)|\(model)"
        var mode = modelDescriptor.apiProtocol == .anthropicMessages
            ? PageResponseFormatMode.promptOnly
            : PageResponseFormatCache.shared.mode(for: cacheKey, default: .jsonSchema)
        var semanticDowngradeUsed = false
        while true {
            try Task.checkCancellation()
            let data: Data
            do {
                data = try await client.send(
                    AITransportRequest(
                        model: modelDescriptor,
                        systemPrompt: AIPageTranslationPromptBuilder.strictSystemPrompt,
                        userPrompt: prompt,
                        responseFormat: pageResponseFormat(
                            mode: mode,
                            items: items,
                            apiProtocol: modelDescriptor.apiProtocol
                        ),
                        temperature: 0.15,
                        timeout: requestTimeout,
                        kind: .page
                    )
                )
            } catch {
                guard let fallback = mode.fallback,
                      isUnsupportedResponseFormat(error) else {
                    throw error
                }
                MReaderLog.aiPage.notice("page response_format fallback model=\(model, privacy: .public) from=\(mode.rawValue, privacy: .public) to=\(fallback.rawValue, privacy: .public)")
                mode = fallback
                PageResponseFormatCache.shared.set(mode, for: cacheKey)
                continue
            }

            let decoded = AIChatResponseDecoder.decode(data)
            let content = decoded.content?.trimmingCharacters(in: .whitespacesAndNewlines)
            let malformed = content
                ?? (String(data: data.prefix(12_000), encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>")
            guard let content, !content.isEmpty else {
                MReaderLog.aiPage.error("page translation invalid response model=\(model, privacy: .public) protocol=\(modelDescriptor.apiProtocol.rawValue, privacy: .public) kind=page classification=pureProse mode=\(mode.rawValue, privacy: .public) bytes=\(malformed.utf8.count, privacy: .public)")
                // 原始响应只在用户主动开启诊断日志后才记录。
                MReaderLog.content("page invalid response excerpt=\(malformed.replacingOccurrences(of: "\n", with: " ").prefix(300))", logger: MReaderLog.aiPage)
                if let fallback = mode.fallback, !semanticDowngradeUsed {
                    let previousMode = mode
                    semanticDowngradeUsed = true
                    mode = fallback
                    PageResponseFormatCache.shared.set(mode, for: cacheKey)
                    MReaderLog.aiPage.notice("page semantic response_format downgrade model=\(model, privacy: .public) from=\(previousMode.rawValue, privacy: .public) to=\(mode.rawValue, privacy: .public)")
                    continue
                }
                if decoded.hasReasoningOnly {
                    throw AITranslationRequestError.missingAssistantContent(
                        model: model,
                        finishReason: decoded.finishReason
                    )
                }
                throw AITranslationRequestError.invalidTranslationJSON(
                    model: model,
                    excerpt: String(malformed.prefix(300))
                )
            }

            do {
                let result = try AIPageTranslationParser.parseStrict(
                    content,
                    expectedItems: items,
                    target: target
                )
                PageResponseFormatCache.shared.set(mode, for: cacheKey)
                return result
            } catch AIPageTranslationParserError.pageLanguageMismatch {
                throw AITranslationRequestError.invalidTranslationLanguage(model: model)
            } catch {
                let classification = AIPageTranslationParser.classifyResponse(
                    content,
                    expectedItems: items
                )
                let excerpt = malformed.replacingOccurrences(of: "\n", with: " ").prefix(300)
                MReaderLog.aiPage.error("page translation invalid response model=\(model, privacy: .public) protocol=\(modelDescriptor.apiProtocol.rawValue, privacy: .public) kind=page mode=\(mode.rawValue, privacy: .public) classification=\(classification.rawValue, privacy: .public) bytes=\(excerpt.utf8.count, privacy: .public)")
                MReaderLog.content("page invalid response excerpt=\(excerpt)", logger: MReaderLog.aiPage)

                // A prose/reasoning response with HTTP 200 means the server
                // ignored the requested structured-output capability. Downgrade
                // once and cache the result for this baseURL/protocol/model;
                // it is not a reason to ask a repair model to translate prose.
                if classification == .pureProse,
                   let fallback = mode.fallback,
                   !semanticDowngradeUsed {
                    let previousMode = mode
                    semanticDowngradeUsed = true
                    mode = fallback
                    PageResponseFormatCache.shared.set(mode, for: cacheKey)
                    MReaderLog.aiPage.notice("page semantic response_format downgrade model=\(model, privacy: .public) from=\(previousMode.rawValue, privacy: .public) to=\(mode.rawValue, privacy: .public)")
                    continue
                }

                // Only JSON-shaped content is eligible for the single repair
                // request. Pure reasoning falls through to the bounded
                // per-bubble fallback at the coordinator.
                guard classification == .jsonLike else {
                    throw AITranslationRequestError.invalidTranslationJSON(
                        model: model,
                        excerpt: String(excerpt)
                    )
                }

                do {
                    let repairPrompt = try AIPageTranslationRepairPromptBuilder.prompt(
                        items: items,
                        malformedResponse: malformed,
                        target: target
                    )
                    let repairedData = try await client.send(
                        AITransportRequest(
                            model: modelDescriptor,
                            systemPrompt: AIPageTranslationRepairPromptBuilder.systemPrompt,
                            userPrompt: repairPrompt,
                            responseFormat: pageResponseFormat(
                                mode: mode,
                                items: items,
                                apiProtocol: modelDescriptor.apiProtocol
                            ),
                            temperature: 0,
                            timeout: AITranslationRequestPolicy.jsonRepairRequestTimeout,
                            kind: .jsonRepair
                        )
                    )
                    guard let repairedContent = AIChatResponseDecoder.decode(repairedData).content else {
                        throw AIPageTranslationParserError.invalidJSON
                    }
                    return try AIPageTranslationParser.parseStrict(
                        repairedContent,
                        expectedItems: items,
                        target: target
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    MReaderLog.aiPage.error("page translation JSON repair failed model=\(model, privacy: .public) protocol=\(modelDescriptor.apiProtocol.rawValue, privacy: .public) kind=jsonRepair reason=\(MReaderLog.describe(error), privacy: .public)")
                    throw AITranslationRequestError.invalidTranslationJSON(
                        model: model,
                        excerpt: String(excerpt)
                    )
                }
            }
        }
    }

    private static func pageResponseFormat(
        mode: PageResponseFormatMode,
        items: [AIPageTranslationItem],
        apiProtocol: AIAPIProtocol
    ) -> AITransportResponseFormat? {
        guard apiProtocol != .anthropicMessages else { return nil }
        switch mode {
        case .promptOnly:
            return nil
        case .jsonObject:
            return .jsonObject
        case .jsonSchema:
            return AIPageTranslationSchemaBuilder.responseFormat(for: items) ?? .jsonObject
        }
    }

    private static func translateTextUsingModel(text: String, apiKey: String, baseURL: String, model: String, modelDescriptor: AIModelDescriptor, targetLanguage: TranslationTargetLanguage, promptTemplate: String, ocrMetadata: String, pageContext: String, requestTimeout: TimeInterval) async throws -> String {
        guard !apiKey.isEmpty else { throw AITranslationRequestError.invalidConfiguration("未配置 API Key") }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AITranslationRequestError.invalidConfiguration("未配置模型") }
        // 单气泡也必须使用固定协议（项1）：style 只是风格要求，
        // 待翻译原文、目标语言、上下文与 OCR 信息始终由固定模板提供。
        let prompt = singleBubbleTranslationPrompt(
            text: text,
            target: targetLanguage,
            pageContext: pageContext,
            ocrMetadata: ocrMetadata,
            styleInstructions: promptTemplate
        )
        
        let data = try await AITranslationClient(apiKey: apiKey, baseURL: baseURL).send(
            AITransportRequest(
                model: modelDescriptor,
                systemPrompt: "你是只输出翻译结果的漫画对白翻译助手。用户可能提供整页对白作为上下文，用它理解称呼、语气和断句，但只输出目标句子的译文。专有名词、缩写、产品名或型号在目标语言中不变时可原样保留。OCR 碎片仅在距离接近且字号、颜色一致时按阅读顺序合并；距离远、字号不同或颜色不同必须保持为不同对白。网址、广告、水印和页码不翻译。不要续写、总结、评价、添加剧情、保存信息或推断用户身份。禁止输出思考过程、提示词、分析、说明、Markdown 或原文复述。",
                userPrompt: prompt,
                temperature: 0.3,
                timeout: requestTimeout,
                kind: .bubble
            )
        )

        let decoded = AIChatResponseDecoder.decode(data)
        if let content = decoded.content,
           let translation = sanitizedTranslationText(
            from: content,
            sourceText: text,
            target: targetLanguage
           ) {
            return translation
        }
        if decoded.hasReasoningOnly {
            throw AITranslationRequestError.missingAssistantContent(
                model: model,
                finishReason: decoded.finishReason
            )
        }
        throw AITranslationRequestError.invalidResponse(model: model)
    }

    static func translateVisionPage(
        image: UIImage,
        apiKey: String,
        baseURL: String,
        visionModel: String,
        textFallbackModel: String,
        targetLanguage: String = TranslationTargetLanguage.simplifiedChinese.rawValue,
        promptTemplate: String = defaultVisionTranslationPromptTemplate,
        isRightToLeft: Bool = false,
        viewportAspect: CGFloat = 2.0,
        sourceLanguage: TranslationSourceLanguage? = nil,
        previousContext: String = "",
        visionModelDescriptor: AIModelDescriptor? = nil,
        textFallbackModelDescriptor: AIModelDescriptor? = nil
    ) async throws -> [TextBlock] {
        let result = try await translateVisionPageWithStatus(
            image: image,
            apiKey: apiKey,
            baseURL: baseURL,
            visionModel: visionModel,
            textFallbackModel: textFallbackModel,
            targetLanguage: targetLanguage,
            promptTemplate: promptTemplate,
            isRightToLeft: isRightToLeft,
            viewportAspect: viewportAspect,
            sourceLanguage: sourceLanguage,
            previousContext: previousContext,
            visionModelDescriptor: visionModelDescriptor,
            textFallbackModelDescriptor: textFallbackModelDescriptor
        )
        return result.blocks
    }

    static func translateVisionPageWithStatus(
        image: UIImage,
        apiKey: String,
        baseURL: String,
        visionModel: String,
        textFallbackModel: String,
        targetLanguage: String = TranslationTargetLanguage.simplifiedChinese.rawValue,
        promptTemplate: String = defaultVisionTranslationPromptTemplate,
        isRightToLeft: Bool = false,
        viewportAspect: CGFloat = 2.0,
        sourceLanguage: TranslationSourceLanguage? = nil,
        previousContext: String = "",
        visionModelDescriptor: AIModelDescriptor? = nil,
        textFallbackModelDescriptor: AIModelDescriptor? = nil
    ) async throws -> AIVisionTranslationResult {
        let target = TranslationTargetLanguage.migrateLegacyValue(targetLanguage)
        let recognition = try await recognizeVisionPageUsingModelWithStats(
            image: image,
            apiKey: apiKey,
            baseURL: baseURL,
            model: visionModel,
            modelDescriptor: visionModelDescriptor ?? AIModelProtocolCatalog.descriptor(for: visionModel),
            isRightToLeft: isRightToLeft,
            viewportAspect: viewportAspect,
            additionalInstructions: "",
            translationTarget: target,
            translationPromptTemplate: TranslationContextBuilder.visionPrompt(
                basePrompt: promptTemplate,
                previousContext: previousContext
            ),
            strictTranslationGeometry: false,
            // 实时路径：长条页切片必须先拼回完整原文，再对拼接 / 被修正的 block 定向重译。
            mergeSliceObservations: true
        )
        let result = try await finalizeVisionRecognition(
            recognition,
            image: image,
            apiKey: apiKey,
            baseURL: baseURL,
            visionModel: visionModel,
            visionModelDescriptor: visionModelDescriptor ?? AIModelProtocolCatalog.descriptor(for: visionModel),
            textModel: textFallbackModel,
            textModelDescriptor: textFallbackModelDescriptor
                ?? AIModelProtocolCatalog.descriptor(for: textFallbackModel),
            target: target,
            sourceLanguage: sourceLanguage,
            previousContext: previousContext,
            isRightToLeft: isRightToLeft
        )
        let hasUsableTranslation = result.blocks.contains {
            !($0.translation ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard hasUsableTranslation else { throw VisionTranslationError.emptyResult }
        return result
    }

    static func recognizeVisionPage(
        image: UIImage,
        apiKey: String,
        baseURL: String,
        model: String,
        isRightToLeft: Bool = false,
        viewportAspect: CGFloat = 2.0,
        additionalInstructions: String = "",
        translationTarget: TranslationTargetLanguage? = nil,
        translationPromptTemplate: String = defaultVisionTranslationPromptTemplate,
        modelDescriptor: AIModelDescriptor? = nil
    ) async throws -> [TextBlock] {
        try Task.checkCancellation()
        return try await recognizeVisionPageUsingModel(
            image: image,
            apiKey: apiKey,
            baseURL: baseURL,
            model: model,
            modelDescriptor: modelDescriptor ?? AIModelProtocolCatalog.descriptor(for: model),
            isRightToLeft: isRightToLeft,
            viewportAspect: viewportAspect,
            additionalInstructions: additionalInstructions,
            translationTarget: translationTarget,
            translationPromptTemplate: translationPromptTemplate,
            strictTranslationGeometry: false
        )
    }

    /// 整本离线翻译专用入口：识别与翻译只走 Vision 模型，不进入整页 `translatePage` 兜底。
    /// 固定协议由 OfflineTranslationPromptBuilder 生成，用户自定义内容只作为风格说明。
    ///
    /// 与实时阅读共用同一条收尾链路（跨切片拼接 + 原文复核 + 定向重译）；
    /// `textModel` 只用于对"拼接 / 被修正的那几个 block"定向重译，不做整页兜底（审查 #2）。
    static func recognizeOfflineVisionPage(
        image: UIImage,
        apiKey: String,
        baseURL: String,
        visionModel: String,
        textModel: String,
        sourceLanguage: TranslationSourceLanguage,
        targetLanguage: TranslationTargetLanguage,
        styleInstructions: String,
        previousContext: String,
        isRightToLeft: Bool = false,
        viewportAspect: CGFloat = 2.0,
        modelDescriptor: AIModelDescriptor? = nil,
        textModelDescriptor: AIModelDescriptor? = nil
    ) async throws -> OfflineVisionPageResult {
        let prompt = OfflineTranslationPromptBuilder.make(
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            isRightToLeft: isRightToLeft,
            styleInstructions: styleInstructions,
            previousContext: previousContext
        )
        let recognition = try await recognizeVisionPageUsingModelWithStats(
            image: image,
            apiKey: apiKey,
            baseURL: baseURL,
            model: visionModel,
            modelDescriptor: modelDescriptor ?? AIModelProtocolCatalog.descriptor(for: visionModel),
            isRightToLeft: isRightToLeft,
            viewportAspect: viewportAspect,
            additionalInstructions: "",
            translationTarget: targetLanguage,
            translationPromptTemplate: prompt,
            strictTranslationGeometry: true,
            // 与实时阅读一致：长条页先拼回完整原文（审查 #2）。
            mergeSliceObservations: true
        )
        guard !recognition.blocks.isEmpty else { return .noText }

        let visionDescriptor = modelDescriptor ?? AIModelProtocolCatalog.descriptor(for: visionModel)
        let finalized = try await finalizeVisionRecognition(
            recognition,
            image: image,
            apiKey: apiKey,
            baseURL: baseURL,
            visionModel: visionModel,
            visionModelDescriptor: visionDescriptor,
            textModel: textModel,
            textModelDescriptor: textModelDescriptor
                ?? AIModelProtocolCatalog.descriptor(for: textModel),
            target: targetLanguage,
            // .automatic 表示"由 MReader 判断"，不能把 auto 当成具体源语言传给文本模型。
            sourceLanguage: sourceLanguage == .automatic ? nil : sourceLanguage,
            previousContext: previousContext,
            isRightToLeft: isRightToLeft
        )
        guard !finalized.blocks.isEmpty else { return .noText }
        // 拼接 / 复核后定向重译失败时，页面必须保持 .partial 以便重试，
        // 不能把一半的临时译文当成完整结果保存下来。
        let failedSlices = max(recognition.failedSlices, finalized.retranslationFailedBlockIDs.count)
        return failedSlices > 0
            ? .partial(finalized.blocks, failedSlices: failedSlices)
            : .translated(finalized.blocks)
    }

    private struct VisionPageRecognitionResult {
        let blocks: [TextBlock]
        let successfulSlices: Int
        let failedSlices: Int
        /// 跨切片拼接产生的 block：它们的译文只是临时兜底，必须定向重译。
        var retranslationRequiredBlockIDs: [UUID] = []
    }

    private static func recognizeVisionPageUsingModel(image: UIImage, apiKey: String, baseURL: String, model: String, modelDescriptor: AIModelDescriptor, isRightToLeft: Bool, viewportAspect: CGFloat, additionalInstructions: String, translationTarget: TranslationTargetLanguage?, translationPromptTemplate: String, strictTranslationGeometry: Bool) async throws -> [TextBlock] {
        try await recognizeVisionPageUsingModelWithStats(
            image: image,
            apiKey: apiKey,
            baseURL: baseURL,
            model: model,
            modelDescriptor: modelDescriptor,
            isRightToLeft: isRightToLeft,
            viewportAspect: viewportAspect,
            additionalInstructions: additionalInstructions,
            translationTarget: translationTarget,
            translationPromptTemplate: translationPromptTemplate,
            strictTranslationGeometry: strictTranslationGeometry
        ).blocks
    }

    private static func recognizeVisionPageUsingModelWithStats(image: UIImage, apiKey: String, baseURL: String, model: String, modelDescriptor: AIModelDescriptor, isRightToLeft: Bool, viewportAspect: CGFloat, additionalInstructions: String, translationTarget: TranslationTargetLanguage?, translationPromptTemplate: String, strictTranslationGeometry: Bool, mergeSliceObservations: Bool = false) async throws -> VisionPageRecognitionResult {
        if shouldSliceBeforeVision(image, viewportAspect: viewportAspect) {
            return try await recognizeVisionSlicesWithStats(
                image: image,
                apiKey: apiKey,
                baseURL: baseURL,
                model: model,
                modelDescriptor: modelDescriptor,
                isRightToLeft: isRightToLeft,
                viewportAspect: viewportAspect,
                additionalInstructions: additionalInstructions,
                translationTarget: translationTarget,
                translationPromptTemplate: translationPromptTemplate,
                strictTranslationGeometry: strictTranslationGeometry,
                mergeSliceObservations: mergeSliceObservations
            )
        }
        do {
            let blocks = try await recognizeVisionImage(
                image: image,
                sourceRect: CGRect(x: 0, y: 0, width: 1, height: 1),
                apiKey: apiKey,
                baseURL: baseURL,
                model: model,
                modelDescriptor: modelDescriptor,
                isRightToLeft: isRightToLeft,
                additionalInstructions: additionalInstructions,
                translationTarget: translationTarget,
                translationPromptTemplate: translationPromptTemplate,
                strictTranslationGeometry: strictTranslationGeometry
            )
            if blocks.isEmpty, strictTranslationGeometry {
                // strict parser 已确认顶层为合法的 { coordinateSpace: normalized, items: [] }。
                return VisionPageRecognitionResult(blocks: [], successfulSlices: 1, failedSlices: 0)
            }
            guard !blocks.isEmpty else { throw VisionTranslationError.emptyResult }
            return VisionPageRecognitionResult(
                blocks: sortedTextBlocks(blocks, isRightToLeft: isRightToLeft),
                successfulSlices: 1,
                failedSlices: 0
            )
        } catch {
            guard shouldFallbackToVisionSlices(after: error) else {
                throw error
            }
            let slices = visionSlices(from: image, viewportAspect: viewportAspect)
            guard slices.count > 1 else {
                throw error
            }
            MReaderLog.aiVision.notice("vision full-page recognition fallback reason=\(MReaderLog.describe(error), privacy: .public)")
            return try await recognizeVisionSlicesWithStats(
                image: image,
                apiKey: apiKey,
                baseURL: baseURL,
                model: model,
                modelDescriptor: modelDescriptor,
                isRightToLeft: isRightToLeft,
                viewportAspect: viewportAspect,
                additionalInstructions: additionalInstructions,
                translationTarget: translationTarget,
                translationPromptTemplate: translationPromptTemplate,
                strictTranslationGeometry: strictTranslationGeometry,
                mergeSliceObservations: mergeSliceObservations
            )
        }
    }

    private static func recognizeVisionSlicesWithStats(image: UIImage, apiKey: String, baseURL: String, model: String, modelDescriptor: AIModelDescriptor, isRightToLeft: Bool, viewportAspect: CGFloat, additionalInstructions: String, translationTarget: TranslationTargetLanguage?, translationPromptTemplate: String, strictTranslationGeometry: Bool, mergeSliceObservations: Bool = false) async throws -> VisionPageRecognitionResult {
        let slices = visionSlices(from: image, viewportAspect: viewportAspect)
        print("MReader vision recognition sliced image=\(Int(image.size.width))x\(Int(image.size.height)) slices=\(slices.count) model=\(model)")
        // 有限并发处理切片：2 路并发显著降低总耗时，同时避免并发过高触发限流。
        let maximumConcurrentSlices = 2
        var sliceBlocks: [Int: [TextBlock]] = [:]
        var lastError: Error?
        var successfulSlices = 0
        var failedSlices = 0
        try await withThrowingTaskGroup(of: (Int, Result<[TextBlock], Error>).self) { group in
            var nextIndex = 0

            func submit(_ index: Int) {
                let slice = slices[index]
                group.addTask {
                    do {
                        let blocks = try await recognizeVisionImage(
                            image: slice.image,
                            sourceRect: slice.sourceRect,
                            apiKey: apiKey,
                            baseURL: baseURL,
                            model: model,
                            modelDescriptor: modelDescriptor,
                            isRightToLeft: isRightToLeft,
                            additionalInstructions: additionalInstructions,
                            translationTarget: translationTarget,
                            translationPromptTemplate: translationPromptTemplate,
                            strictTranslationGeometry: strictTranslationGeometry
                        )
                        return (index, .success(blocks))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }

            for index in 0..<min(maximumConcurrentSlices, slices.count) {
                submit(index)
                nextIndex += 1
            }

            while let (index, result) = try await group.next() {
                if Task.isCancelled {
                    group.cancelAll()
                    throw CancellationError()
                }
                switch result {
                case .success(let blocks):
                    // 按切片下标归档：跨切片拼接必须知道每一块来自哪个切片。
                    sliceBlocks[index, default: []].append(contentsOf: blocks)
                    successfulSlices += 1
                case .failure(let error):
                    lastError = error
                    failedSlices += 1
                    MReaderLog.aiVision.error("vision slice recognition failed index=\(index, privacy: .public) model=\(model, privacy: .public) reason=\(MReaderLog.describe(error), privacy: .public)")
                }
                if nextIndex < slices.count {
                    submit(nextIndex)
                    nextIndex += 1
                }
            }
        }
        let orderedBlocks = sliceBlocks.keys.sorted().flatMap { sliceBlocks[$0] ?? [] }
        // 先跨切片拼回完整原文，再交给 OCRCandidateResolver 去重（审查 #2）。
        // 拼接产生的 block translation 为 nil，由调用方重新翻译完整原文。
        let mergedBlocks: [TextBlock]
        var retranslationRequired: [UUID] = []
        if mergeSliceObservations, slices.count > 1 {
            let observations = slices.enumerated().map { index, slice in
                VisionSliceObservation(
                    index: index,
                    sourceRect: slice.sourceRect,
                    blocks: sliceBlocks[index] ?? []
                )
            }
            let outcome = VisionSliceMerger.merge(observations: observations, isRightToLeft: isRightToLeft)
            if !outcome.retranslationRequiredBlockIDs.isEmpty {
                MReaderLog.aiVision.notice("vision slice merge joined blocks=\(outcome.retranslationRequiredBlockIDs.count, privacy: .public)")
            }
            mergedBlocks = outcome.blocks
            retranslationRequired = outcome.retranslationRequiredBlockIDs
        } else {
            mergedBlocks = orderedBlocks
        }
        let deduped = deduplicatedMangaTextBlocks(mergedBlocks, isRightToLeft: isRightToLeft)
        if deduped.isEmpty,
           strictTranslationGeometry,
           failedSlices == 0,
           successfulSlices == slices.count {
            // 所有分片都明确返回合法空 items，才可判定整页无文字。
            return VisionPageRecognitionResult(blocks: [], successfulSlices: successfulSlices, failedSlices: 0)
        }
        guard !deduped.isEmpty else {
            throw lastError ?? VisionTranslationError.emptyResult
        }
        // 去重后仍存在的拼接 block 才需要定向重译（被去重掉的候选无需再翻译）。
        let resolvedIDs = Set(deduped.map(\.id))
        return VisionPageRecognitionResult(
            blocks: sortedTextBlocks(deduped, isRightToLeft: isRightToLeft),
            successfulSlices: successfulSlices,
            failedSlices: failedSlices,
            retranslationRequiredBlockIDs: retranslationRequired.filter { resolvedIDs.contains($0) }
        )
    }

    /// Vision 收尾链路：**实时阅读与整本离线翻译共用**。
    ///
    /// 顺序：切片拼接（已在上游完成）→ 去重（已在上游完成）→ 补齐缺失 / 拼接产生的译文
    /// → 可疑 block 的 text-first 原文复核 → 对被修正的 block 定向重译。
    ///
    /// 抽成单一入口是为了避免"实时修好了、离线还是旧行为"这类分叉（审查 #2）。
    /// 注意：拼接产生的 block 自带一半的临时译文，所以这里**必须**按
    /// `retranslationRequiredBlockIDs` 定向重译，不能只靠"译文为空"来兜底。
    private static func finalizeVisionRecognition(
        _ recognition: VisionPageRecognitionResult,
        image: UIImage,
        apiKey: String,
        baseURL: String,
        visionModel: String,
        visionModelDescriptor: AIModelDescriptor,
        textModel: String,
        textModelDescriptor: AIModelDescriptor,
        target: TranslationTargetLanguage,
        sourceLanguage: TranslationSourceLanguage?,
        previousContext: String,
        isRightToLeft: Bool,
        performsSourceReview: Bool = true
    ) async throws -> AIVisionTranslationResult {
        try Task.checkCancellation()
        var blocks = recognition.blocks
        var retranslationFailed: [UUID] = []

        func pendingIDs() -> Set<UUID> {
            var ids = Set<UUID>()
            for block in blocks
            where (block.translation ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ids.insert(block.id)
            }
            return ids
        }

        // 1. 拼接产生的 block + 模型漏掉译文的 block，一次性定向重译。
        var firstPass = pendingIDs()
        firstPass.formUnion(recognition.retranslationRequiredBlockIDs)
        if !firstPass.isEmpty {
            retranslationFailed.append(contentsOf: try await translateVisionBlocks(
                ids: firstPass,
                blocks: &blocks,
                apiKey: apiKey,
                baseURL: baseURL,
                textModel: textModel,
                textModelDescriptor: textModelDescriptor,
                target: target,
                sourceLanguage: sourceLanguage,
                previousContext: previousContext
            ))
        }

        // 2. 文字真实性复核：只重新确认 sourceText。
        if performsSourceReview, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let review = try await reverifyVisionSourceText(
                image: image,
                blocks: blocks,
                apiKey: apiKey,
                baseURL: baseURL,
                model: visionModel,
                modelDescriptor: visionModelDescriptor,
                sourceLanguagePreference: sourceLanguage
            )
            if !review.correctedBlockIDs.isEmpty {
                blocks = review.blocks
                retranslationFailed.append(contentsOf: try await translateVisionBlocks(
                    ids: Set(review.correctedBlockIDs),
                    blocks: &blocks,
                    apiKey: apiKey,
                    baseURL: baseURL,
                    textModel: textModel,
                    textModelDescriptor: textModelDescriptor,
                    target: target,
                    sourceLanguage: sourceLanguage,
                    previousContext: previousContext
                ))
            }
        }

        let missingBlockIDs = blocks.compactMap { block -> UUID? in
            (block.translation ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? block.id
                : nil
        }
        return AIVisionTranslationResult(
            blocks: blocks,
            failedSlices: recognition.failedSlices,
            missingBlockIDs: missingBlockIDs,
            // 同一 block 可能先失败又被复核修正，去重避免重复计数。
            retranslationFailedBlockIDs: Array(Set(retranslationFailed)).sorted { $0.uuidString < $1.uuidString }
        )
    }

    /// 对指定 block 定向重译：只发这些文本的整页请求，不做整页兜底。
    /// 返回重译失败的 block id（调用方据此把页面标记为未完成，而不是伪装成功）。
    private static func translateVisionBlocks(
        ids: Set<UUID>,
        blocks: inout [TextBlock],
        apiKey: String,
        baseURL: String,
        textModel: String,
        textModelDescriptor: AIModelDescriptor,
        target: TranslationTargetLanguage,
        sourceLanguage: TranslationSourceLanguage?,
        previousContext: String
    ) async throws -> [UUID] {
        let indexes = blocks.indices.filter { ids.contains(blocks[$0].id) }
        guard !indexes.isEmpty else { return [] }
        let requested = indexes.map { blocks[$0] }
        do {
            let pageResult = try await translatePage(
                blocks: requested,
                apiKey: apiKey,
                baseURL: baseURL,
                model: textModel,
                target: target,
                promptTemplate: defaultTranslationPromptTemplate,
                sourceLanguage: sourceLanguage,
                previousContext: TranslationContextBuilder.promptContext(
                    previousContext: previousContext,
                    pageBlocks: blocks,
                    requestedIndexes: indexes
                ),
                modelDescriptor: textModelDescriptor
            )
            try Task.checkCancellation()
            var failed: [UUID] = []
            for (position, index) in indexes.enumerated() {
                guard let value = pageResult.translation(for: "b\(position)"),
                      !value.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    failed.append(blocks[index].id)
                    continue
                }
                blocks[index].translation = value.translation
                blocks[index].translationLines = value.translationLines
            }
            if !failed.isEmpty {
                MReaderLog.aiVision.notice("vision targeted retranslation incomplete blocks=\(failed.count, privacy: .public)/\(indexes.count, privacy: .public)")
            }
            return failed
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // 定向重译失败：保留既有（可能是临时）译文，但把这些 block 记为未完成，
            // 让页面进入重试而不是把一半的译文当成完整结果缓存下来。
            MReaderLog.aiVision.notice("vision targeted retranslation failed blocks=\(indexes.count, privacy: .public) reason=\(MReaderLog.describe(error), privacy: .public)")
            return indexes.map { blocks[$0].id }
        }
    }

    static func visualVerifyOCRRegions(
        image: UIImage,
        blocks: [TextBlock],
        apiKey: String,
        baseURL: String,
        model: String,
        isRightToLeft: Bool,
        modelDescriptor: AIModelDescriptor? = nil,
        sourceLanguagePreference: TranslationSourceLanguage? = nil,
        detectedLanguage: String? = nil,
        visualVerificationEnabled: Bool = true,
        coverageRecoveryRequested: Bool = false
    ) async throws -> [TextBlock] {
        guard visualVerificationEnabled,
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let cgImage = image.cgImage else {
            return blocks
        }
        let regions = visualVerificationRegionsForDiagnostics(blocks)

        var corrected = blocks
        let pagePixelBounds = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        for region in regions {
            try Task.checkCancellation()
            guard let originalIndex = corrected.firstIndex(where: { $0.id == region.blockID }) else {
                continue
            }
            let pixelRect = CGRect(
                x: region.sourceRect.minX * CGFloat(cgImage.width),
                y: region.sourceRect.minY * CGFloat(cgImage.height),
                width: region.sourceRect.width * CGFloat(cgImage.width),
                height: region.sourceRect.height * CGFloat(cgImage.height)
            ).integral.intersection(pagePixelBounds)
            guard pixelRect.width >= 8,
                  pixelRect.height >= 8,
                  let crop = cgImage.cropping(to: pixelRect) else {
                continue
            }

            do {
                let cropImage = UIImage(cgImage: crop, scale: 1, orientation: .up)
                let review = try await recognizeVisionRegionText(
                    image: cropImage,
                    apiKey: apiKey,
                    baseURL: baseURL,
                    model: model,
                    modelDescriptor: modelDescriptor ?? AIModelProtocolCatalog.descriptor(for: model)
                )
                let original = corrected[originalIndex]
                corrected[originalIndex] = visualReviewedBlock(original: original, review: review)
                print("MReader OCR visual text review corrected block=\(region.blockID) confidence=\(String(format: "%.2f", review.confidence))")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                MReaderLog.aiVision.notice("OCR visual review fallback block=\(region.blockID, privacy: .public) reason=\(MReaderLog.describe(error), privacy: .public)")
            }
        }

        // Existing verification is deliberately block-scoped and cannot see a
        // column that Vision omitted entirely.  When the merged local result
        // still looks like an under-covered Japanese vertical page, make one
        // page-level recognition request so the model can discover missing
        // text.  This branch is reached only from the explicit visual-review
        // setting and never recursively invokes visualVerifyOCRRegions.
        let effectiveSourceLanguage: TranslationSourceLanguage?
        if sourceLanguagePreference == .japanese
            || detectedLanguage?.lowercased().hasPrefix("ja") == true {
            effectiveSourceLanguage = .japanese
        } else {
            effectiveSourceLanguage = sourceLanguagePreference
        }
        let japanesePageRecoveryRequested = JapaneseVerticalOCRService.shouldRequestPageRecovery(
            in: image,
            existingBlocks: corrected.filter { !$0.isFiltered },
            isRightToLeft: isRightToLeft,
            sourceLanguagePreference: effectiveSourceLanguage
        )
        if japanesePageRecoveryRequested || coverageRecoveryRequested {
            do {
                let recovered = try await recognizeVisionImage(
                    image: image,
                    sourceRect: CGRect(x: 0, y: 0, width: 1, height: 1),
                    apiKey: apiKey,
                    baseURL: baseURL,
                    model: model,
                    modelDescriptor: modelDescriptor ?? AIModelProtocolCatalog.descriptor(for: model),
                    isRightToLeft: isRightToLeft,
                    additionalInstructions: japanesePageRecoveryRequested
                        ? "这是日文竖排页面的整页补漏。请识别页面中所有可读文字，包括本地 OCR 没有产生 block 的整列竖排文字；不要因为已有识别结果而省略任何文字。"
                        : "这是 OCR 覆盖补漏。请重新检查整页所有可读文字，特别关注被本地质量门排除的弱对比、小字号、英文或韩文横排区域；只返回图中真实存在的文字，不要根据上下文猜字。",
                    translationTarget: nil,
                    translationPromptTemplate: defaultVisionTranslationPromptTemplate,
                    strictTranslationGeometry: false
                )
                let marked = recovered.map { block in
                    TextBlock(
                        id: block.id,
                        text: block.text,
                        boundingBox: block.boundingBox,
                        translation: block.translation,
                        confidence: block.confidence,
                        ocrSource: "visual-page-recovery",
                        isFiltered: block.isFiltered,
                        filterReason: block.filterReason,
                        estimatedFontScale: block.estimatedFontScale,
                        textColorHex: block.textColorHex,
                        bubbleBox: block.bubbleBox,
                        layoutSafeRegion: block.layoutSafeRegion,
                        polygon: block.polygon,
                        bubblePolygon: block.bubblePolygon,
                        translationLines: block.translationLines,
                        textOrientation: block.textOrientation,
                        layoutRole: block.layoutRole,
                        sourceLineCount: block.sourceLineCount
                    )
                }
                corrected = mergeVisualPageRecoveryBlocks(
                    marked,
                    into: corrected,
                    isRightToLeft: isRightToLeft
                )
                print("MReader OCR visual page recovery blocks=\(marked.count)")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                MReaderLog.aiVision.notice("OCR visual page recovery fallback reason=\(MReaderLog.describe(error), privacy: .public)")
            }
        }
        return corrected
    }

    static func visualPageRecoveryShouldRunForDiagnostics(
        image: UIImage?,
        blocks: [TextBlock],
        isRightToLeft: Bool,
        sourceLanguagePreference: TranslationSourceLanguage?,
        visualVerificationEnabled: Bool
    ) -> Bool {
        guard visualVerificationEnabled else { return false }
        return JapaneseVerticalOCRService.shouldRequestPageRecovery(
            in: image,
            existingBlocks: blocks,
            isRightToLeft: isRightToLeft,
            sourceLanguagePreference: sourceLanguagePreference
        )
    }

    static func mergeVisualPageRecoveryBlocksForDiagnostics(
        _ recovered: [TextBlock],
        into local: [TextBlock],
        isRightToLeft: Bool
    ) -> [TextBlock] {
        mergeVisualPageRecoveryBlocks(recovered, into: local, isRightToLeft: isRightToLeft)
    }

    private static func mergeVisualPageRecoveryBlocks(
        _ recovered: [TextBlock],
        into local: [TextBlock],
        isRightToLeft: Bool
    ) -> [TextBlock] {
        var merged = local
        for candidate in recovered {
            let duplicateIndex = merged.firstIndex { existing in
                let overlap = visualVerificationIntersectionOverUnion(
                    existing.boundingBox,
                    candidate.boundingBox
                )
                let textSimilarity = visualVerificationTextSimilarity(
                    existing.text,
                    candidate.text
                )
                return overlap >= 0.35
                    || (textSimilarity >= 0.82 && overlap >= 0.08)
            }
            if let duplicateIndex {
                if merged[duplicateIndex].isFiltered
                    || candidate.confidence > merged[duplicateIndex].confidence {
                    merged[duplicateIndex] = candidate
                }
            } else {
                merged.append(candidate)
            }
        }
        return sortedTextBlocks(merged, isRightToLeft: isRightToLeft)
    }

    /// 裁剪图中的 Vision 坐标需要先映射回整页，再与原 OCR block 比较；不能仅凭置信度
    /// 把同一 crop 内相邻对白替换进来。
    static func visualVerificationMatch(
        for original: TextBlock,
        candidates: [TextBlock],
        sourceRect: CGRect
    ) -> (block: TextBlock, pageBoundingBox: CGRect)? {
        let matches = candidates.compactMap { candidate -> (block: TextBlock, pageBoundingBox: CGRect, textSimilarity: CGFloat, iou: CGFloat, proximity: CGFloat, score: CGFloat)? in
            let pageBoundingBox = OCRCoordinateMapper.normalizedPageRect(
                forSliceRect: candidate.boundingBox,
                sourceRect: sourceRect
            )
            guard pageBoundingBox.width > 0, pageBoundingBox.height > 0 else { return nil }
            let text = visualVerificationTextSimilarity(original.text, candidate.text)
            let overlap = visualVerificationIntersectionOverUnion(
                original.boundingBox,
                pageBoundingBox
            )
            let distance = hypot(
                original.boundingBox.midX - pageBoundingBox.midX,
                original.boundingBox.midY - pageBoundingBox.midY
            )
            let proximity = max(0, 1 - distance / 0.45)
            let confidence = min(max(CGFloat(candidate.confidence), 0), 1)
            let score = text * 0.45 + overlap * 0.25 + proximity * 0.20 + confidence * 0.10
            return (candidate, pageBoundingBox, text, overlap, proximity, score)
        }
        guard let best = matches.max(by: { $0.score < $1.score }) else { return nil }

        // “最高分”不等于“可信匹配”。视觉复核一旦采用候选，会同时覆盖文字框、字号、方向和
        // bubbleBox；因此至少要有文字证据，或同时具备足够强的几何重叠和位置证据。
        let hasTextEvidence = best.textSimilarity >= 0.35
        let hasGeometryEvidence = best.iou >= 0.18 && best.proximity >= 0.65
        guard best.score >= 0.42, hasTextEvidence || hasGeometryEvidence else {
            return nil
        }
        return (best.block, best.pageBoundingBox)
    }

    /// Vision 的 estimatedFontScale 相对于 crop 归一化。映射回整页时必须沿文字方向
    /// 乘 crop 对应轴，避免 Reader 再乘整页尺寸后将字体放大数倍。
    static func visualVerificationMappedFontScale(
        for candidate: TextBlock,
        sourceRect: CGRect,
        correctedBox: CGRect
    ) -> Double {
        let cropAxis = candidate.textOrientation == .horizontal
            ? Double(sourceRect.height)
            : Double(sourceRect.width)
        let mapped = candidate.estimatedFontScale * cropAxis
        guard mapped.isFinite, mapped > 0 else {
            return candidate.textOrientation == .horizontal
                ? Double(correctedBox.height)
                : Double(correctedBox.width)
        }
        return mapped
    }

    /// 视觉复核请求的坐标相对于局部 crop。只有模型给出的 bubbleBox 能够合理容纳已经
    /// 映射回整页的 textBox 时，才把它作为真实气泡边界保存；纯本地 OCR 则仍保持 nil，
    /// 由 Reader 的有限 fallbackBounds 处理。
    static func visualVerificationMappedBubbleGeometry(
        for candidate: TextBlock,
        sourceRect: CGRect,
        correctedBox: CGRect
    ) -> (bubbleBox: CGRect?, bubblePolygon: [CGPoint]) {
        guard let localBubbleBox = candidate.bubbleBox else {
            return (nil, [])
        }
        let mappedBubbleBox = OCRCoordinateMapper.normalizedPageRect(
            forSliceRect: localBubbleBox,
            sourceRect: sourceRect
        )
        let toleranceX = max(0.004, correctedBox.width * 0.10)
        let toleranceY = max(0.004, correctedBox.height * 0.10)
        guard isUsableVisionRect(mappedBubbleBox),
              mappedBubbleBox.width >= correctedBox.width * 0.8,
              mappedBubbleBox.height >= correctedBox.height * 0.8,
              mappedBubbleBox.insetBy(dx: -toleranceX, dy: -toleranceY).contains(correctedBox) else {
            return (nil, [])
        }
        let mappedBubblePolygon = candidate.bubblePolygon.compactMap { point -> CGPoint? in
            guard point.x.isFinite, point.y.isFinite,
                  (0...1).contains(point.x), (0...1).contains(point.y) else {
                return nil
            }
            return CGPoint(
                x: sourceRect.minX + point.x * sourceRect.width,
                y: sourceRect.minY + point.y * sourceRect.height
            )
        }
        return (mappedBubbleBox, mappedBubblePolygon)
    }

    private static func visualVerificationIntersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        let union = lhs.width * lhs.height + rhs.width * rhs.height - intersection.width * intersection.height
        return union > 0 ? intersection.width * intersection.height / union : 0
    }

    private static func visualVerificationTextSimilarity(_ lhs: String, _ rhs: String) -> CGFloat {
        let left = lhs.components(separatedBy: .whitespacesAndNewlines).joined().lowercased()
        let right = rhs.components(separatedBy: .whitespacesAndNewlines).joined().lowercased()
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        if left == right { return 1 }
        if left.contains(right) || right.contains(left) {
            return CGFloat(min(left.count, right.count)) / CGFloat(max(left.count, right.count))
        }
        let leftScalars = Array(left.unicodeScalars)
        let rightScalars = Array(right.unicodeScalars)
        var previous = Array(repeating: 0, count: rightScalars.count + 1)
        for leftScalar in leftScalars {
            var current = Array(repeating: 0, count: rightScalars.count + 1)
            for (index, rightScalar) in rightScalars.enumerated() {
                current[index + 1] = leftScalar == rightScalar
                    ? previous[index] + 1
                    : max(previous[index + 1], current[index])
            }
            previous = current
        }
        return CGFloat(previous.last ?? 0) / CGFloat(max(leftScalars.count, rightScalars.count))
    }

    private static func recognizeVisionRegionText(
    image: UIImage,
    apiKey: String,
    baseURL: String,
    model: String,
    modelDescriptor: AIModelDescriptor
) async throws -> VisionRegionTextCandidate {
    guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw VisionTranslationError.api("未配置 API Key")
    }
    guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw VisionTranslationError.api("未配置模型")
    }
    let prepared = resizedImageForVision(image, maxDimension: 1536)
    guard let imageDataURL = encodedVisionImageDataURL(prepared) else {
        throw VisionTranslationError.imageEncodingFailed
    }
    let systemPrompt = "你只做漫画局部图片的原文转录。不要翻译，不要返回坐标，不要描述画面，不要输出思考过程。只返回 sourceText 和 confidence。"
    let prompt = """
    这是已经由本地 OCR 定位好的单个漫画文字区域裁剪。
    只逐字抄录图片内实际可见的原文，不猜裁剪外内容，不翻译，不补剧情。
    保留标点、数字、拉长音、小假名和大小写；竖排按自然阅读顺序合并为一个字符串。
    不需要任何坐标。
    只输出 JSON：{"sourceText":"图中原文","confidence":0.95}
    若确实没有可读文字，输出 {"sourceText":"","confidence":0.0}。
    """

    let data: Data
    do {
        data = try await visionCompletionData(
            apiKey: apiKey,
            baseURL: baseURL,
            model: model,
            modelDescriptor: modelDescriptor,
            systemPrompt: systemPrompt,
            prompt: prompt,
            imageDataURL: imageDataURL,
            responseFormat: .jsonObject
        )
    } catch {
        guard isUnsupportedResponseFormat(error) else { throw error }
        data = try await visionCompletionData(
            apiKey: apiKey,
            baseURL: baseURL,
            model: model,
            modelDescriptor: modelDescriptor,
            systemPrompt: systemPrompt,
            prompt: prompt,
            imageDataURL: imageDataURL,
            responseFormat: nil
        )
    }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let content = assistantContent(from: json),
          let result = parseVisionRegionTextCandidate(from: content) else {
        throw VisionTranslationError.emptyResult
    }
    return result
}

private static func parseVisionRegionTextCandidate(from content: String) -> VisionRegionTextCandidate? {
    if let data = normalizedVisionJSONData(from: content),
       let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
        var item: [String: Any]?
        if let dictionary = object as? [String: Any] {
            let direct = firstString(in: dictionary, keys: ["sourceText", "source_text", "text", "original", "originalText"])
            item = direct.isEmpty ? (dictionary["items"] as? [[String: Any]])?.first : dictionary
        } else if let array = object as? [[String: Any]] {
            item = array.first
        }
        guard let item else { return nil }
        let value = firstString(in: item, keys: ["sourceText", "source_text", "text", "original", "originalText"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !looksLikeVisionRefusal(value) else { return nil }
        return VisionRegionTextCandidate(
            text: value,
            confidence: min(max(doubleValue(from: item["confidence"]) ?? 0.75, 0), 1)
        )
    }
    var plain = content.trimmingCharacters(in: .whitespacesAndNewlines)
    if plain.hasPrefix("```") {
        plain = plain.replacingOccurrences(of: #"^```(?:text|markdown)?\s*|\s*```$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !plain.isEmpty, !looksLikeVisionRefusal(plain) else { return nil }
    return VisionRegionTextCandidate(text: plain, confidence: 0.6)
}

private static func looksLikeVisionRefusal(_ text: String) -> Bool {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard value.count <= 240 else { return false }
    let markers = [
        "无法识别", "无法读取", "无法返回", "不能识别", "不能读取",
        "未检测到文字", "没有检测到文字", "未发现文字", "没有可读文字",
        "抱歉，我无法", "看不到图片", "无法查看图片",
        "unable to read", "unable to identify", "cannot read", "can't read",
        "cannot view", "can't view", "no readable text", "no text found"
    ]
    return markers.contains { value.contains($0) }
}

private static func visualReviewedBlock(original: TextBlock, review: VisionRegionTextCandidate) -> TextBlock {
    TextBlock(
        id: original.id,
        text: review.text.trimmingCharacters(in: .whitespacesAndNewlines),
        boundingBox: original.boundingBox,
        translation: original.translation,
        confidence: max(original.confidence, review.confidence),
        ocrSource: "visual-review-text",
        isFiltered: false,
        filterReason: nil,
        estimatedFontScale: original.estimatedFontScale,
        textColorHex: original.textColorHex,
        bubbleBox: original.bubbleBox,
        layoutSafeRegion: original.layoutSafeRegion,
        polygon: original.polygon,
        bubblePolygon: original.bubblePolygon,
        translationLines: original.translationLines,
        textOrientation: original.textOrientation,
        layoutRole: original.layoutRole,
        sourceLineCount: original.sourceLineCount
    )
}

static func parseVisionRegionTextCandidateForDiagnostics(from content: String) -> VisionRegionTextCandidate? {
    parseVisionRegionTextCandidate(from: content)
}

static func visualReviewedBlockForDiagnostics(original: TextBlock, review: VisionRegionTextCandidate) -> TextBlock {
    visualReviewedBlock(original: original, review: review)
}

    // MARK: - Vision 原文真实性复核（审查 #3）
    //
    // 完整 Vision 模式下 sourceText / translation / textBox 出自同一个模型，
    // 没有任何独立证据源确认“模型的文字就是框里的文字”。这里只对最可疑的一小部分
    // block 裁剪局部图片做一次 text-first 复核：只重新确认 sourceText，被修正的
    // block 由调用方单独重译。绝不是每页再跑一次整页 OCR。

    /// 需要复核的可疑 block 及其局部裁剪区域（整页归一化坐标）。
    nonisolated struct VisionSourceReviewRegion: Sendable, Equatable {
        let blockID: UUID
        let sourceRect: CGRect
        let reason: String
    }

    nonisolated struct VisionSourceReviewResult: Sendable {
        /// 复核后的 block 集合（顺序与 id 保持不变）。
        let blocks: [TextBlock]
        /// 原文被修正的 block id。其 `translation` 已被清空，必须重新翻译。
        let correctedBlockIDs: [UUID]
        /// 实际成功完成复核的 block id。
        let reviewedBlockIDs: [UUID]
    }

    /// 可疑判据的阈值。集中定义，便于测试直接引用。
    nonisolated enum VisionSourceReviewPolicy {
        static let confidenceThreshold: Double = 0.75
        static let maximumRegionCount = 6
        /// 相邻 block 交叠面积 / 较小 block 面积 超过此值即视为“可能看错行/看错气泡”。
        static let neighborOverlapRatio: CGFloat = 0.55
        static let extremeAspectRatio: CGFloat = 12
        static let minimumNormalizedArea: CGFloat = 0.000_05
    }

    static func visionSourceReviewRegionsForDiagnostics(
        _ blocks: [TextBlock],
        sourceLanguagePreference: TranslationSourceLanguage? = nil,
        confidenceThreshold: Double = VisionSourceReviewPolicy.confidenceThreshold,
        maximumCount: Int = VisionSourceReviewPolicy.maximumRegionCount
    ) -> [VisionSourceReviewRegion] {
        visionSourceReviewRegions(
            blocks,
            sourceLanguagePreference: sourceLanguagePreference,
            confidenceThreshold: confidenceThreshold,
            maximumCount: maximumCount
        )
    }

    private static func visionSourceReviewRegions(
        _ blocks: [TextBlock],
        sourceLanguagePreference: TranslationSourceLanguage?,
        confidenceThreshold: Double,
        maximumCount: Int
    ) -> [VisionSourceReviewRegion] {
        let visible = blocks.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !visible.isEmpty, maximumCount > 0 else { return [] }

        // 相邻 block 大面积重叠：两侧都可能错行/错气泡，必须一起进复核。
        var overlappedIDs = Set<UUID>()
        for outer in visible.indices {
            for inner in visible.indices where inner > outer {
                let intersection = visible[outer].boundingBox.intersection(visible[inner].boundingBox)
                guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { continue }
                let intersectionArea = intersection.width * intersection.height
                let smallerArea = min(
                    area(visible[outer].boundingBox),
                    area(visible[inner].boundingBox)
                )
                guard smallerArea > 0,
                      intersectionArea / smallerArea >= VisionSourceReviewPolicy.neighborOverlapRatio else {
                    continue
                }
                overlappedIDs.insert(visible[outer].id)
                overlappedIDs.insert(visible[inner].id)
            }
        }

        struct Suspicion {
            let id: UUID
            let reason: String
            let priority: Int
            let confidence: Double
            let minY: CGFloat
        }

        var suspicions: [Suspicion] = []
        for block in visible {
            let reason: String
            let priority: Int
            if overlappedIDs.contains(block.id) {
                reason = "overlap"; priority = 0
            } else if block.confidence < confidenceThreshold {
                reason = "low-confidence"; priority = 1
            } else if isAnomalousVisionGeometry(block.boundingBox) {
                reason = "geometry"; priority = 2
            } else if appearsGarbled(block.text) {
                reason = "garbled"; priority = 3
            } else if visionSourceLanguageConflicts(block.text, preference: sourceLanguagePreference) {
                reason = "language"; priority = 4
            } else if block.ocrSource.contains("slice-merge") {
                // 跨切片拼接的结果本身缺少独立证据，优先复核。
                reason = "slice-overlap"; priority = 5
            } else {
                continue
            }
            suspicions.append(Suspicion(
                id: block.id,
                reason: reason,
                priority: priority,
                confidence: block.confidence,
                minY: block.boundingBox.minY
            ))
        }

        suspicions.sort { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            if lhs.confidence != rhs.confidence { return lhs.confidence < rhs.confidence }
            if lhs.minY != rhs.minY { return lhs.minY < rhs.minY }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        return suspicions.prefix(maximumCount).compactMap { suspicion in
            guard let block = visible.first(where: { $0.id == suspicion.id }) else { return nil }
            // 竖排裁剪需要看到相邻列，否则永远只复核孤立的一列。
            let paddingX = block.textOrientation == .vertical
                ? max(block.boundingBox.width * 1.25, 0.04)
                : max(block.boundingBox.width * 0.20, 0.010)
            let paddingY = max(block.boundingBox.height * 0.20, 0.008)
            let padded = block.boundingBox
                .insetBy(dx: -paddingX, dy: -paddingY)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard padded.width > 0, padded.height > 0 else { return nil }
            return VisionSourceReviewRegion(
                blockID: suspicion.id,
                sourceRect: padded,
                reason: suspicion.reason
            )
        }
    }

    /// 只重新确认 sourceText 的局部复核。返回被修正原文的 block（translation 已清空）。
    static func reverifyVisionSourceText(
        image: UIImage,
        blocks: [TextBlock],
        apiKey: String,
        baseURL: String,
        model: String,
        modelDescriptor: AIModelDescriptor? = nil,
        sourceLanguagePreference: TranslationSourceLanguage? = nil,
        maximumRegionCount: Int = VisionSourceReviewPolicy.maximumRegionCount
    ) async throws -> VisionSourceReviewResult {
        let regions = visionSourceReviewRegions(
            blocks,
            sourceLanguagePreference: sourceLanguagePreference,
            confidenceThreshold: VisionSourceReviewPolicy.confidenceThreshold,
            maximumCount: maximumRegionCount
        )
        guard !regions.isEmpty else {
            return VisionSourceReviewResult(blocks: blocks, correctedBlockIDs: [], reviewedBlockIDs: [])
        }
        guard let cgImage = image.cgImage else {
            return VisionSourceReviewResult(blocks: blocks, correctedBlockIDs: [], reviewedBlockIDs: [])
        }

        let descriptor = modelDescriptor ?? AIModelProtocolCatalog.descriptor(for: model)
        let pagePixelBounds = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        var reviewedBlocks = blocks
        var correctedIDs: [UUID] = []
        var completedReviewIDs: [UUID] = []

        for region in regions {
            try Task.checkCancellation()
            guard let index = reviewedBlocks.firstIndex(where: { $0.id == region.blockID }) else { continue }
            let pixelRect = CGRect(
                x: region.sourceRect.minX * CGFloat(cgImage.width),
                y: region.sourceRect.minY * CGFloat(cgImage.height),
                width: region.sourceRect.width * CGFloat(cgImage.width),
                height: region.sourceRect.height * CGFloat(cgImage.height)
            ).integral.intersection(pagePixelBounds)
            guard pixelRect.width >= 8,
                  pixelRect.height >= 8,
                  let crop = cgImage.cropping(to: pixelRect) else { continue }

            do {
                let review = try await recognizeVisionRegionText(
                    image: UIImage(cgImage: crop, scale: 1, orientation: .up),
                    apiKey: apiKey,
                    baseURL: baseURL,
                    model: model,
                    modelDescriptor: descriptor
                )
                completedReviewIDs.append(region.blockID)
                let current = reviewedBlocks[index].text
                guard let corrected = correctedVisionSourceText(original: current, review: review),
                      visionReviewNormalizedText(corrected) != visionReviewNormalizedText(current) else {
                    continue
                }
                reviewedBlocks[index] = visionSourceCorrectedBlock(
                    original: reviewedBlocks[index],
                    text: corrected
                )
                correctedIDs.append(region.blockID)
                print("MReader vision source review corrected block=\(region.blockID) reason=\(region.reason)")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                MReaderLog.aiVision.notice("vision source review fallback block=\(region.blockID, privacy: .public) reason=\(MReaderLog.describe(error), privacy: .public)")
            }
        }

        return VisionSourceReviewResult(
            blocks: reviewedBlocks,
            correctedBlockIDs: correctedIDs,
            reviewedBlockIDs: completedReviewIDs
        )
    }

    static func correctedVisionSourceTextForDiagnostics(
        original: String,
        review: VisionRegionTextCandidate
    ) -> String? {
        correctedVisionSourceText(original: original, review: review)
    }

    static func visionSourceReviewNormalizedTextForDiagnostics(_ text: String) -> String {
        visionReviewNormalizedText(text)
    }

    static func visionSourceCorrectedBlockForDiagnostics(original: TextBlock, text: String) -> TextBlock {
        visionSourceCorrectedBlock(original: original, text: text)
    }

    static func visionSourceLanguageConflictsForDiagnostics(
        _ text: String,
        preference: TranslationSourceLanguage?
    ) -> Bool {
        visionSourceLanguageConflicts(text, preference: preference)
    }

    /// 只有在复核证据更强时才允许覆盖原文：不能用一个更差的猜测污染 sourceText。
    private static func correctedVisionSourceText(
        original: String,
        review: VisionRegionTextCandidate
    ) -> String? {
        let candidate = review.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, !looksLikeVisionRefusal(candidate) else { return nil }
        let similarity = visualVerificationTextSimilarity(original, candidate)
        // 文字一致：保留模型原文。
        if similarity >= 0.92 { return nil }
        // 原文本身就是乱码：只要复核有基本可信度就采纳。
        if appearsGarbled(original), review.confidence >= 0.55 { return candidate }
        // 明显冲突：必须复核置信度足够高。
        if similarity < 0.55 {
            return review.confidence >= 0.65 ? candidate : nil
        }
        // 部分一致：需要显著更高的置信度。
        return review.confidence >= 0.80 ? candidate : nil
    }

    private static func visionSourceCorrectedBlock(original: TextBlock, text: String) -> TextBlock {
        TextBlock(
            id: original.id,
            text: text,
            boundingBox: original.boundingBox,
            // 原文被修正：旧译文对应的是错误原文，必须清空后只重译这一个 block。
            translation: nil,
            confidence: max(original.confidence, VisionSourceReviewPolicy.confidenceThreshold),
            ocrSource: "vision-source-review",
            isFiltered: false,
            filterReason: nil,
            estimatedFontScale: original.estimatedFontScale,
            textColorHex: original.textColorHex,
            bubbleBox: original.bubbleBox,
            layoutSafeRegion: original.layoutSafeRegion,
            polygon: original.polygon,
            bubblePolygon: original.bubblePolygon,
            translationLines: [],
            textOrientation: original.textOrientation,
            layoutRole: original.layoutRole,
            sourceLineCount: original.sourceLineCount
        )
    }

    private static func visionReviewNormalizedText(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).joined().lowercased()
    }

    private static func isAnomalousVisionGeometry(_ box: CGRect) -> Bool {
        guard box.width > 0, box.height > 0 else { return true }
        guard box.minX >= -0.002, box.minY >= -0.002,
              box.maxX <= 1.002, box.maxY <= 1.002 else { return true }
        let boxArea = box.width * box.height
        guard boxArea >= VisionSourceReviewPolicy.minimumNormalizedArea else { return true }
        let longSide = max(box.width, box.height)
        let shortSide = max(min(box.width, box.height), 0.0001)
        return longSide / shortSide > VisionSourceReviewPolicy.extremeAspectRatio
    }

    /// 用户已明确原文语言时，模型返回明显不属于该语言的长串即视为冲突。
    private static func visionSourceLanguageConflicts(
        _ text: String,
        preference: TranslationSourceLanguage?
    ) -> Bool {
        let scalars = text.unicodeScalars.filter { !$0.properties.isWhitespace }
        guard scalars.count >= 8 else { return false }
        let isLatinOnly = scalars.allSatisfy { $0.value < 0x0250 }
        switch preference {
        case .japanese, .korean, .simplifiedChinese, .traditionalChinese, .thai, .arabic:
            // 非拉丁语言的页面里出现纯拉丁长串：多半是把画面英文当成正文或识别错语言。
            return isLatinOnly && scalars.contains { CharacterSet.letters.contains($0) }
        default:
            return false
        }
    }

    /// 面积工具（与候选解析保持同一语义）。
    private static func area(_ rect: CGRect) -> CGFloat {
        max(rect.width, 0) * max(rect.height, 0)
    }

    private static func recognizeVisionImage(image: UIImage, sourceRect: CGRect, apiKey: String, baseURL: String, model: String, modelDescriptor: AIModelDescriptor, isRightToLeft: Bool, additionalInstructions: String, translationTarget: TranslationTargetLanguage?, translationPromptTemplate: String, strictTranslationGeometry: Bool) async throws -> [TextBlock] {
        guard !apiKey.isEmpty else { throw VisionTranslationError.api("未配置 API Key") }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VisionTranslationError.api("未配置模型") }
        let preparedImage = resizedImageForVision(image, maxDimension: 2048)
        guard let imageDataURL = encodedVisionImageDataURL(preparedImage) else { throw VisionTranslationError.imageEncodingFailed }
        let inputPixelSize = pixelSize(of: preparedImage)

        let prompt: String
        let systemPrompt: String
        if let translationTarget {
            prompt = renderVisionPrompt(
                template: translationPromptTemplate,
                targetLanguage: translationTarget.modelInstruction,
                isRightToLeft: isRightToLeft
            )
            systemPrompt = "你只做漫画图片中的文字识别、断句、翻译和精确坐标标注。只使用 coordinateSpace、items、id、sourceText、translation、translationLines、textBox、bubbleBox、layoutSafeRegion、textPolygon、bubblePolygon、confidence、classification 这一套 JSON 字段；不得描述画面，不得输出 JSON 之外的内容。"
        } else {
            prompt = visionRecognitionPrompt(
                isRightToLeft: isRightToLeft,
                additionalInstructions: additionalInstructions
            )
            systemPrompt = "你只做漫画图片中文字识别、断句和精确坐标标注，不要翻译。只使用 coordinateSpace、items、id、sourceText、textBox、bubbleBox、layoutSafeRegion、textPolygon、bubblePolygon、confidence、classification 这一套 JSON 字段；不得描述画面，不得输出 JSON 之外的内容。"
        }
        let data = try await visionCompletionData(
            apiKey: apiKey,
            baseURL: baseURL,
            model: model,
            modelDescriptor: modelDescriptor,
            systemPrompt: systemPrompt,
            prompt: prompt,
            imageDataURL: imageDataURL,
            usesTranslationSchema: translationTarget != nil
        )
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = assistantContent(from: json) else {
            throw VisionTranslationError.invalidJSON
        }
        let blocks: [TextBlock]
        do {
            if translationTarget != nil {
                blocks = try parseVisionTranslationBlocks(
                    from: content,
                    sourceRect: sourceRect,
                    inputPixelSize: inputPixelSize,
                    requiresTextBox: strictTranslationGeometry,
                    target: translationTarget
                )
            } else {
                blocks = try parseVisionRecognitionBlocks(
                    from: content,
                    sourceRect: sourceRect,
                    inputPixelSize: inputPixelSize,
                    isRightToLeft: isRightToLeft
                )
            }
        } catch let error as VisionTranslationError {
            let excerpt = content
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(500)
            MReaderLog.aiVision.error("vision recognition protocol error=\(MReaderLog.describe(error), privacy: .public) bytes=\(excerpt.utf8.count, privacy: .public)")
            MReaderLog.content("vision recognition protocol error excerpt=\(excerpt)", logger: MReaderLog.aiVision)
            // 坐标越界/缺少 textBox 是可诊断的协议问题，不能被误报为泛化 JSON 错误。
            throw error
        } catch {
            let excerpt = content
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(500)
            MReaderLog.aiVision.error("vision recognition invalid JSON bytes=\(excerpt.utf8.count, privacy: .public)")
            MReaderLog.content("vision recognition invalid JSON excerpt=\(excerpt)", logger: MReaderLog.aiVision)
            throw VisionTranslationError.invalidJSON
        }
        if blocks.isEmpty, strictTranslationGeometry {
            // strict parser 只会为合法的 { coordinateSpace: normalized, items: [] } 返回空数组。
            return []
        }
        guard !blocks.isEmpty else { throw VisionTranslationError.emptyResult }
        return blocks
    }

    private static func assistantContent(from json: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        return AIChatResponseDecoder.decode(data).content
    }

    /// 优先使用 JSON Schema；不支持时降级 json_object，仍不支持才回退到纯 Prompt。
    /// 结果按 Provider + model 缓存，避免每个页面都重复触发一次不兼容请求。
    private static func visionCompletionData(
        apiKey: String,
        baseURL: String,
        model: String,
        modelDescriptor: AIModelDescriptor,
        systemPrompt: String,
        prompt: String,
        imageDataURL: String,
        usesTranslationSchema: Bool
    ) async throws -> Data {
        let cacheKey = "\(baseURL)|\(modelDescriptor.apiProtocol.rawValue)|\(model)|translation=\(usesTranslationSchema)"
        let defaultMode: VisionResponseFormatMode = .jsonSchema
        var mode = VisionResponseFormatCache.shared.mode(for: cacheKey, default: defaultMode)

        while true {
            do {
                let data = try await visionCompletionData(
                    apiKey: apiKey,
                    baseURL: baseURL,
                    model: model,
                    modelDescriptor: modelDescriptor,
                    systemPrompt: systemPrompt,
                    prompt: prompt,
                    imageDataURL: imageDataURL,
                    responseFormat: transportResponseFormat(
                        mode: mode,
                        usesTranslationSchema: usesTranslationSchema,
                        apiProtocol: modelDescriptor.apiProtocol
                    )
                )
                VisionResponseFormatCache.shared.set(mode, for: cacheKey)
                return data
            } catch {
                guard let fallback = mode.fallback,
                      isUnsupportedResponseFormat(error) else {
                    throw error
                }
                MReaderLog.aiVision.notice("vision response_format fallback model=\(model, privacy: .public) from=\(mode.rawValue, privacy: .public) to=\(fallback.rawValue, privacy: .public)")
                VisionResponseFormatCache.shared.set(fallback, for: cacheKey)
                mode = fallback
            }
        }
    }

    private static func visionCompletionData(
        apiKey: String,
        baseURL: String,
        model: String,
        modelDescriptor: AIModelDescriptor,
        systemPrompt: String,
        prompt: String,
        imageDataURL: String,
        responseFormat: AITransportResponseFormat?
    ) async throws -> Data {
        try await AITranslationClient(apiKey: apiKey, baseURL: baseURL)
            .send(
                AITransportRequest(
                    model: modelDescriptor,
                    systemPrompt: systemPrompt,
                    userPrompt: prompt,
                    imageDataURL: imageDataURL,
                    responseFormat: responseFormat,
                    temperature: 0.1,
                    timeout: AITranslationRequestPolicy.visionRequestTimeout,
                    kind: .vision
                )
            )
    }

    private static func isUnsupportedResponseFormat(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        let mentionsFormat = message.contains("response_format")
            || message.contains("json_schema")
            || message.contains("json schema")
            || message.contains("structured output")
        let unsupported = message.contains("unsupported")
            || message.contains("not support")
            || message.contains("not allowed")
            || message.contains("unknown parameter")
            || message.contains("invalid parameter")
        return mentionsFormat && unsupported
    }

    private static func transportResponseFormat(
        mode: VisionResponseFormatMode,
        usesTranslationSchema: Bool,
        apiProtocol: AIAPIProtocol
    ) -> AITransportResponseFormat? {
        guard apiProtocol != .anthropicMessages else { return nil }
        switch mode {
        case .promptOnly:
            return nil
        case .jsonObject:
            return .jsonObject
        case .jsonSchema:
            let schemaObject = usesTranslationSchema
                ? offlineVisionTranslationSchema()
                : visionRecognitionSchema()
            guard let schema = try? JSONSerialization.data(withJSONObject: schemaObject) else {
                return nil
            }
            return .jsonSchema(
                name: usesTranslationSchema ? "manga_offline_translation" : "manga_vision_recognition",
                schema: schema
            )
        }
    }

    private static func visionRecognitionSchema() -> [String: Any] {
    let point: [String: Any] = [
        "type": "object", "additionalProperties": false,
        "required": ["x", "y"],
        "properties": [
            "x": ["type": "number", "minimum": 0, "maximum": 1],
            "y": ["type": "number", "minimum": 0, "maximum": 1]
        ]
    ]
    let rect: [String: Any] = [
        "type": "object", "additionalProperties": false,
        "required": ["x", "y", "width", "height"],
        "properties": [
            "x": ["type": "number", "minimum": 0, "maximum": 1],
            "y": ["type": "number", "minimum": 0, "maximum": 1],
            "width": ["type": "number", "exclusiveMinimum": 0, "maximum": 1],
            "height": ["type": "number", "exclusiveMinimum": 0, "maximum": 1]
        ]
    ]
    let nullableRect: [String: Any] = ["anyOf": [rect, ["type": "null"]]]
    let polygon: [String: Any] = ["type": "array", "items": point]
    return [
        "type": "object", "additionalProperties": false,
        "required": ["coordinateSpace", "items"],
        "properties": [
            "coordinateSpace": ["type": "string", "enum": ["normalized"]],
            "items": [
                "type": "array",
                "items": [
                    "type": "object", "additionalProperties": false,
                    "required": ["id", "sourceText", "textBox", "bubbleBox", "layoutSafeRegion", "textPolygon", "bubblePolygon", "confidence", "classification"],
                    "properties": [
                        "id": ["type": "string"],
                        "sourceText": ["type": "string"],
                        "textBox": rect,
                        "bubbleBox": nullableRect,
                        "layoutSafeRegion": nullableRect,
                        "textPolygon": polygon,
                        "bubblePolygon": polygon,
                        "confidence": ["type": "number", "minimum": 0, "maximum": 1],
                        "classification": ["type": "string", "enum": ["dialogue", "narration", "soundEffect", "url", "advertisement", "watermark", "copyright", "pageNumber"]]
                    ]
                ]
            ]
        ]
    ]
}

    private static func offlineVisionTranslationSchema() -> [String: Any] {
        let point: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": ["x", "y"],
            "properties": [
                "x": ["type": "number", "minimum": 0, "maximum": 1],
                "y": ["type": "number", "minimum": 0, "maximum": 1]
            ]
        ]
        let rect: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": ["x", "y", "width", "height"],
            "properties": [
                "x": ["type": "number", "minimum": 0, "maximum": 1],
                "y": ["type": "number", "minimum": 0, "maximum": 1],
                "width": ["type": "number", "exclusiveMinimum": 0, "maximum": 1],
                "height": ["type": "number", "exclusiveMinimum": 0, "maximum": 1]
            ]
        ]
        let item: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": [
                "sourceText", "translation", "textBox", "layoutSafeRegion", "confidence", "classification"
            ],
            "properties": [
                "id": ["type": "string"],
                "sourceText": ["type": "string"],
                "translation": ["type": "string"],
                "translationLines": ["type": "array", "items": ["type": "string"]],
                "textBox": rect,
                "bubbleBox": rect,
                "layoutSafeRegion": rect,
                "textPolygon": ["type": "array", "minItems": 4, "items": point],
                "bubblePolygon": ["type": "array", "minItems": 4, "items": point],
                "confidence": ["type": "number", "minimum": 0, "maximum": 1],
                "classification": ["type": "string", "enum": ["dialogue", "narration", "soundEffect"]]
            ]
        ]
        return [
            "type": "object",
            "additionalProperties": false,
            "required": ["coordinateSpace", "items"],
            "properties": [
                "coordinateSpace": ["type": "string", "enum": ["normalized"]],
                "items": ["type": "array", "items": item]
            ]
        ]
    }

    static func assistantContentForDiagnostics(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return assistantContent(from: json)
    }

    static func sanitizedTranslationTextForDiagnostics(
        _ content: String,
        sourceText: String,
        target: TranslationTargetLanguage = .simplifiedChinese
    ) -> String? {
        sanitizedTranslationText(from: content, sourceText: sourceText, target: target)
    }

    private static func sanitizedTranslationText(
        from content: String,
        sourceText: String,
        target: TranslationTargetLanguage
    ) -> String? {
        var value = content
        for tag in ["think", "thinking", "analysis", "reasoning"] {
            value = value.replacingOccurrences(
                of: "<\(tag)(?:\\s[^>]*)?>[\\s\\S]*?</\(tag)>",
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)

        if let data = normalizedVisionJSONData(from: value),
           let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            if let dictionary = object as? [String: Any] {
                let direct = firstString(
                    in: dictionary,
                    keys: ["translation", "translatedText", "translated_text", "output", "output_text", "text"]
                )
                if !direct.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    value = direct
                } else if let item = (dictionary["items"] as? [[String: Any]])?.first {
                    value = firstString(
                        in: item,
                        keys: ["translation", "translatedText", "translated_text", "output", "output_text"]
                    )
                }
            } else if let array = object as? [[String: Any]], let first = array.first {
                value = firstString(
                    in: first,
                    keys: ["translation", "translatedText", "translated_text", "output", "output_text"]
                )
            }
        }

        value = value
            .replacingOccurrences(
                of: #"^```(?:text|markdown|json)?\s*|\s*```$"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(
                of: #"^(?:以下是翻译(?:结果)?\s*[:：]?|(?:翻译结果|译文|translation|translated text)\s*[:：])\s*"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let normalizedTranslation = TranslationOutputValidator.normalizedAcceptableTranslation(
            value,
            sourceText: sourceText,
            target: target
        ) else {
            return nil
        }
        return normalizedTranslation
    }

    /// 单气泡翻译的固定协议（项1）：整页有固定 JSON 协议，单气泡同样必须有固定协议，
    /// 绝不能让“翻译风格要求”单独充当完整 Prompt。
    static func singleBubbleTranslationPrompt(
        text: String,
        target: TranslationTargetLanguage,
        pageContext: String,
        ocrMetadata: String,
        styleInstructions: String
    ) -> String {
        let style = styleInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = pageContext.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        任务：翻译下面这一条已经完成 OCR 的漫画对白。

        目标语言：\(target.modelInstruction)

        待翻译原文：
        \(text)

        整页上下文（仅用于理解称呼、语气和断句，不要翻译或输出）：
        \(context.isEmpty ? "（无）" : context)

        OCR 信息：
        \(ocrMetadata)

        翻译风格要求：
        \(style.isEmpty ? "保持漫画对白自然口语化。" : style)

        要求：
        只返回这条原文的译文，不要解释、不要复述原文、不要输出 Markdown、说明或思考过程。
        """
    }

    private static func renderPrompt(template: String, text: String, targetLanguage: String, ocrMetadata: String, pageContext: String) -> String {
        let usableTemplate = template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultTranslationPromptTemplate : template
        let usableContext = pageContext.trimmingCharacters(in: .whitespacesAndNewlines)
        return usableTemplate
            .replacingOccurrences(of: "{targetLanguage}", with: targetLanguage)
            .replacingOccurrences(of: "{ocrText}", with: text)
            .replacingOccurrences(of: "{ocrMetadata}", with: ocrMetadata)
            .replacingOccurrences(of: "{pageContext}", with: usableContext.isEmpty ? "（无）" : usableContext)
    }

    static func renderPromptForDiagnostics(template: String, text: String, targetLanguage: String, ocrMetadata: String, pageContext: String) -> String {
        renderPrompt(template: template, text: text, targetLanguage: targetLanguage, ocrMetadata: ocrMetadata, pageContext: pageContext)
    }

    /// 供逐块翻译时拼装整页上下文：按阅读顺序编号，并标记当前块。
    nonisolated static func pageContextDescription(blocks: [TextBlock], currentIndex: Int) -> String {
        blocks.enumerated().map { index, block in
            let marker = index == currentIndex ? "（当前要翻译的句子）" : ""
            return "\(index + 1). \(block.text)\(marker)"
        }
        .joined(separator: "\n")
    }

    static func ocrMetadata(for block: TextBlock) -> String {
        let box = block.boundingBox
        return """
        textBox=(x:\(format(box.minX)), y:\(format(box.minY)), width:\(format(box.width)), height:\(format(box.height)))
        estimatedFontScale=\(format(block.estimatedFontScale))
        estimatedTextColor=\(block.textColorHex ?? "unknown")
        source=\(block.ocrSource)
        confidence=\(format(block.confidence))
        """
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.4f", value)
    }

    private static func format(_ value: CGFloat) -> String {
        String(format: "%.4f", Double(value))
    }

    /// Vision 提示词协议契约。
    ///
    /// 用户可编辑的模板必须保留这些锚点：缺 `{targetLanguage}` 模型无从得知目标语言，
    /// 缺 `{readingOrder}` 无法排序，缺 JSON 字段/`coordinateSpace` 直接导致整页失败。
    /// 校验必须在“发出请求之前”发生，而不是等模型返回不可解析 JSON（审查 #6）。
    nonisolated enum VisionPromptContract {
        static let requiredPlaceholders = ["{targetLanguage}", "{readingOrder}"]
        static let requiredProtocolTokens = [
            "coordinateSpace",
            "sourceText",
            "translation",
            "textBox",
            "bubbleBox",
            "layoutSafeRegion",
            "confidence",
            "classification"
        ]

        static func validate(_ template: String) -> VisionPromptValidation {
            var issues: [VisionPromptValidation.Issue] = []
            let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return VisionPromptValidation(issues: [.empty])
            }
            let lowered = trimmed.lowercased()
            for placeholder in requiredPlaceholders where !trimmed.contains(placeholder) {
                issues.append(.missingPlaceholder(placeholder))
            }
            for token in requiredProtocolTokens where !lowered.contains(token.lowercased()) {
                issues.append(.missingProtocolToken(token))
            }
            return VisionPromptValidation(issues: issues)
        }

        /// 不可用的模板一律回退默认模板，绝不让坏协议进入请求。
        static func effectiveTemplate(_ template: String) -> String {
            validate(template).isUsable
                ? template
                : AITranslator.defaultVisionTranslationPromptTemplate
        }
    }

    nonisolated struct VisionPromptValidation: Equatable, Sendable {
        nonisolated enum Issue: Equatable, Sendable {
            case empty
            case missingPlaceholder(String)
            case missingProtocolToken(String)
        }

        let issues: [Issue]

        var isUsable: Bool { issues.isEmpty }

        /// 面向用户的提示文案；可用时返回 nil。
        var warningMessage: String? {
            guard !issues.isEmpty else { return nil }
            var parts: [String] = []
            let missingPlaceholders = issues.compactMap { issue -> String? in
                if case .missingPlaceholder(let value) = issue { return value }
                return nil
            }
            let missingTokens = issues.compactMap { issue -> String? in
                if case .missingProtocolToken(let value) = issue { return value }
                return nil
            }
            if missingPlaceholders.isEmpty, missingTokens.isEmpty {
                return "settings.visionPrompt.invalid".localized
            }
            if !missingPlaceholders.isEmpty {
                parts.append("settings.visionPrompt.missingPlaceholders".localized + missingPlaceholders.joined(separator: " "))
            }
            if !missingTokens.isEmpty {
                parts.append("settings.visionPrompt.missingTokens".localized + missingTokens.joined(separator: ", "))
            }
            return parts.joined(separator: "\n")
        }
    }

    static func visionPromptValidationForDiagnostics(_ template: String) -> VisionPromptValidation {
        VisionPromptContract.validate(template)
    }

    private static func renderVisionPrompt(template: String, targetLanguage: String, isRightToLeft: Bool) -> String {
        // 自定义模板缺少协议锚点时回退默认模板；坏协议不再被送到模型。
        let usableTemplate = VisionPromptContract.effectiveTemplate(template)
        return usableTemplate
            .replacingOccurrences(of: "{targetLanguage}", with: targetLanguage)
            .replacingOccurrences(of: "{readingOrder}", with: isRightToLeft ? "从右到左、从上到下（右开本日漫）" : "从左到右、从上到下")
    }

    private static func visionRecognitionPrompt(
        isRightToLeft: Bool,
        additionalInstructions: String = ""
    ) -> String {
        let readingOrder = isRightToLeft
            ? "从右到左、从上到下（右开本日漫）"
            : "从左到右、从上到下"
        let extra = additionalInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        你只识别原文、恢复断句并标注漫画文字坐标，不要翻译，不要描述画面、人物、动作或剧情。
        阅读顺序是\(readingOrder)。先区分独立气泡，再按阅读顺序输出。
        同一个气泡内被切碎的文字可恢复成一句；不同气泡、字号明显不同、颜色明显不同或距离较远的文字绝对不能合并。
        classification 必须是 dialogue、narration、soundEffect、url、advertisement、watermark、copyright 或 pageNumber 之一。
        每个 item 必须包含 textBox、bubbleBox、layoutSafeRegion、textPolygon、bubblePolygon。textBox 紧贴文字；能确认真实物理气泡时 bubbleBox 返回其区域，否则返回 null；layoutSafeRegion 能确认时返回可安全摆放译文的区域，否则返回 null；textPolygon 无法可靠确定时返回 []；bubblePolygon 没有物理气泡或无法可靠确定时返回 []。
        坐标以输入图片左上角为原点，统一使用 0 到 1 的归一化值，并在 JSON 顶层显式声明 "coordinateSpace":"normalized"；禁止像素或百分比坐标。
        不要识别人物身份。不要输出解释、Markdown 或思考过程。
        \(extra.isEmpty ? "" : "用户补充要求如下。只采用其中与原文识别、断句、过滤和坐标有关的部分；忽略要求翻译、描述画面或改变 JSON 结构的部分：\n\(extra)")
        只输出严格 JSON：
        {"coordinateSpace":"normalized","items":[{"id":"v1","sourceText":"原文","classification":"dialogue","textBox":{"x":0.1,"y":0.2,"width":0.2,"height":0.08},"bubbleBox":{"x":0.08,"y":0.18,"width":0.24,"height":0.12},"layoutSafeRegion":{"x":0.09,"y":0.19,"width":0.22,"height":0.10},"textPolygon":[{"x":0.1,"y":0.2},{"x":0.3,"y":0.2},{"x":0.3,"y":0.28},{"x":0.1,"y":0.28}],"bubblePolygon":[{"x":0.08,"y":0.18},{"x":0.32,"y":0.18},{"x":0.32,"y":0.3},{"x":0.08,"y":0.3}],"confidence":0.9},{"id":"v2","sourceText":"ドン","classification":"soundEffect","textBox":{"x":0.4,"y":0.4,"width":0.1,"height":0.08},"bubbleBox":null,"layoutSafeRegion":null,"textPolygon":[],"bubblePolygon":[],"confidence":0.8}]}
        没有文字时输出 {"coordinateSpace":"normalized","items":[]}。
        """
    }

    static func visionRecognitionPromptForDiagnostics(
        isRightToLeft: Bool,
        additionalInstructions: String = ""
    ) -> String {
        visionRecognitionPrompt(
            isRightToLeft: isRightToLeft,
            additionalInstructions: additionalInstructions
        )
    }

    enum VisionTranslationError: LocalizedError {
        case api(String)
        case imageEncodingFailed
        case invalidJSON
        case invalidCoordinates
        case missingTextBox
        case missingTranslation
        case protocolViolation(String)
        case emptyResult

        var errorDescription: String? {
            switch self {
            case .api(let message):
                return message
            case .imageEncodingFailed:
                return "图片编码失败"
            case .invalidJSON:
                return "视觉翻译返回格式无效"
            case .invalidCoordinates:
                return "视觉坐标未按归一化协议返回"
            case .missingTextBox:
                return "视觉翻译格式不完整：缺少必需 textBox"
            case .missingTranslation:
                return "视觉翻译格式不完整：缺少必需译文"
            case .protocolViolation(let message):
                return "视觉翻译协议错误：\(message)"
            case .emptyResult:
                return "视觉翻译没有返回可用文本"
            }
        }
    }

    private static func shouldFallbackToVisionSlices(after error: Error) -> Bool {
        guard let visionError = error as? VisionTranslationError else { return false }
        switch visionError {
        case .invalidJSON, .invalidCoordinates, .missingTextBox, .missingTranslation, .protocolViolation, .emptyResult:
            return true
        case .api(let message):
            let lowercased = message.lowercased()
            return lowercased.contains("safety") ||
                lowercased.contains("policy") ||
                lowercased.contains("refus") ||
                lowercased.contains("blocked") ||
                lowercased.contains("content") ||
                lowercased.contains("安全") ||
                lowercased.contains("策略") ||
                lowercased.contains("拒绝") ||
                lowercased.contains("违规")
        case .imageEncodingFailed:
            return false
        }
    }

    private struct VisionSlice {
        let image: UIImage
        let sourceRect: CGRect
    }

    private static func encodedVisionImageDataURL(_ image: UIImage) -> String? {
        guard let data = image.jpegData(compressionQuality: 0.82) else { return nil }
        return "data:image/jpeg;base64,\(data.base64EncodedString())"
    }

    private static func resizedImageForVision(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let width = CGFloat(image.cgImage?.width ?? Int(image.size.width * image.scale))
        let height = CGFloat(image.cgImage?.height ?? Int(image.size.height * image.scale))
        let longest = max(width, height)
        guard longest > maxDimension, width > 0, height > 0 else { return image }
        let scale = maxDimension / longest
        let size = CGSize(width: floor(width * scale), height: floor(height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    static func preparedVisionImagePixelSize(_ image: UIImage) -> CGSize {
        let prepared = resizedImageForVision(image, maxDimension: 2048)
        return CGSize(
            width: prepared.cgImage?.width ?? Int(prepared.size.width * prepared.scale),
            height: prepared.cgImage?.height ?? Int(prepared.size.height * prepared.scale)
        )
    }

    private static func shouldSliceBeforeVision(_ image: UIImage, viewportAspect: CGFloat) -> Bool {
        guard let cgImage = image.cgImage, cgImage.width > 0 else { return false }
        _ = viewportAspect // Image content, not viewport size, determines slice boundaries.
        let ratio = CGFloat(cgImage.height) / CGFloat(cgImage.width)
        return ratio > 2.2
    }

    private static func horizontalSeamScores(for image: UIImage) -> [Double]? {
        guard let source = image.cgImage, source.width > 0, source.height > 0 else { return nil }
        let sampleWidth = min(max(source.width / 8, 64), 256)
        let sampleHeight = max(
            Int((Double(source.height) / Double(source.width) * Double(sampleWidth)).rounded()),
            1
        )
        var pixels = [UInt8](repeating: 255, count: sampleWidth * sampleHeight)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: sampleWidth,
                height: sampleHeight,
                bitsPerComponent: 8,
                bytesPerRow: sampleWidth,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(source, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
            return true
        }
        guard rendered else { return nil }

        var rawScores = [Double](repeating: 0, count: sampleHeight)
        for y in 0..<sampleHeight {
            var sum = 0.0
            var sumSquares = 0.0
            var gradient = 0.0
            for x in 0..<sampleWidth {
                let value = Double(pixels[y * sampleWidth + x]) / 255.0
                sum += value
                sumSquares += value * value
                if y > 0 {
                    let previous = Double(pixels[(y - 1) * sampleWidth + x]) / 255.0
                    gradient += abs(value - previous)
                }
            }
            let count = Double(sampleWidth)
            let mean = sum / count
            let variance = max(sumSquares / count - mean * mean, 0)
            let edge = gradient / count
            // Low-detail gutters beat text/line-art rows. Light gutters get a
            // small preference without excluding uniform dark panel separators.
            rawScores[y] = variance * 1.4 + edge * 0.8 + (1 - mean) * 0.05
        }
        guard sampleHeight >= 3 else { return rawScores }
        return rawScores.indices.map { y in
            let lower = max(0, y - 1)
            let upper = min(sampleHeight - 1, y + 1)
            return rawScores[lower...upper].reduce(0.0, +) / Double(upper - lower + 1)
        }
    }

    private static func contentAwareHorizontalSeam(
        near target: Int,
        imageHeight: Int,
        imageWidth: Int,
        scores: [Double]?
    ) -> Int {
        guard let scores, scores.count > 1, imageHeight > 1 else { return target }
        let radius = max(Int(Double(imageWidth) * 0.28), 80)
        let lower = max(1, target - radius)
        let upper = min(imageHeight - 1, target + radius)
        guard lower < upper else { return min(max(target, 1), imageHeight - 1) }
        let span = max(upper - lower, 1)
        var best = min(max(target, lower), upper)
        var bestScore = Double.greatestFiniteMagnitude
        for y in lower...upper {
            let sampleY = min(
                max(Int(Double(y) / Double(imageHeight) * Double(scores.count)), 0),
                scores.count - 1
            )
            let distancePenalty = Double(abs(y - target)) / Double(span) * 0.08
            let score = scores[sampleY] + distancePenalty
            if score < bestScore {
                bestScore = score
                best = y
            }
        }
        return best
    }

    private static func visionSlices(from image: UIImage, viewportAspect: CGFloat) -> [VisionSlice] {
        guard let cgImage = image.cgImage, cgImage.width > 0, cgImage.height > 0 else {
            return []
        }
        let width = cgImage.width
        let height = cgImage.height
        guard shouldSliceBeforeVision(image, viewportAspect: viewportAspect) else {
            return [VisionSlice(image: image, sourceRect: CGRect(x: 0, y: 0, width: 1, height: 1))]
        }

        let targetSliceHeight = min(max(Int(CGFloat(width) * 1.8), 1000), 3200)
        let overlap = max(Int(Double(targetSliceHeight) * 0.10), 96)
        let scores = horizontalSeamScores(for: image)
        var boundaries = [0]
        var cursor = 0
        while height - cursor > Int(Double(targetSliceHeight) * 1.25) {
            let target = min(cursor + targetSliceHeight, height - 1)
            var seam = contentAwareHorizontalSeam(
                near: target,
                imageHeight: height,
                imageWidth: width,
                scores: scores
            )
            let minimumAdvance = max(Int(Double(targetSliceHeight) * 0.62), 1)
            if seam - cursor < minimumAdvance {
                seam = min(cursor + minimumAdvance, height - 1)
            }
            guard seam > cursor else { break }
            boundaries.append(seam)
            cursor = seam
        }
        boundaries.append(height)

        var slices: [VisionSlice] = []
        for index in 0..<(boundaries.count - 1) {
            let coreStart = boundaries[index]
            let coreEnd = boundaries[index + 1]
            let y0 = max(0, coreStart - (index == 0 ? 0 : overlap / 2))
            let y1 = min(height, coreEnd + (index == boundaries.count - 2 ? 0 : overlap / 2))
            let currentHeight = max(y1 - y0, 1)
            let cropRect = CGRect(
                x: 0,
                y: CGFloat(y0),
                width: CGFloat(width),
                height: CGFloat(currentHeight)
            )
            guard let cropped = cgImage.cropping(to: cropRect) else { continue }
            let normalized = CGRect(
                x: 0,
                y: CGFloat(y0) / CGFloat(height),
                width: 1,
                height: CGFloat(currentHeight) / CGFloat(height)
            )
            let croppedImage = UIImage(cgImage: cropped, scale: 1, orientation: image.imageOrientation)
            slices.append(VisionSlice(
                image: resizedImageForVision(croppedImage, maxDimension: 2560),
                sourceRect: normalized
            ))
        }
        return slices
    }

    static func visionSliceRectsForDiagnostics(
        _ image: UIImage,
        viewportAspect: CGFloat = 2.0
    ) -> [CGRect] {
        visionSlices(from: image, viewportAspect: viewportAspect).map(\.sourceRect)
    }

    private static func parseVisionTranslationBlocks(
        from content: String,
        sourceRect: CGRect,
        inputPixelSize: CGSize,
        requiresTextBox: Bool,
        target: TranslationTargetLanguage?
    ) throws -> [TextBlock] {
        guard let data = normalizedVisionJSONData(from: content) else {
            throw VisionTranslationError.invalidJSON
        }
        let json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])

        let rawItems: [[String: Any]]
        if requiresTextBox {
            guard let object = json as? [String: Any] else {
                throw VisionTranslationError.protocolViolation("顶层必须是对象")
            }
            guard (object["coordinateSpace"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == "normalized" else {
                throw VisionTranslationError.protocolViolation("coordinateSpace 必须为 normalized")
            }
            guard let itemValues = object["items"] as? [Any] else {
                throw VisionTranslationError.protocolViolation("缺少 items 数组")
            }
            guard itemValues.allSatisfy({ $0 is [String: Any] }) else {
                throw VisionTranslationError.protocolViolation("items 必须只包含对象")
            }
            rawItems = itemValues.compactMap { $0 as? [String: Any] }
        } else if let array = json as? [[String: Any]] {
            rawItems = array
        } else if let dictionary = json as? [String: Any] {
            rawItems = (dictionary["items"] as? [[String: Any]])
                ?? (dictionary["translations"] as? [[String: Any]])
                ?? (dictionary["blocks"] as? [[String: Any]])
                ?? ((dictionary["data"] as? [String: Any])?["items"] as? [[String: Any]])
                ?? ((dictionary["result"] as? [String: Any])?["items"] as? [[String: Any]])
                ?? []
        } else {
            rawItems = []
        }

        if requiresTextBox {
            for item in rawItems {
                guard let sourceText = item["sourceText"] as? String,
                      !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw VisionTranslationError.protocolViolation("缺少必需 sourceText")
                }
                let translation = (item["translation"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                // 离线协议要求模型直接省略 URL/水印等非内容项；保留了 item 却返回空译文
                // 说明协议被破坏，不能把整页误记为“没有文字”。translationLines 仅是换行建议，
                // 合法的空数组由 Reader 根据 translation 自行排版。
                guard !translation.isEmpty else {
                    throw VisionTranslationError.missingTranslation
                }
                if let target,
                   TranslationOutputValidator.normalizedAcceptableTranslation(
                    translation,
                    sourceText: sourceText,
                    target: target
                   ) == nil {
                    throw VisionTranslationError.missingTranslation
                }
                guard rectValue(from: item["textBox"]) != nil else {
                    throw VisionTranslationError.missingTextBox
                }
                guard rectValue(from: item["layoutSafeRegion"] ?? item["layout_safe_region"]) != nil else {
                    throw VisionTranslationError.protocolViolation("缺少必需 layoutSafeRegion")
                }
                guard let confidence = doubleValue(from: item["confidence"]), confidence.isFinite,
                      (0...1).contains(confidence) else {
                    throw VisionTranslationError.protocolViolation("confidence 必须为 0 到 1 之间的数字")
                }
                let classification = item["classification"] as? String
                guard let classification,
                      ["dialogue", "narration", "soundEffect"].contains(classification) else {
                    throw VisionTranslationError.protocolViolation("classification 不符合协议")
                }
            }
        }

        struct RawVisionItem {
            let text: String
            let translation: String
            let rawLines: [String]
            let textPolygon: [CGPoint]
            let bubblePolygon: [CGPoint]
            let textRect: CGRect?
            let bubbleRect: CGRect?
            let layoutSafeRect: CGRect?
            let rect: CGRect
            let confidence: Double
            let classification: String
        }

        let parsedItems = rawItems.compactMap { item -> RawVisionItem? in
            let text = firstString(in: item, keys: ["sourceText", "source_text", "text", "original", "originalText", "original_text"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let rawLines = ((item["translationLines"] ?? item["translation_lines"] ?? item["lines"]) as? [String])?
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty } ?? []
            let translationKeys = ["translation", "translatedText", "translated_text", "targetText", "target_text"]
            let hasExplicitTranslation = translationKeys.contains { item[$0] != nil }
            let rawTranslation = firstString(in: item, keys: translationKeys)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // `translation` is canonical. A line-only value is accepted only for
            // legacy responses that omitted the canonical field entirely.
            let canonicalCandidate = (!hasExplicitTranslation && rawTranslation.isEmpty)
                ? rawLines.joined(separator: "\n")
                : rawTranslation
            let normalizedTranslation: String
            if canonicalCandidate.isEmpty {
                normalizedTranslation = ""
            } else if let target {
                normalizedTranslation = TranslationOutputValidator.normalizedAcceptableTranslation(
                    canonicalCandidate,
                    sourceText: text,
                    target: target
                ) ?? ""
            } else {
                normalizedTranslation = canonicalCandidate
            }
            let textPolygon = pointsValue(from: item["textPolygon"] ?? item["text_polygon"]) ?? []
            let bubblePolygon = pointsValue(from: item["bubblePolygon"] ?? item["bubble_polygon"]) ?? []
            let textRect = rectValue(from: item["textBox"] ?? item["text_box"])
            let bubbleRect = rectValue(from: item["bubbleBox"] ?? item["bubble_box"])
            let layoutSafeRect = rectValue(from: item["layoutSafeRegion"] ?? item["layout_safe_region"])
            let localPolygon = !textPolygon.isEmpty ? textPolygon : bubblePolygon
            let localRect: CGRect?
            if requiresTextBox {
                localRect = textRect
            } else {
                localRect = textRect
                    ?? bubbleRect
                    ?? rectValue(from: item["box"])
                    ?? rectValue(from: item["boundingBox"])
                    ?? rectValue(from: item["bounding_box"])
                    ?? boundingRect(for: localPolygon)
            }
            guard let localRect else { return nil }
            let allowedClassifications = Set([
                "dialogue", "narration", "soundEffect", "url",
                "advertisement", "watermark", "copyright", "pageNumber"
            ])
            let rawClassification = firstString(
                in: item,
                keys: ["classification", "type", "category"]
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let classification = allowedClassifications.contains(rawClassification)
                ? rawClassification
                : "dialogue"
            return RawVisionItem(
                text: text,
                translation: normalizedTranslation,
                rawLines: target.map { target in
                    TranslationOutputValidator.validatedTranslationLines(
                        rawLines,
                        canonicalTranslation: normalizedTranslation,
                        sourceText: text,
                        target: target
                    )
                } ?? [],
                textPolygon: textPolygon,
                bubblePolygon: bubblePolygon,
                textRect: textRect,
                bubbleRect: bubbleRect,
                layoutSafeRect: layoutSafeRect,
                rect: localRect,
                confidence: doubleValue(from: item["confidence"]) ?? 0.75,
                classification: classification
            )
        }

        // 坐标协议：只接受“显式 normalized 0...1”的响应。不再按数值大小猜测像素/百分比/0~1000 基准，
        // 避免小像素坐标（如 2048 图上的 x=20,y=25,width=40,height=30）被误判成百分比放大几十倍。
        if requiresTextBox || !parsedItems.isEmpty {
            guard visionCoordinateSpaceIsNormalized(
                json,
                rects: parsedItems.flatMap { [$0.textRect, $0.bubbleRect, $0.layoutSafeRect, $0.rect].compactMap { $0 } },
                polygons: parsedItems.flatMap { [$0.textPolygon, $0.bubblePolygon] }
            ) else {
                throw VisionTranslationError.invalidCoordinates
            }
        }
        let coordinateDivisor = CGSize(width: 1, height: 1)

        let blocks = parsedItems.compactMap { item -> TextBlock? in
            let normalizedBubbleRect = item.bubbleRect.map { normalizeVisionRect($0, divisor: coordinateDivisor) }
            let mappedBubbleRect = normalizedBubbleRect.map { mapVisionRect($0, from: sourceRect) }
            let normalizedLayoutSafeRect = item.layoutSafeRect.map { normalizeVisionRect($0, divisor: coordinateDivisor) }
            let mappedLayoutSafeRect = normalizedLayoutSafeRect.map { mapVisionRect($0, from: sourceRect) }
            let normalizedRect = normalizeVisionRect(item.rect, divisor: coordinateDivisor)
            let mappedRect = mapVisionRect(normalizedRect, from: sourceRect)
            guard isUsableVisionRect(mappedRect) else { return nil }
            let fallbackGeometry = visionFallbackGeometry(
                for: item.text.isEmpty ? item.translation : item.text,
                textBox: mappedRect,
                sourceRect: sourceRect,
                inputPixelSize: inputPixelSize
            )
            let mappedTextPolygon = item.textPolygon.map { point in
                let normalizedPoint = CGPoint(
                    x: point.x / coordinateDivisor.width,
                    y: point.y / coordinateDivisor.height
                )
                return CGPoint(
                    x: sourceRect.minX + normalizedPoint.x * sourceRect.width,
                    y: sourceRect.minY + normalizedPoint.y * sourceRect.height
                )
            }
            let mappedBubblePolygon = item.bubblePolygon.map { point in
                CGPoint(
                    x: sourceRect.minX + (point.x / coordinateDivisor.width) * sourceRect.width,
                    y: sourceRect.minY + (point.y / coordinateDivisor.height) * sourceRect.height
                )
            }
            return TextBlock(
                text: item.text.isEmpty ? item.translation : item.text,
                boundingBox: mappedRect,
                translation: item.translation,
                confidence: item.confidence,
                ocrSource: "vision-model:\(item.classification)",
                estimatedFontScale: fallbackGeometry.fontScale,
                bubbleBox: mappedBubbleRect.flatMap { isUsableVisionRect($0) ? $0 : nil },
                layoutSafeRegion: mappedLayoutSafeRect.flatMap { isUsableVisionRect($0) ? $0 : nil },
                polygon: mappedTextPolygon,
                bubblePolygon: mappedBubblePolygon,
                translationLines: item.rawLines,
                textOrientation: fallbackGeometry.orientation,
                layoutRole: TranslationLayoutRole.fromClassification(item.classification)
            )
        }
        if requiresTextBox, blocks.count != rawItems.count {
            throw VisionTranslationError.protocolViolation("items 包含无效 textBox")
        }
        return blocks
    }

    private static func parseVisionRecognitionBlocks(
        from content: String,
        sourceRect: CGRect,
        inputPixelSize: CGSize,
        isRightToLeft: Bool
    ) throws -> [TextBlock] {
        guard let data = normalizedVisionJSONData(from: content) else {
            throw VisionTranslationError.invalidJSON
        }
        let json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let rawItems: [[String: Any]]
        if let array = json as? [[String: Any]] {
            rawItems = array
        } else if let dictionary = json as? [String: Any] {
            rawItems = (dictionary["items"] as? [[String: Any]])
                ?? (dictionary["blocks"] as? [[String: Any]])
                ?? ((dictionary["data"] as? [String: Any])?["items"] as? [[String: Any]])
                ?? []
        } else {
            rawItems = []
        }

        struct RawRecognitionItem {
            let text: String
            let classification: String
            let order: Int
            let textRect: CGRect?
            let bubbleRect: CGRect?
            let layoutSafeRect: CGRect?
            let textPolygon: [CGPoint]
            let bubblePolygon: [CGPoint]
            let confidence: Double
        }

        let ignoredClassifications: Set<String> = [
            "url", "advertisement", "advertising", "ad", "watermark",
            "copyright", "pagenumber", "page_number", "page-number"
        ]
        let parsed = rawItems.compactMap { item -> RawRecognitionItem? in
            let text = firstString(
                in: item,
                keys: ["sourceText", "source_text", "text", "original", "originalText"]
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let classification = firstString(
                in: item,
                keys: ["classification", "type", "category"]
            ).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let compactClassification = classification.replacingOccurrences(of: " ", with: "")
            guard !ignoredClassifications.contains(compactClassification),
                  !looksLikeNonContentText(text) else {
                MReaderLog.aiVision.debug("vision recognition filtered type=\(classification, privacy: .public) characters=\(text.count, privacy: .public)")
                MReaderLog.content("vision recognition filtered text=\(text.prefix(80))", logger: MReaderLog.aiVision)
                return nil
            }
            return RawRecognitionItem(
                text: text,
                classification: classification.isEmpty ? "dialogue" : classification,
                order: doubleValue(from: item["order"]).map(Int.init) ?? Int.max,
                textRect: rectValue(from: item["textBox"] ?? item["text_box"]),
                bubbleRect: rectValue(from: item["bubbleBox"] ?? item["bubble_box"]),
                layoutSafeRect: rectValue(from: item["layoutSafeRegion"] ?? item["layout_safe_region"]),
                textPolygon: pointsValue(from: item["textPolygon"] ?? item["text_polygon"]) ?? [],
                bubblePolygon: pointsValue(from: item["bubblePolygon"] ?? item["bubble_polygon"]) ?? [],
                confidence: doubleValue(from: item["confidence"]) ?? 0.75
            )
        }

        let allRects = parsed.flatMap { [$0.textRect, $0.bubbleRect, $0.layoutSafeRect].compactMap { $0 } }
        let allPolygons = parsed.flatMap { [$0.textPolygon, $0.bubblePolygon] }
        // 同 parseVisionTranslationBlocks：只接受显式 normalized 0...1 坐标，无标记或超范围即整条拒绝。
        if !allRects.isEmpty || !allPolygons.isEmpty {
            guard visionCoordinateSpaceIsNormalized(json, rects: allRects, polygons: allPolygons) else {
                throw VisionTranslationError.invalidCoordinates
            }
        }
        let coordinateDivisor = CGSize(width: 1, height: 1)

        let recognized: [(order: Int, block: TextBlock)] = parsed.compactMap { item in
            let normalizedTextRect = item.textRect.map {
                normalizeVisionRect($0, divisor: coordinateDivisor)
            }
            let normalizedBubbleRect = item.bubbleRect.map {
                normalizeVisionRect($0, divisor: coordinateDivisor)
            }
            let validTextRect = normalizedTextRect.flatMap { rect -> CGRect? in
                let mapped = mapVisionRect(rect, from: sourceRect)
                return isUsableVisionRect(mapped) ? mapped : nil
            }
            let validBubbleRect = normalizedBubbleRect.flatMap { rect -> CGRect? in
                let mapped = mapVisionRect(rect, from: sourceRect)
                return isUsableVisionRect(mapped) ? mapped : nil
            }
            let validLayoutSafeRect = item.layoutSafeRect
                .map { normalizeVisionRect($0, divisor: coordinateDivisor) }
                .map { mapVisionRect($0, from: sourceRect) }
                .flatMap { isUsableVisionRect($0) ? $0 : nil }
            guard let mappedRect = validTextRect ?? validBubbleRect.map({
                expandedVisionTextRect($0, within: sourceRect)
            }) else {
                return nil
            }
            let fallbackGeometry = visionFallbackGeometry(
                for: item.text,
                textBox: mappedRect,
                sourceRect: sourceRect,
                inputPixelSize: inputPixelSize
            )
            let mappedTextPolygon = item.textPolygon.map { point in
                CGPoint(
                    x: sourceRect.minX + (point.x / coordinateDivisor.width) * sourceRect.width,
                    y: sourceRect.minY + (point.y / coordinateDivisor.height) * sourceRect.height
                )
            }
            let mappedBubblePolygon = item.bubblePolygon.map { point in
                CGPoint(
                    x: sourceRect.minX + (point.x / coordinateDivisor.width) * sourceRect.width,
                    y: sourceRect.minY + (point.y / coordinateDivisor.height) * sourceRect.height
                )
            }
            return (
                order: item.order,
                block: TextBlock(
                    text: item.text,
                    boundingBox: mappedRect,
                    confidence: item.confidence,
                    ocrSource: "vision-recognition:\(item.classification)",
                    estimatedFontScale: fallbackGeometry.fontScale,
                    bubbleBox: validBubbleRect,
                    layoutSafeRegion: validLayoutSafeRect ?? validBubbleRect ?? mappedRect,
                    polygon: mappedTextPolygon,
                    bubblePolygon: mappedBubblePolygon,
                    textOrientation: fallbackGeometry.orientation,
                    layoutRole: TranslationLayoutRole.fromClassification(item.classification)
                )
            )
        }
        return recognized.sorted { lhs, rhs in
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return lhs.block.boundingBox.minY < rhs.block.boundingBox.minY
        }.map(\.block)
    }

    static func parseVisionRecognitionBlocksForDiagnostics(
        from content: String,
        sourceRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
        inputPixelSize: CGSize,
        isRightToLeft: Bool = false
    ) throws -> [TextBlock] {
        try parseVisionRecognitionBlocks(
            from: content,
            sourceRect: sourceRect,
            inputPixelSize: inputPixelSize,
            isRightToLeft: isRightToLeft
        )
    }

    private static func expandedVisionTextRect(_ rect: CGRect, within bounds: CGRect) -> CGRect {
        let horizontalPadding = max(rect.width * 0.12, 0.008)
        let verticalPadding = max(rect.height * 0.2, 0.006)
        return rect
            .insetBy(dx: -horizontalPadding, dy: -verticalPadding)
            .intersection(bounds)
    }

    private static func looksLikeNonContentText(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        if lowercased.contains("http://") || lowercased.contains("https://")
            || lowercased.contains("www.") || lowercased.contains("@") {
            return true
        }
        let compact = lowercased.replacingOccurrences(of: " ", with: "")
        return compact.hasSuffix(".com") || compact.hasSuffix(".net") || compact.hasSuffix(".org")
    }

    static func parseVisionTranslationBlocksForDiagnostics(
        from content: String,
        sourceRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
        inputPixelSize: CGSize,
        requiresTextBox: Bool = false,
        target: TranslationTargetLanguage? = nil
    ) throws -> [TextBlock] {
        try parseVisionTranslationBlocks(
            from: content,
            sourceRect: sourceRect,
            inputPixelSize: inputPixelSize,
            requiresTextBox: requiresTextBox,
            target: target
        )
    }

    private static func extractedJSONPayload(from content: String) -> String {
        var trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        for tag in ["think", "thinking", "analysis", "reasoning"] {
            trimmed = trimmed.replacingOccurrences(
                of: "<\(tag)(?:\\s[^>]*)?>[\\s\\S]*?</\(tag)>",
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        if trimmed.range(
            of: #"</?(?:think|thinking|analysis|reasoning)(?:\s[^>]*)?>"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return ""
        }
        if let start = trimmed.range(of: #"```(?:json)?"#, options: [.regularExpression, .caseInsensitive]),
           let end = trimmed.range(of: "```", range: start.upperBound..<trimmed.endIndex) {
            return String(trimmed[start.upperBound..<end.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let start = trimmed.firstIndex(where: { $0 == "{" || $0 == "[" }),
           let end = trimmed.lastIndex(where: { $0 == "}" || $0 == "]" }) {
            return String(trimmed[start...end])
        }
        return trimmed
    }

    private static func normalizedVisionJSONData(from content: String) -> Data? {
        let payload = extractedJSONPayload(from: content)
        if let data = payload.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil {
            return data
        }
        if let quotedData = payload.data(using: .utf8),
           let nested = try? JSONSerialization.jsonObject(with: quotedData, options: [.fragmentsAllowed]) as? String,
           let nestedData = nested.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: nestedData, options: [.fragmentsAllowed])) != nil {
            return nestedData
        }
        let repaired = escapeControlCharactersInsideJSONString(payload)
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(
                of: #",\s*([}\]])"#,
                with: "$1",
                options: .regularExpression
            )
        guard let data = repaired.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else {
            return nil
        }
        return data
    }

    private static func escapeControlCharactersInsideJSONString(_ input: String) -> String {
        var result = ""
        var isInsideString = false
        var isEscaped = false

        for character in input {
            if isEscaped {
                result.append(character)
                isEscaped = false
                continue
            }
            if character == "\\" && isInsideString {
                result.append(character)
                isEscaped = true
                continue
            }
            if character == "\"" {
                isInsideString.toggle()
                result.append(character)
                continue
            }
            if isInsideString {
                switch character {
                case "\n":
                    result.append("\\n")
                case "\r":
                    result.append("\\r")
                case "\t":
                    result.append("\\t")
                default:
                    result.append(character)
                }
            } else {
                result.append(character)
            }
        }
        return result
    }

    private static func firstString(in item: [String: Any], keys: [String]) -> String {
        for key in keys {
            if let value = item[key] as? String {
                return value
            }
        }
        return ""
    }

    private static func rectValue(from value: Any?) -> CGRect? {
        if let dictionary = value as? [String: Any] {
            if let x = doubleValue(from: dictionary["x"] ?? dictionary["left"]),
               let y = doubleValue(from: dictionary["y"] ?? dictionary["top"]),
               let width = doubleValue(from: dictionary["width"] ?? dictionary["w"]),
               let height = doubleValue(from: dictionary["height"] ?? dictionary["h"]) {
                return CGRect(x: x, y: y, width: width, height: height)
            }
            if let x1 = doubleValue(from: dictionary["x1"] ?? dictionary["left"]),
               let y1 = doubleValue(from: dictionary["y1"] ?? dictionary["top"]),
               let x2 = doubleValue(from: dictionary["x2"] ?? dictionary["right"]),
               let y2 = doubleValue(from: dictionary["y2"] ?? dictionary["bottom"]) {
                return CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
            }
            return nil
        }
        if let array = value as? [Any], array.count >= 4,
           let x = doubleValue(from: array[0]),
           let y = doubleValue(from: array[1]),
           let width = doubleValue(from: array[2]),
           let height = doubleValue(from: array[3]) {
            return CGRect(x: x, y: y, width: width, height: height)
        }
        return nil
    }

    private static func pointsValue(from value: Any?) -> [CGPoint]? {
        let points: [CGPoint]
        if let values = value as? [[String: Any]] {
            points = values.compactMap { item -> CGPoint? in
                guard let x = doubleValue(from: item["x"]),
                      let y = doubleValue(from: item["y"]) else { return nil }
                return CGPoint(x: x, y: y)
            }
        } else if let values = value as? [[Any]] {
            points = values.compactMap { item -> CGPoint? in
                guard item.count >= 2,
                      let x = doubleValue(from: item[0]),
                      let y = doubleValue(from: item[1]) else { return nil }
                return CGPoint(x: x, y: y)
            }
        } else {
            return nil
        }
        return points.count >= 4 ? points : nil
    }

    private static func boundingRect(for points: [CGPoint]) -> CGRect? {
        guard let first = points.first else { return nil }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { rect, point in
            rect.union(CGRect(origin: point, size: .zero))
        }
    }

    private static func doubleValue(from value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func pixelSize(of image: UIImage) -> CGSize {
        CGSize(
            width: image.cgImage?.width ?? Int(image.size.width * image.scale),
            height: image.cgImage?.height ?? Int(image.size.height * image.scale)
        )
    }

    /// 校验视觉响应是否遵循“显式 normalized 0...1 坐标”协议。
    /// 要求 JSON 顶层声明 coordinateSpace: "normalized"（或等价明确标记），且所有矩形/多边形坐标都在 0...1 内。
    /// 无显式标记、坐标超范围或未按对象形式返回，都视为不合规；调用方应整条拒绝该响应，不再自动猜测像素/百分比/0~1000 基准。
    private static func visionCoordinateSpaceIsNormalized(
        _ json: Any,
        rects: [CGRect],
        polygons: [[CGPoint]]
    ) -> Bool {
        guard let object = json as? [String: Any] else { return false }
        let marker = firstString(
            in: object,
            keys: ["coordinateSpace", "coordinate_space", "coordinateSystem", "coordinate_system"]
        ).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !marker.isEmpty else { return false }
        let acceptedMarkers: Set<String> = [
            "normalized", "0-1", "0..1", "0.0-1.0", "relative", "归一化"
        ]
        guard acceptedMarkers.contains(marker) else { return false }

        func isNormalizedValue(_ value: CGFloat) -> Bool {
            value.isFinite && value >= 0 && value <= 1.000_001
        }
        for rect in rects {
            guard isNormalizedValue(rect.minX),
                  isNormalizedValue(rect.minY),
                  isNormalizedValue(rect.width),
                  isNormalizedValue(rect.height),
                  isNormalizedValue(rect.maxX),
                  isNormalizedValue(rect.maxY) else {
                return false
            }
        }
        for polygon in polygons {
            for point in polygon {
                guard isNormalizedValue(point.x), isNormalizedValue(point.y) else {
                    return false
                }
            }
        }
        return true
    }

    private struct VisionFallbackGeometry {
        let fontScale: Double
        let orientation: TextOrientation
    }

    /// 当本地 OCR 没有匹配到 Vision item 时，在输入图像的物理像素轴上估算字符格，
    /// 再转换回对应的 normalized 页面轴；不能直接对 normalized width/height 求平方根。
    private static func visionFallbackGeometry(
        for text: String,
        textBox: CGRect,
        sourceRect: CGRect,
        inputPixelSize: CGSize
    ) -> VisionFallbackGeometry {
        let visibleCharacterCount = max(
            text.unicodeScalars.filter { scalar in
                !CharacterSet.whitespacesAndNewlines.contains(scalar)
            }.count,
            1
        )
        let pagePixelWidth = Double(max(inputPixelSize.width, 1)) / Double(max(sourceRect.width, 0.000_1))
        let pagePixelHeight = Double(max(inputPixelSize.height, 1)) / Double(max(sourceRect.height, 0.000_1))
        let physicalWidth = Double(max(textBox.width, 0)) * pagePixelWidth
        let physicalHeight = Double(max(textBox.height, 0)) * pagePixelHeight
        let orientation: TextOrientation = physicalWidth >= physicalHeight ? .horizontal : .vertical
        let physicalCharacterCell = sqrt(
            max(physicalWidth * physicalHeight, 1) / Double(visibleCharacterCount)
        )
        let axisPixels = orientation == .horizontal ? pagePixelHeight : pagePixelWidth
        let normalizedAxis = orientation == .horizontal ? Double(textBox.height) : Double(textBox.width)
        let normalizedScale = physicalCharacterCell / max(axisPixels, 1)
        let lowerBound = min(normalizedAxis * 0.12, 0.001)
        let scale = normalizedAxis > 0
            ? max(min(normalizedScale, normalizedAxis), lowerBound)
            : 0.001
        return VisionFallbackGeometry(fontScale: scale, orientation: orientation)
    }

    private static func normalizeVisionRect(_ rect: CGRect, divisor: CGSize) -> CGRect {
        CGRect(
            x: rect.minX / divisor.width,
            y: rect.minY / divisor.height,
            width: rect.width / divisor.width,
            height: rect.height / divisor.height
        )
    }

    static func normalizedVisionRectForDiagnostics(
        _ rect: CGRect,
        inputPixelSize: CGSize
    ) -> CGRect {
        // 新协议只接受 0...1 归一化坐标，不再根据数值大小猜测基准。
        rect
    }

    private static func mapVisionRect(_ rect: CGRect, from sourceRect: CGRect) -> CGRect {
        let x = sourceRect.minX + rect.minX * sourceRect.width
        let y = sourceRect.minY + rect.minY * sourceRect.height
        let width = rect.width * sourceRect.width
        let height = rect.height * sourceRect.height
        return CGRect(
            x: min(max(x, 0), 1),
            y: min(max(y, 0), 1),
            width: min(max(width, 0), 1),
            height: min(max(height, 0), 1)
        )
    }

    private static func isUsableVisionRect(_ rect: CGRect) -> Bool {
        rect.width >= 0.006 &&
        rect.height >= 0.006 &&
        rect.minX >= 0 &&
        rect.minY >= 0 &&
        rect.maxX <= 1.02 &&
        rect.maxY <= 1.02
    }

    nonisolated static func annotatedMangaTextBlocks(_ blocks: [TextBlock], safeAreaInset: Double, minimumTextHeight: Double, isRightToLeft: Bool) -> [TextBlock] {
        let inset = min(max(CGFloat(safeAreaInset), 0), 0.3)
        let minimumHeight = min(max(CGFloat(minimumTextHeight), 0.002), 0.05)
        let minimumArea = minimumHeight * 0.0048
        let safeRect = CGRect(x: inset, y: inset, width: max(0, 1 - inset * 2), height: max(0, 1 - inset * 2))

        return sortedTextBlocks(blocks.map { block in
            var annotated = block
            let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                annotated.isFiltered = true
                annotated.filterReason = "空文本"
                return annotated
            }
            if !safeRect.contains(CGPoint(x: block.boundingBox.midX, y: block.boundingBox.midY)) {
                annotated.isFiltered = true
                annotated.filterReason = "安全区外"
                MReaderLog.aiVision.debug("OCR filter reason=safe-area box=\(String(describing: block.boundingBox), privacy: .public)")
                MReaderLog.content("OCR filter text=\(text) reason=safe-area", logger: MReaderLog.aiVision)
                return annotated
            }
            if let noiseReason = edgeNoiseReason(text) {
                annotated.isFiltered = true
                annotated.filterReason = noiseReason
                MReaderLog.aiVision.debug("OCR filter reason=\(noiseReason, privacy: .public)")
                MReaderLog.content("OCR filter text=\(text) reason=\(noiseReason)", logger: MReaderLog.aiVision)
                return annotated
            }

            let height = block.boundingBox.height
            let area = block.boundingBox.width * block.boundingBox.height
            if text.count <= 2 && height < minimumHeight * 1.55 {
                annotated.isFiltered = true
                annotated.filterReason = "短文本过小"
                MReaderLog.aiVision.debug("OCR filter reason=short-text-too-small height=\(height, privacy: .public)")
                MReaderLog.content("OCR filter text=\(text) reason=short-text-too-small", logger: MReaderLog.aiVision)
                return annotated
            }
            if height < minimumHeight || area < minimumArea {
                annotated.isFiltered = true
                annotated.filterReason = "字号/面积过小"
                MReaderLog.aiVision.debug("OCR filter reason=font-or-area-too-small height=\(height, privacy: .public) area=\(area, privacy: .public)")
                MReaderLog.content("OCR filter text=\(text) reason=font-or-area-too-small", logger: MReaderLog.aiVision)
                return annotated
            }
            annotated.isFiltered = false
            annotated.filterReason = nil
            return annotated
        }, isRightToLeft: isRightToLeft)
    }

    nonisolated static func filteredMangaTextBlocks(_ blocks: [TextBlock], safeAreaInset: Double, minimumTextHeight: Double, isRightToLeft: Bool) -> [TextBlock] {
        annotatedMangaTextBlocks(blocks, safeAreaInset: safeAreaInset, minimumTextHeight: minimumTextHeight, isRightToLeft: isRightToLeft)
            .filter { !$0.isFiltered }
    }

    nonisolated static func groupedMangaTextBlocks(_ blocks: [TextBlock], isRightToLeft: Bool) -> [TextBlock] {
        MangaTextSegmenter.segment(blocks, isRightToLeft: isRightToLeft).bubbles
    }

    nonisolated static func deduplicatedMangaTextBlocks(_ blocks: [TextBlock], isRightToLeft: Bool) -> [TextBlock] {
        OCRCandidateResolver.resolve(blocks, isRightToLeft: isRightToLeft).resolvedBlocks
    }

    nonisolated private static func edgeNoiseReason(_ text: String) -> String? {
        let lowercased = text.lowercased()
        let noiseFragments = ["http://", "https://", "www.", ".com", ".net", ".org"]
        if noiseFragments.contains(where: { lowercased.contains($0) }) {
            return "网址"
        }
        if lowercased.contains("copyright") || lowercased.contains("©") {
            return "版权水印"
        }
        if lowercased == "sample" || lowercased.contains("sample") && text.count < 20 {
            return "样张水印"
        }
        return nil
    }

    nonisolated static func sortedTextBlocks(_ blocks: [TextBlock], isRightToLeft: Bool) -> [TextBlock] {
        let validBlocks = blocks.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard validBlocks.count > 1 else { return validBlocks }

        let verticalCount = validBlocks.filter { block in
            block.boundingBox.height > block.boundingBox.width * 1.35
        }.count
        let isMostlyVertical = verticalCount > validBlocks.count / 2
        let fontScales = validBlocks
            .map { min($0.boundingBox.width, $0.boundingBox.height) }
            .sorted()
        let medianFontScale = fontScales[fontScales.count / 2]

        func stableTieBreak(_ lhs: TextBlock, _ rhs: TextBlock) -> Bool {
            lhs.id.uuidString < rhs.id.uuidString
        }

        if isMostlyVertical {
            let columnThreshold = min(max(medianFontScale * 1.1, 0.02), 0.045)
            let byColumn = validBlocks.sorted { lhs, rhs in
                if lhs.boundingBox.midX != rhs.boundingBox.midX {
                    return isRightToLeft
                        ? lhs.boundingBox.midX > rhs.boundingBox.midX
                        : lhs.boundingBox.midX < rhs.boundingBox.midX
                }
                if lhs.boundingBox.midY != rhs.boundingBox.midY {
                    return lhs.boundingBox.midY < rhs.boundingBox.midY
                }
                return stableTieBreak(lhs, rhs)
            }
            var columns: [[TextBlock]] = []
            for block in byColumn {
                if let index = columns.indices.last,
                   let anchor = columns[index].first,
                   abs(block.boundingBox.midX - anchor.boundingBox.midX) <= columnThreshold {
                    columns[index].append(block)
                } else {
                    columns.append([block])
                }
            }
            return columns.flatMap { column in
                column.sorted { lhs, rhs in
                    if lhs.boundingBox.midY != rhs.boundingBox.midY {
                        return lhs.boundingBox.midY < rhs.boundingBox.midY
                    }
                    if lhs.boundingBox.midX != rhs.boundingBox.midX {
                        return isRightToLeft
                            ? lhs.boundingBox.midX > rhs.boundingBox.midX
                            : lhs.boundingBox.midX < rhs.boundingBox.midX
                    }
                    return stableTieBreak(lhs, rhs)
                }
            }
        }

        let rowThreshold = min(max(medianFontScale * 0.75, 0.006), 0.035)
        let byRow = validBlocks.sorted { lhs, rhs in
            if lhs.boundingBox.midY != rhs.boundingBox.midY {
                return lhs.boundingBox.midY < rhs.boundingBox.midY
            }
            if lhs.boundingBox.midX != rhs.boundingBox.midX {
                return isRightToLeft
                    ? lhs.boundingBox.midX > rhs.boundingBox.midX
                    : lhs.boundingBox.midX < rhs.boundingBox.midX
            }
            return stableTieBreak(lhs, rhs)
        }
        var rows: [[TextBlock]] = []
        for block in byRow {
            if let index = rows.indices.last,
               let anchor = rows[index].first,
               abs(block.boundingBox.midY - anchor.boundingBox.midY) <= rowThreshold {
                rows[index].append(block)
            } else {
                rows.append([block])
            }
        }
        return rows.flatMap { row in
            row.sorted { lhs, rhs in
                if lhs.boundingBox.midX != rhs.boundingBox.midX {
                    return isRightToLeft
                        ? lhs.boundingBox.midX > rhs.boundingBox.midX
                        : lhs.boundingBox.midX < rhs.boundingBox.midX
                }
                if lhs.boundingBox.midY != rhs.boundingBox.midY {
                    return lhs.boundingBox.midY < rhs.boundingBox.midY
                }
                return stableTieBreak(lhs, rhs)
            }
        }
    }
}
