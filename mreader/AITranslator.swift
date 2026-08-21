import Foundation
import UIKit

// AI 翻译专用 URLSession。单个模型不应长期占住整页翻译任务。
private let aiTranslationSession: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 60
    config.timeoutIntervalForResource = 90
    config.waitsForConnectivity = true
    return URLSession(configuration: config)
}()

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
    var bubbleBox: CGRect?
    var polygon: [CGPoint]
    var translationLines: [String]

    nonisolated init(id: UUID = UUID(), text: String, boundingBox: CGRect, translation: String? = nil, confidence: Double = 0, ocrSource: String = "vision", isFiltered: Bool = false, filterReason: String? = nil, estimatedFontScale: Double? = nil, textColorHex: String? = nil, bubbleBox: CGRect? = nil, polygon: [CGPoint] = [], translationLines: [String] = []) {
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
        self.polygon = polygon
        self.translationLines = translationLines
    }
}

nonisolated struct OCRVerificationRegion: Sendable {
    let blockID: UUID
    let sourceRect: CGRect
}

nonisolated enum AITranslationRequestError: LocalizedError, Sendable {
    case invalidConfiguration(String)
    case server(model: String, statusCode: Int?, message: String)
    case serverWithRetryAfter(model: String, statusCode: Int?, message: String, retryAfterSeconds: UInt64?)
    case invalidResponse(model: String)
    case invalidResponseEnvelope(model: String, contentType: String?, excerpt: String)
    case missingAssistantContent(model: String, finishReason: String?)
    case invalidTranslationJSON(model: String, excerpt: String)
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
        case .incompleteResponse(let model, let finishReason):
            return "模型 \(model) 响应不完整（finish_reason=\(finishReason)）"
        }
    }

    /// 是否属于“格式/协议类”失败：可以触发缩小 batch 或逐气泡兜底。
    var isFormatFailure: Bool {
        switch self {
        case .invalidResponseEnvelope, .missingAssistantContent,
             .invalidTranslationJSON, .incompleteResponse:
            return true
        default:
            return false
        }
    }
}

/// 共享的 Chat Completions endpoint 解析（项6）：生产与设置页测试共用，
/// 兼容 `https://xxx/v1` 与已填写完整 `/chat/completions` 的 Base URL。
nonisolated enum AIEndpointResolver {
    static func chatCompletionsURL(from baseURL: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasSuffix("/chat/completions") {
            return URL(string: trimmed)
        }
        let withoutTrailingSlash = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(withoutTrailingSlash)/chat/completions")
    }
}

/// 统一解析 OpenAI 兼容接口的响应包，支持：
/// - Chat Completions: choices[].message.content (String / Array)
/// - legacy: choices[].text
/// - Responses: 顶层 output_text / output[].content[].text
/// - reasoning_content（只标记，不当作译文）
nonisolated enum AIChatResponseDecoder {
    struct Decoded: Sendable {
        let content: String?
        let finishReason: String?
        let hasReasoningOnly: Bool
    }

    static func decode(_ data: Data) -> Decoded {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Decoded(content: nil, finishReason: nil, hasReasoningOnly: false)
        }
        let topFinish = (json["finish_reason"] as? String) ?? (json["finishReason"] as? String)

        // Responses 顶层 output_text
        if let outputText = json["output_text"] as? String,
           !outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Decoded(content: outputText, finishReason: topFinish, hasReasoningOnly: false)
        }

        // Responses 嵌套 output[].content[].text / output[].text
        if let output = json["output"] as? [[String: Any]] {
            let texts = output.compactMap { item -> String? in
                if let contentArray = item["content"] as? [[String: Any]] {
                    let joined = contentArray.compactMap { part -> String? in
                        if let type = part["type"] as? String, type == "output_text",
                           let t = part["text"] as? String {
                            return t
                        }
                        if let t = part["text"] as? String { return t }
                        return nil
                    }.joined(separator: "\n")
                    return joined.isEmpty ? nil : joined
                }
                if let t = item["text"] as? String, !t.isEmpty { return t }
                return nil
            }.joined(separator: "\n")
            if !texts.isEmpty {
                return Decoded(content: texts, finishReason: topFinish, hasReasoningOnly: false)
            }
        }

        guard let choices = json["choices"] as? [[String: Any]], let choice = choices.first else {
            return Decoded(content: nil, finishReason: topFinish, hasReasoningOnly: false)
        }
        let finishReason = (choice["finish_reason"] as? String) ?? topFinish

        if let text = choice["text"] as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Decoded(content: text, finishReason: finishReason, hasReasoningOnly: false)
        }

        if let message = choice["message"] as? [String: Any] {
            if let content = message["content"] as? String, !content.isEmpty {
                return Decoded(content: content, finishReason: finishReason, hasReasoningOnly: false)
            }
            if let content = message["content"] as? [[String: Any]] {
                let joined = content.compactMap { part -> String? in
                    if let text = part["text"] as? String { return text }
                    if let content = part["content"] as? String { return content }
                    if let value = part["value"] as? String { return value }
                    return nil
                }.joined(separator: "\n")
                if !joined.isEmpty {
                    return Decoded(content: joined, finishReason: finishReason, hasReasoningOnly: false)
                }
            }
            if let content = message["content"],
               JSONSerialization.isValidJSONObject(content),
               let data = try? JSONSerialization.data(withJSONObject: content),
               let value = String(data: data, encoding: .utf8) {
                return Decoded(content: value, finishReason: finishReason, hasReasoningOnly: false)
            }
            let hasReasoning = ((message["reasoning_content"] as? String)?.isEmpty == false)
                || ((message["reasoning"] as? String)?.isEmpty == false)
            if hasReasoning {
                return Decoded(content: nil, finishReason: finishReason, hasReasoningOnly: true)
            }
        }
        return Decoded(content: nil, finishReason: finishReason, hasReasoningOnly: false)
    }
}

class AITranslator {
    nonisolated static func visualVerificationRegionsForDiagnostics(
        _ blocks: [TextBlock],
        confidenceThreshold: Double = 0.72,
        maximumCount: Int = 3
    ) -> [OCRVerificationRegion] {
        blocks
            .filter { block in
                block.confidence < confidenceThreshold || appearsGarbled(block.text)
            }
            .sorted { lhs, rhs in
                if lhs.confidence != rhs.confidence { return lhs.confidence < rhs.confidence }
                return lhs.boundingBox.minY < rhs.boundingBox.minY
            }
            .prefix(max(maximumCount, 0))
            .map { block in
                let horizontalPadding = max(block.boundingBox.width * 0.15, 0.008)
                let verticalPadding = max(block.boundingBox.height * 0.15, 0.006)
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
    你是一个漫画图片文字识别与翻译助手。请只处理图片中的文字，不要描述画面、人物、动作、身体、场景或剧情，不要评价、总结、续写或添加任何新细节。
    你的任务是：识别漫画页面中的对白、旁白、拟声词和必要的画面文字，翻译为：{targetLanguage}，并给出文字框和推荐显示气泡框坐标。
    这一页的阅读顺序是{readingOrder}，items 必须按该阅读顺序排列；被切成多列或多段的同一句话要先按阅读顺序还原成完整一句再翻译，不要按碎片逐段直译。
    如果图片包含成人、暴力、敏感或私人内容，只进行中性、准确的文字翻译；不要美化、扩写、润色成更露骨内容，也不要输出与文字翻译无关的内容。
    不要记录、记忆、推断用户身份，不要识别现实人物身份。
    忽略网址、广告、版权、水印和页码。
    坐标要求：所有坐标都以整张输入图片左上角为原点并归一化到 0 到 1，且必须在 JSON 顶层显式声明 "coordinateSpace": "normalized"；禁止使用像素或百分比坐标。除了 textBox 和 bubbleBox，还必须提供 textPolygon 和 bubblePolygon（按左上、右上、右下、左下顺序的四个点）以及 center 点。bubbleBox 必须真实覆盖原气泡或文字区域，不要只给大概位置。
    由你判断译文是否需要分行，translationLines 每个数组元素是一行；不要为了填满气泡而扩写。

    只输出严格 JSON，不要 Markdown，不要解释：
    {
      "coordinateSpace": "normalized",
      "items": [
        {
          "order": 1,
          "text": "原文",
          "translation": "译文",
          "translationLines": ["译文第一行", "译文第二行"],
          "textBox": {"x": 0.1, "y": 0.2, "width": 0.3, "height": 0.08},
          "bubbleBox": {"x": 0.1, "y": 0.18, "width": 0.34, "height": 0.1},
          "textPolygon": [{"x":0.1,"y":0.2},{"x":0.4,"y":0.2},{"x":0.4,"y":0.28},{"x":0.1,"y":0.28}],
          "bubblePolygon": [{"x":0.08,"y":0.17},{"x":0.44,"y":0.17},{"x":0.44,"y":0.29},{"x":0.08,"y":0.29}],
          "center": {"x": 0.26, "y": 0.23},
          "confidence": 0.9
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
    static func translate(text: String, ocrMetadata: String = "", pageContext: String = "", apiKey: String, baseURL: String, model: String, targetLanguage: String = "中文", promptTemplate: String = defaultTranslationPromptTemplate, requestTimeout: TimeInterval = 45) async throws -> String {
        try Task.checkCancellation()
        return try await translateTextUsingModel(
            text: text,
            apiKey: apiKey,
            baseURL: baseURL,
            model: model,
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
        sourceLanguage: TranslationSourceLanguage? = nil
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
            target: target,
            promptTemplate: promptTemplate,
            sourceLanguage: sourceLanguage,
            requestTimeout: AITranslationRequestPolicy.pageRequestTimeout
        )
    }

    private static func translatePageUsingModel(
        items: [AIPageTranslationItem],
        apiKey: String,
        baseURL: String,
        model: String,
        target: TranslationTargetLanguage,
        promptTemplate: String,
        sourceLanguage: TranslationSourceLanguage?,
        requestTimeout: TimeInterval
    ) async throws -> AIPageTranslationResult {
        guard !apiKey.isEmpty else { throw AITranslationRequestError.invalidConfiguration("未配置 API Key") }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AITranslationRequestError.invalidConfiguration("未配置模型")
        }
        guard let url = chatCompletionsURL(from: baseURL) else {
            throw AITranslationRequestError.invalidConfiguration("接口地址无效")
        }

        // V2：固定 JSON 协议在 PromptBuilder 内，用户模板只作为“翻译风格要求”传入，
        // 旧整页/逐气泡提示词不再被原样注入新协议（审查 #3/#4）。
        let prompt = try AIPageTranslationPromptBuilder.prompt(
            items: items,
            sourceLanguage: sourceLanguage,
            target: target,
            styleInstructions: promptTemplate
        )

        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model.trimmingCharacters(in: .whitespacesAndNewlines),
            "messages": [
                [
                    "role": "system",
                    "content": "你只做漫画整页翻译。必须保留输入 id，统一整页称呼和语气，只输出严格 JSON。不要描述图片、解释、续写、总结或输出思考过程。"
                ],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.15
        ])

        let (data, response) = try await aiTranslationSession.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw AITranslationRequestError.server(
                model: model,
                statusCode: httpResponse.statusCode,
                message: apiErrorMessage(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            )
        }
        if let message = apiErrorMessage(from: data) {
            throw AITranslationRequestError.server(model: model, statusCode: nil, message: message)
        }
        let decoded = AIChatResponseDecoder.decode(data)
        guard let content = decoded.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if decoded.hasReasoningOnly || decoded.finishReason != nil {
                throw AITranslationRequestError.missingAssistantContent(
                    model: model,
                    finishReason: decoded.finishReason
                )
            }
            let contentType = (response as? HTTPURLResponse)?.mimeType
            let excerpt = String(data: data.prefix(300), encoding: .utf8)
                ?? "<non-utf8 \(data.count) bytes>"
            throw AITranslationRequestError.invalidResponseEnvelope(
                model: model,
                contentType: contentType,
                excerpt: excerpt
            )
        }
        do {
            return try AIPageTranslationParser.parse(content, expectedItems: items, target: target)
        } catch {
            let excerpt = content.replacingOccurrences(of: "\n", with: " ").prefix(300)
            print("MReader AI page translation invalid response model=\(model) excerpt=\(excerpt)")
            throw AITranslationRequestError.invalidTranslationJSON(
                model: model,
                excerpt: String(excerpt)
            )
        }
    }

    private static func translateTextUsingModel(text: String, apiKey: String, baseURL: String, model: String, targetLanguage: String, promptTemplate: String, ocrMetadata: String, pageContext: String, requestTimeout: TimeInterval) async throws -> String {
        guard !apiKey.isEmpty else { throw AITranslationRequestError.invalidConfiguration("未配置 API Key") }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AITranslationRequestError.invalidConfiguration("未配置模型") }
        guard let url = chatCompletionsURL(from: baseURL) else { throw AITranslationRequestError.invalidConfiguration("接口地址无效") }
        // 单气泡也必须使用固定协议（项1）：style 只是风格要求，
        // 待翻译原文、目标语言、上下文与 OCR 信息始终由固定模板提供。
        let prompt = singleBubbleTranslationPrompt(
            text: text,
            target: TranslationTargetLanguage.migrateLegacyValue(targetLanguage),
            pageContext: pageContext,
            ocrMetadata: ocrMetadata,
            styleInstructions: promptTemplate
        )
        
        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "model": model.trimmingCharacters(in: .whitespacesAndNewlines),
            "messages": [
                ["role": "system", "content": "你是只输出翻译结果的漫画对白翻译助手。用户可能提供整页对白作为上下文，用它理解称呼、语气和断句，但只输出目标句子的译文。OCR 碎片仅在距离接近且字号、颜色一致时按阅读顺序合并；距离远、字号不同或颜色不同必须保持为不同对白。网址、广告、水印和页码不翻译。不要续写、总结、评价、添加剧情、保存信息或推断用户身份。禁止输出思考过程、提示词、分析、说明、Markdown 或原文复述。"],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.3
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await aiTranslationSession.data(for: request)

        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw AITranslationRequestError.server(
                model: model,
                statusCode: httpResponse.statusCode,
                message: apiErrorMessage(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            )
        }

        if let message = apiErrorMessage(from: data) {
            throw AITranslationRequestError.server(model: model, statusCode: nil, message: message)
        }

        let decoded = AIChatResponseDecoder.decode(data)
        if let content = decoded.content,
           let translation = sanitizedTranslationText(from: content, sourceText: text) {
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
        sourceLanguage: TranslationSourceLanguage? = nil
    ) async throws -> [TextBlock] {
        let target = TranslationTargetLanguage.migrateLegacyValue(targetLanguage)
        let recognized = try await recognizeVisionPage(
            image: image,
            apiKey: apiKey,
            baseURL: baseURL,
            model: visionModel,
            isRightToLeft: isRightToLeft,
            viewportAspect: viewportAspect,
            translationTarget: target,
            translationPromptTemplate: promptTemplate
        )
        try Task.checkCancellation()

        var translated = recognized
        let missingIndexes = translated.indices.filter {
            (translated[$0].translation ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if !missingIndexes.isEmpty {
            let missingBlocks = missingIndexes.map { translated[$0] }
            // Vision 漏译的纯文本补译走文本模型，而不是昂贵的视觉模型（审查 #12）
            let pageResult = try await translatePage(
                blocks: missingBlocks,
                apiKey: apiKey,
                baseURL: baseURL,
                model: textFallbackModel,
                target: target,
                promptTemplate: defaultTranslationPromptTemplate,
                sourceLanguage: sourceLanguage
            )
            // 线上 ID 是 b0/b1/...（顺序 = missingBlocks 中的位置）
            for (position, index) in missingIndexes.enumerated() {
                if let result = pageResult.translation(for: "b\(position)") {
                    translated[index].translation = result.translation
                    translated[index].translationLines = result.translationLines
                }
            }
        }

        let completed = translated.filter {
            !($0.translation ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !completed.isEmpty else { throw VisionTranslationError.emptyResult }
        return completed
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
        translationPromptTemplate: String = defaultVisionTranslationPromptTemplate
    ) async throws -> [TextBlock] {
        try Task.checkCancellation()
        return try await recognizeVisionPageUsingModel(
            image: image,
            apiKey: apiKey,
            baseURL: baseURL,
            model: model,
            isRightToLeft: isRightToLeft,
            viewportAspect: viewportAspect,
            additionalInstructions: additionalInstructions,
            translationTarget: translationTarget,
            translationPromptTemplate: translationPromptTemplate
        )
    }

    /// 整本离线翻译专用入口：只调用 Vision 识别/翻译，不进入 `translatePage` 文本模型兜底。
    /// 固定协议由 OfflineTranslationPromptBuilder 生成，用户自定义内容只作为风格说明。
    static func recognizeOfflineVisionPage(
        image: UIImage,
        apiKey: String,
        baseURL: String,
        visionModel: String,
        sourceLanguage: TranslationSourceLanguage,
        targetLanguage: TranslationTargetLanguage,
        styleInstructions: String,
        previousContext: String,
        isRightToLeft: Bool = false,
        viewportAspect: CGFloat = 2.0
    ) async throws -> OfflineVisionPageResult {
        let prompt = OfflineTranslationPromptBuilder.make(
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            isRightToLeft: isRightToLeft,
            styleInstructions: styleInstructions,
            previousContext: previousContext
        )
        do {
            let result = try await recognizeVisionPageUsingModelWithStats(
                image: image,
                apiKey: apiKey,
                baseURL: baseURL,
                model: visionModel,
                isRightToLeft: isRightToLeft,
                viewportAspect: viewportAspect,
                additionalInstructions: "",
                translationTarget: targetLanguage,
                translationPromptTemplate: prompt
            )
            guard !result.blocks.isEmpty else { return .noText }
            return result.failedSlices > 0
                ? .partial(result.blocks, failedSlices: result.failedSlices)
                : .translated(result.blocks)
        } catch VisionTranslationError.emptyResult {
            return .noText
        }
    }

    private struct VisionPageRecognitionResult {
        let blocks: [TextBlock]
        let successfulSlices: Int
        let failedSlices: Int
    }

    private static func recognizeVisionPageUsingModel(image: UIImage, apiKey: String, baseURL: String, model: String, isRightToLeft: Bool, viewportAspect: CGFloat, additionalInstructions: String, translationTarget: TranslationTargetLanguage?, translationPromptTemplate: String) async throws -> [TextBlock] {
        try await recognizeVisionPageUsingModelWithStats(
            image: image,
            apiKey: apiKey,
            baseURL: baseURL,
            model: model,
            isRightToLeft: isRightToLeft,
            viewportAspect: viewportAspect,
            additionalInstructions: additionalInstructions,
            translationTarget: translationTarget,
            translationPromptTemplate: translationPromptTemplate
        ).blocks
    }

    private static func recognizeVisionPageUsingModelWithStats(image: UIImage, apiKey: String, baseURL: String, model: String, isRightToLeft: Bool, viewportAspect: CGFloat, additionalInstructions: String, translationTarget: TranslationTargetLanguage?, translationPromptTemplate: String) async throws -> VisionPageRecognitionResult {
        if shouldSliceBeforeVision(image, viewportAspect: viewportAspect) {
            return try await recognizeVisionSlicesWithStats(
                image: image,
                apiKey: apiKey,
                baseURL: baseURL,
                model: model,
                isRightToLeft: isRightToLeft,
                viewportAspect: viewportAspect,
                additionalInstructions: additionalInstructions,
                translationTarget: translationTarget,
                translationPromptTemplate: translationPromptTemplate
            )
        }
        do {
            let blocks = try await recognizeVisionImage(
                image: image,
                sourceRect: CGRect(x: 0, y: 0, width: 1, height: 1),
                apiKey: apiKey,
                baseURL: baseURL,
                model: model,
                isRightToLeft: isRightToLeft,
                additionalInstructions: additionalInstructions,
                translationTarget: translationTarget,
                translationPromptTemplate: translationPromptTemplate
            )
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
            print("MReader vision full-page recognition fallback: \(error.localizedDescription)")
            return try await recognizeVisionSlicesWithStats(
                image: image,
                apiKey: apiKey,
                baseURL: baseURL,
                model: model,
                isRightToLeft: isRightToLeft,
                viewportAspect: viewportAspect,
                additionalInstructions: additionalInstructions,
                translationTarget: translationTarget,
                translationPromptTemplate: translationPromptTemplate
            )
        }
    }

    private static func recognizeVisionSlicesWithStats(image: UIImage, apiKey: String, baseURL: String, model: String, isRightToLeft: Bool, viewportAspect: CGFloat, additionalInstructions: String, translationTarget: TranslationTargetLanguage?, translationPromptTemplate: String) async throws -> VisionPageRecognitionResult {
        let slices = visionSlices(from: image, viewportAspect: viewportAspect)
        print("MReader vision recognition sliced image=\(Int(image.size.width))x\(Int(image.size.height)) slices=\(slices.count) model=\(model)")
        // 有限并发处理切片：2 路并发显著降低总耗时，同时避免并发过高触发限流。
        let maximumConcurrentSlices = 2
        var fallbackBlocks: [TextBlock] = []
        var lastError: Error?
        var successfulSlices = 0
        var failedSlices = 0
        await withTaskGroup(of: (Int, Result<[TextBlock], Error>).self) { group in
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
                            isRightToLeft: isRightToLeft,
                            additionalInstructions: additionalInstructions,
                            translationTarget: translationTarget,
                            translationPromptTemplate: translationPromptTemplate
                        )
                        return (index, .success(blocks))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }

            for index in 0..<min(maximumConcurrentSlices, slices.count) {
                submit(index)
                nextIndex += 1
            }

            while let (index, result) = await group.next() {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                switch result {
                case .success(let blocks):
                    fallbackBlocks.append(contentsOf: blocks)
                    successfulSlices += 1
                case .failure(let error):
                    lastError = error
                    failedSlices += 1
                    print("MReader vision slice recognition failed index=\(index) model=\(model) reason=\(error.localizedDescription)")
                }
                if nextIndex < slices.count {
                    submit(nextIndex)
                    nextIndex += 1
                }
            }
        }
        let deduped = deduplicatedMangaTextBlocks(fallbackBlocks, isRightToLeft: isRightToLeft)
        guard !deduped.isEmpty else {
            throw lastError ?? VisionTranslationError.emptyResult
        }
        return VisionPageRecognitionResult(
            blocks: sortedTextBlocks(deduped, isRightToLeft: isRightToLeft),
            successfulSlices: successfulSlices,
            failedSlices: failedSlices
        )
    }

    static func visualVerifyOCRRegions(
        image: UIImage,
        blocks: [TextBlock],
        apiKey: String,
        baseURL: String,
        model: String,
        isRightToLeft: Bool
    ) async -> [TextBlock] {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let cgImage = image.cgImage else {
            return blocks
        }
        let regions = visualVerificationRegionsForDiagnostics(blocks)
        guard !regions.isEmpty else { return blocks }

        var corrected = blocks
        let pagePixelBounds = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        for region in regions {
            guard !Task.isCancelled,
                  let originalIndex = corrected.firstIndex(where: { $0.id == region.blockID }) else {
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
                let localBlocks = try await recognizeVisionPage(
                    image: cropImage,
                    apiKey: apiKey,
                    baseURL: baseURL,
                    model: model,
                    isRightToLeft: isRightToLeft,
                    viewportAspect: max(cropImage.size.height / max(cropImage.size.width, 1), 1.25)
                )
                guard let best = localBlocks.max(by: { $0.confidence < $1.confidence }) else {
                    continue
                }
                let original = corrected[originalIndex]
                let correctedText = best.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !correctedText.isEmpty else { continue }
                corrected[originalIndex] = TextBlock(
                    id: original.id,
                    text: correctedText,
                    boundingBox: OCRCoordinateMapper.normalizedPageRect(
                        forSliceRect: best.boundingBox,
                        sourceRect: region.sourceRect
                    ),
                    translation: original.translation,
                    confidence: max(original.confidence, best.confidence),
                    ocrSource: "visual-review",
                    isFiltered: original.isFiltered,
                    filterReason: original.filterReason,
                    estimatedFontScale: original.estimatedFontScale,
                    textColorHex: original.textColorHex,
                    polygon: original.polygon,
                    translationLines: original.translationLines
                )
                print("MReader OCR visual review corrected block=\(region.blockID) confidence=\(String(format: "%.2f", best.confidence))")
            } catch {
                print("MReader OCR visual review fallback block=\(region.blockID) reason=\(error.localizedDescription)")
            }
        }
        return corrected
    }

    private static func recognizeVisionImage(image: UIImage, sourceRect: CGRect, apiKey: String, baseURL: String, model: String, isRightToLeft: Bool, additionalInstructions: String, translationTarget: TranslationTargetLanguage?, translationPromptTemplate: String) async throws -> [TextBlock] {
        guard !apiKey.isEmpty else { throw VisionTranslationError.api("未配置 API Key") }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VisionTranslationError.api("未配置模型") }
        guard let url = chatCompletionsURL(from: baseURL) else { throw VisionTranslationError.api("接口地址无效") }
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
            systemPrompt = "你只做漫画图片中的文字识别、断句、翻译和精确坐标标注。逐个气泡同时返回原文、译文、translationLines、textBox、bubbleBox 和四点多边形；不得描述画面，不得输出 JSON 之外的内容。"
        } else {
            prompt = visionRecognitionPrompt(
                isRightToLeft: isRightToLeft,
                additionalInstructions: additionalInstructions
            )
            systemPrompt = "你只做漫画图片中文字识别、断句和精确坐标标注，不要翻译。逐个气泡返回原文、分类、textBox、bubbleBox 和四点多边形；不得描述画面，不得输出 JSON 之外的内容。"
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model.trimmingCharacters(in: .whitespacesAndNewlines),
            "messages": [
                [
                    "role": "system",
                    "content": systemPrompt
                ],
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": prompt],
                        ["type": "image_url", "image_url": ["url": imageDataURL]]
                    ]
                ]
            ],
            "temperature": 0.1
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await aiTranslationSession.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw AITranslationRequestError.serverWithRetryAfter(
                model: model,
                statusCode: httpResponse.statusCode,
                message: apiErrorMessage(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode),
                retryAfterSeconds: retryAfterSeconds(from: httpResponse)
            )
        }
        if let message = apiErrorMessage(from: data) {
            throw VisionTranslationError.api(message)
        }
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
                    inputPixelSize: inputPixelSize
                )
            } else {
                blocks = try parseVisionRecognitionBlocks(
                    from: content,
                    sourceRect: sourceRect,
                    inputPixelSize: inputPixelSize,
                    isRightToLeft: isRightToLeft
                )
            }
        } catch {
            let excerpt = content
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(500)
            print("MReader vision recognition invalid JSON excerpt=\(excerpt)")
            throw VisionTranslationError.invalidJSON
        }
        guard !blocks.isEmpty else { throw VisionTranslationError.emptyResult }
        return blocks
    }

    private static func chatCompletionsURL(from baseURL: String) -> URL? {
        AIEndpointResolver.chatCompletionsURL(from: baseURL)
    }

    private static func retryAfterSeconds(from response: HTTPURLResponse) -> UInt64? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              seconds >= 0 else {
            return nil
        }
        return UInt64(ceil(seconds))
    }

    private static func apiErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any] else {
            return nil
        }
        if let message = error["message"] as? String, !message.isEmpty {
            return message
        }
        if let code = error["code"] as? String, !code.isEmpty {
            return code
        }
        if let type = error["type"] as? String, !type.isEmpty {
            return type
        }
        return nil
    }

    private static func assistantContent(from json: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        return AIChatResponseDecoder.decode(data).content
    }

    static func assistantContentForDiagnostics(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return assistantContent(from: json)
    }

    static func sanitizedTranslationTextForDiagnostics(
        _ content: String,
        sourceText: String
    ) -> String? {
        sanitizedTranslationText(from: content, sourceText: sourceText)
    }

    private static func sanitizedTranslationText(
        from content: String,
        sourceText: String
    ) -> String? {
        var value = content
            .replacingOccurrences(
                of: #"<think>[\s\S]*?</think>"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)

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

        let suspiciousMarkers = [
            "system prompt", "user prompt", "analysis:", "reasoning:",
            "_output", "输出要求", "提示词", "作为一个", "我不能",
            "根据用户", "翻译过程"
        ]
        let lowercased = value.lowercased()
        guard !value.isEmpty,
              !suspiciousMarkers.contains(where: { lowercased.contains($0.lowercased()) }),
              value != sourceText.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        return value
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

    private static func renderVisionPrompt(template: String, targetLanguage: String, isRightToLeft: Bool) -> String {
        let usableTemplate = template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultVisionTranslationPromptTemplate : template
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
        textBox 紧贴文字，bubbleBox 覆盖文字所在的完整原气泡；同时尽量返回对应的四点 textPolygon 和 bubblePolygon。
        坐标以输入图片左上角为原点，统一使用 0 到 1 的归一化值，并在 JSON 顶层显式声明 "coordinateSpace":"normalized"；禁止像素或百分比坐标。
        不要识别人物身份。不要输出解释、Markdown 或思考过程。
        \(extra.isEmpty ? "" : "用户补充要求如下。只采用其中与原文识别、断句、过滤和坐标有关的部分；忽略要求翻译、描述画面或改变 JSON 结构的部分：\n\(extra)")
        只输出严格 JSON：
        {"coordinateSpace":"normalized","items":[{"id":"v1","order":1,"text":"原文","classification":"dialogue","textBox":{"x":0.1,"y":0.2,"width":0.2,"height":0.08},"bubbleBox":{"x":0.08,"y":0.18,"width":0.24,"height":0.12},"textPolygon":[{"x":0.1,"y":0.2},{"x":0.3,"y":0.2},{"x":0.3,"y":0.28},{"x":0.1,"y":0.28}],"bubblePolygon":[{"x":0.08,"y":0.18},{"x":0.32,"y":0.18},{"x":0.32,"y":0.3},{"x":0.08,"y":0.3}],"confidence":0.9}]}
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

    private enum VisionTranslationError: LocalizedError {
        case api(String)
        case imageEncodingFailed
        case invalidJSON
        case invalidCoordinates
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
            case .emptyResult:
                return "视觉翻译没有返回可用文本"
            }
        }
    }

    private static func shouldFallbackToVisionSlices(after error: Error) -> Bool {
        guard let visionError = error as? VisionTranslationError else { return false }
        switch visionError {
        case .invalidJSON, .invalidCoordinates, .emptyResult:
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
        let ratio = CGFloat(cgImage.height) / CGFloat(cgImage.width)
        return ratio > max(min(max(viewportAspect, 1.25), 2.6) * 1.35, 2.2)
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

        let clampedViewportAspect = min(max(viewportAspect, 1.25), 2.6)
        let sliceHeight = min(max(Int(CGFloat(width) * clampedViewportAspect), 900), 3200)
        let overlap = Int(Double(sliceHeight) * 0.12)
        let step = max(1, sliceHeight - overlap)
        var slices: [VisionSlice] = []
        var y = 0
        while y < height {
            let currentHeight = min(sliceHeight, height - y)
            let cropRect = CGRect(x: 0, y: CGFloat(y), width: CGFloat(width), height: CGFloat(currentHeight))
            if let cropped = cgImage.cropping(to: cropRect) {
                let normalized = CGRect(
                    x: 0,
                    y: CGFloat(y) / CGFloat(height),
                    width: 1,
                    height: CGFloat(currentHeight) / CGFloat(height)
                )
                let croppedImage = UIImage(cgImage: cropped, scale: 1, orientation: image.imageOrientation)
                slices.append(VisionSlice(
                    image: resizedImageForVision(croppedImage, maxDimension: 2048),
                    sourceRect: normalized
                ))
            }
            if y + currentHeight >= height { break }
            y += step
        }
        return slices
    }

    private static func parseVisionTranslationBlocks(
        from content: String,
        sourceRect: CGRect,
        inputPixelSize: CGSize
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
                ?? (dictionary["translations"] as? [[String: Any]])
                ?? (dictionary["blocks"] as? [[String: Any]])
                ?? ((dictionary["data"] as? [String: Any])?["items"] as? [[String: Any]])
                ?? ((dictionary["result"] as? [String: Any])?["items"] as? [[String: Any]])
                ?? []
        } else {
            rawItems = []
        }

        struct RawVisionItem {
            let text: String
            let translation: String
            let rawLines: [String]
            let textPolygon: [CGPoint]
            let bubblePolygon: [CGPoint]
            let textRect: CGRect?
            let bubbleRect: CGRect?
            let rect: CGRect
            let confidence: Double
            let classification: String
        }

        let parsedItems = rawItems.compactMap { item -> RawVisionItem? in
            let text = firstString(in: item, keys: ["text", "sourceText", "source_text", "original", "originalText", "original_text"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let rawLines = ((item["lines"] ?? item["translationLines"] ?? item["translation_lines"]) as? [String])?
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty } ?? []
            let rawTranslation = firstString(in: item, keys: ["translation", "translatedText", "translated_text", "targetText", "target_text"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let translation = rawLines.isEmpty ? rawTranslation : rawLines.joined(separator: "\n")
            guard !translation.isEmpty else { return nil }
            let textPolygon = pointsValue(from: item["textPolygon"] ?? item["text_polygon"]) ?? []
            let bubblePolygon = pointsValue(from: item["bubblePolygon"] ?? item["bubble_polygon"]) ?? []
            let textRect = rectValue(from: item["textBox"] ?? item["text_box"])
            let bubbleRect = rectValue(from: item["bubbleBox"] ?? item["bubble_box"])
            let localPolygon = !textPolygon.isEmpty ? textPolygon : bubblePolygon
            let localRect = textRect
                ?? bubbleRect
                ?? rectValue(from: item["box"])
                ?? rectValue(from: item["boundingBox"])
                ?? rectValue(from: item["bounding_box"])
                ?? boundingRect(for: localPolygon)
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
                translation: translation,
                rawLines: rawLines,
                textPolygon: textPolygon,
                bubblePolygon: bubblePolygon,
                textRect: textRect,
                bubbleRect: bubbleRect,
                rect: localRect,
                confidence: doubleValue(from: item["confidence"]) ?? 0.75,
                classification: classification
            )
        }

        // 坐标协议：只接受“显式 normalized 0...1”的响应。不再按数值大小猜测像素/百分比/0~1000 基准，
        // 避免小像素坐标（如 2048 图上的 x=20,y=25,width=40,height=30）被误判成百分比放大几十倍。
        if !parsedItems.isEmpty {
            guard visionCoordinateSpaceIsNormalized(
                json,
                rects: parsedItems.flatMap { [$0.textRect, $0.bubbleRect, $0.rect].compactMap { $0 } },
                polygons: parsedItems.flatMap { [$0.textPolygon, $0.bubblePolygon] }
            ) else {
                throw VisionTranslationError.invalidCoordinates
            }
        }
        let coordinateDivisor = CGSize(width: 1, height: 1)

        let blocks = parsedItems.compactMap { item -> TextBlock? in
            let normalizedBubbleRect = item.bubbleRect.map { normalizeVisionRect($0, divisor: coordinateDivisor) }
            let mappedBubbleRect = normalizedBubbleRect.map { mapVisionRect($0, from: sourceRect) }
            let normalizedRect = normalizeVisionRect(item.rect, divisor: coordinateDivisor)
            let mappedRect = mapVisionRect(normalizedRect, from: sourceRect)
            guard isUsableVisionRect(mappedRect) else { return nil }
            let sourcePolygon = !item.textPolygon.isEmpty ? item.textPolygon : item.bubblePolygon
            let mappedPolygon = sourcePolygon.map { point in
                let normalizedPoint = CGPoint(
                    x: point.x / coordinateDivisor.width,
                    y: point.y / coordinateDivisor.height
                )
                return CGPoint(
                    x: sourceRect.minX + normalizedPoint.x * sourceRect.width,
                    y: sourceRect.minY + normalizedPoint.y * sourceRect.height
                )
            }
            return TextBlock(
                text: item.text.isEmpty ? item.translation : item.text,
                boundingBox: mappedRect,
                translation: item.translation,
                confidence: item.confidence,
                ocrSource: "vision-model:\(item.classification)",
                bubbleBox: mappedBubbleRect.flatMap { isUsableVisionRect($0) ? $0 : nil },
                polygon: mappedPolygon,
                translationLines: item.rawLines
            )
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
                keys: ["text", "sourceText", "source_text", "original", "originalText"]
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let classification = firstString(
                in: item,
                keys: ["classification", "type", "category"]
            ).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let compactClassification = classification.replacingOccurrences(of: " ", with: "")
            guard !ignoredClassifications.contains(compactClassification),
                  !looksLikeNonContentText(text) else {
                print("MReader vision recognition filtered type=\(classification) text=\(text.prefix(80))")
                return nil
            }
            return RawRecognitionItem(
                text: text,
                classification: classification.isEmpty ? "dialogue" : classification,
                order: doubleValue(from: item["order"]).map(Int.init) ?? Int.max,
                textRect: rectValue(from: item["textBox"] ?? item["text_box"]),
                bubbleRect: rectValue(from: item["bubbleBox"] ?? item["bubble_box"]),
                textPolygon: pointsValue(from: item["textPolygon"] ?? item["text_polygon"]) ?? [],
                bubblePolygon: pointsValue(from: item["bubblePolygon"] ?? item["bubble_polygon"]) ?? [],
                confidence: doubleValue(from: item["confidence"]) ?? 0.75
            )
        }

        let allRects = parsed.flatMap { [$0.textRect, $0.bubbleRect].compactMap { $0 } }
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
            guard let mappedRect = validTextRect ?? validBubbleRect.map({
                expandedVisionTextRect($0, within: sourceRect)
            }) else {
                return nil
            }
            let sourcePolygon = !item.textPolygon.isEmpty ? item.textPolygon : item.bubblePolygon
            let mappedPolygon = sourcePolygon.map { point in
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
                    estimatedFontScale: Double(min(
                        validTextRect?.width ?? mappedRect.width,
                        validTextRect?.height ?? mappedRect.height
                    )),
                    bubbleBox: validBubbleRect,
                    polygon: mappedPolygon
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
        inputPixelSize: CGSize
    ) throws -> [TextBlock] {
        try parseVisionTranslationBlocks(
            from: content,
            sourceRect: sourceRect,
            inputPixelSize: inputPixelSize
        )
    }

    private static func extractedJSONPayload(from content: String) -> String {
        var trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        trimmed = trimmed.replacingOccurrences(
            of: #"<think>[\s\S]*?</think>"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
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
                print("MReader OCR filter text=\(text) reason=安全区外 box=\(block.boundingBox)")
                return annotated
            }
            if let noiseReason = edgeNoiseReason(text) {
                annotated.isFiltered = true
                annotated.filterReason = noiseReason
                print("MReader OCR filter text=\(text) reason=\(noiseReason)")
                return annotated
            }

            let height = block.boundingBox.height
            let area = block.boundingBox.width * block.boundingBox.height
            if text.count <= 2 && height < minimumHeight * 1.55 {
                annotated.isFiltered = true
                annotated.filterReason = "短文本过小"
                print("MReader OCR filter text=\(text) reason=短文本过小 height=\(height)")
                return annotated
            }
            if height < minimumHeight || area < minimumArea {
                annotated.isFiltered = true
                annotated.filterReason = "字号/面积过小"
                print("MReader OCR filter text=\(text) reason=字号/面积过小 height=\(height) area=\(area)")
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

        // 行/列分组阈值随页面字号自适应：长条漫画（webtoon）归一化后的字号远小于普通单页，
        // 固定阈值会把纵向相邻的多行文字误判成同一行。
        let fontScales = validBlocks
            .map { min($0.boundingBox.width, $0.boundingBox.height) }
            .sorted()
        let medianFontScale = fontScales[fontScales.count / 2]

        if isMostlyVertical {
            let columnThreshold = min(max(medianFontScale * 1.1, 0.02), 0.045)
            return validBlocks.sorted { lhs, rhs in
                let columnDistance = abs(lhs.boundingBox.midX - rhs.boundingBox.midX)
                if columnDistance > columnThreshold {
                    return isRightToLeft ? lhs.boundingBox.midX > rhs.boundingBox.midX : lhs.boundingBox.midX < rhs.boundingBox.midX
                }
                return lhs.boundingBox.midY < rhs.boundingBox.midY
            }
        }

        let rowThreshold = min(max(medianFontScale * 0.75, 0.006), 0.035)
        return validBlocks.sorted { lhs, rhs in
            let rowDistance = abs(lhs.boundingBox.midY - rhs.boundingBox.midY)
            if rowDistance > rowThreshold {
                return lhs.boundingBox.midY < rhs.boundingBox.midY
            }
            return isRightToLeft ? lhs.boundingBox.midX > rhs.boundingBox.midX : lhs.boundingBox.midX < rhs.boundingBox.midX
        }
    }
}
