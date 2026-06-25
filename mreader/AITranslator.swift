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
    var polygon: [CGPoint]
    var translationLines: [String]

    nonisolated init(id: UUID = UUID(), text: String, boundingBox: CGRect, translation: String? = nil, confidence: Double = 0, ocrSource: String = "vision", isFiltered: Bool = false, filterReason: String? = nil, estimatedFontScale: Double? = nil, textColorHex: String? = nil, polygon: [CGPoint] = [], translationLines: [String] = []) {
        self.id = id
        self.text = text
        self.boundingBox = boundingBox
        self.translation = translation
        self.confidence = confidence
        self.ocrSource = ocrSource
        self.isFiltered = isFiltered
        self.filterReason = filterReason
        self.estimatedFontScale = estimatedFontScale ?? Double(boundingBox.height)
        self.textColorHex = textColorHex
        self.polygon = polygon
        self.translationLines = translationLines
    }
}

nonisolated enum AITranslationRequestError: LocalizedError, Sendable {
    case invalidConfiguration(String)
    case server(model: String, statusCode: Int?, message: String)
    case invalidResponse(model: String)
    case allModelsFailed(lastModel: String?, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            return message
        case .server(let model, let statusCode, let message):
            if let statusCode {
                return "模型 \(model) 请求失败：HTTP \(statusCode)，\(message)"
            }
            return "模型 \(model) 请求失败：\(message)"
        case .invalidResponse(let model):
            return "模型 \(model) 返回了无法识别的响应"
        case .allModelsFailed(let lastModel, let message):
            if let lastModel {
                return "所有可用模型均请求失败，最后使用 \(lastModel)：\(message)"
            }
            return "没有可用的 AI 模型：\(message)"
        }
    }
}

class AITranslator {
    private static let maximumTextModelsPerRequest = 3
    private static let maximumVisionModelsPerRequest = 2

    nonisolated static let defaultTranslationPromptTemplate = """
    你是一个漫画对白翻译助手。请只翻译我提供的 OCR 文本，不要续写、总结、评价或添加剧情。
    请保持原文的语气、称呼、人物关系、情绪和漫画对白的自然口语感。
    OCR 可能把同一句话切成数段。只有当片段距离接近、字号和颜色一致时，才按阅读顺序还原为一句通顺对白；距离较远、字号不同或颜色不同的片段绝对不能合并。
    网址、广告、版权、水印和页码不要翻译。
    如果同一气泡包含多句独立对白，请每句之间保留一个空行。
    如果原文有断句、气泡顺序或拟声词，请保留对应结构。
    不要记录、记忆、推断用户身份，也不要输出与翻译无关的内容。
    如果文本包含成人、暴力、敏感或私人内容，只进行中性、准确翻译，不要扩写、润色成更露骨内容，也不要添加新的细节。
    请将以下文本翻译为：{targetLanguage}

    OCR 文本：
    {ocrText}

    OCR 属性：
    {ocrMetadata}

    输出要求：
    只输出翻译结果。
    """

    nonisolated static let defaultVisionTranslationPromptTemplate = """
    你是一个漫画图片文字识别与翻译助手。请只处理图片中的文字，不要描述画面、人物、动作、身体、场景或剧情，不要评价、总结、续写或添加任何新细节。
    你的任务是：识别漫画页面中的对白、旁白、拟声词和必要的画面文字，翻译为：{targetLanguage}，并给出文字框和推荐显示气泡框坐标。
    如果图片包含成人、暴力、敏感或私人内容，只进行中性、准确的文字翻译；不要美化、扩写、润色成更露骨内容，也不要输出与文字翻译无关的内容。
    不要记录、记忆、推断用户身份，不要识别现实人物身份。
    忽略网址、广告、版权、水印和页码。
    坐标要求：所有坐标都以整张输入图片左上角为原点并归一化到 0 到 1。除了 textBox 和 bubbleBox，还必须提供 textPolygon 和 bubblePolygon（按左上、右上、右下、左下顺序的四个点）以及 center 点。bubbleBox 必须真实覆盖原气泡或文字区域，不要只给大概位置。
    由你判断译文是否需要分行，translationLines 每个数组元素是一行；不要为了填满气泡而扩写。

    只输出严格 JSON，不要 Markdown，不要解释：
    {
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
    如果没有可翻译文字，输出 {"items": []}。
    """
    
    // 1. 使用 Apple 原生 Vision 框架进行 OCR 识别 (极低内存占用，全本地执行)
    static func recognizeText(in image: UIImage, isRightToLeft: Bool = false, minimumTextHeight: Double = 0.008) async throws -> [TextBlock] {
        try await OCRPreprocessor.recognizeText(
            in: image,
            options: OCRPreprocessor.Options(
                isRightToLeft: isRightToLeft,
                minimumTextHeight: minimumTextHeight,
                languages: ["zh-Hans", "zh-Hant", "ja-JP", "en-US"]
            )
        )
    }

    // 2. 调用 OpenAI 兼容接口进行翻译
    static func translate(text: String, ocrMetadata: String = "", apiKey: String, baseURL: String, model: String, modelPoolText: String = "", isModelPoolEnabled: Bool = true, targetLanguage: String = "中文", promptTemplate: String = defaultTranslationPromptTemplate) async throws -> String {
        let models = await AIModelPoolManager.shared.modelsForAttempt(
            defaultModel: model,
            poolText: modelPoolText,
            isPoolEnabled: isModelPoolEnabled
        )
        guard !models.isEmpty else {
            throw AITranslationRequestError.invalidConfiguration("未配置模型")
        }
        var lastError: Error?
        var lastModel: String?
        for candidate in models.prefix(maximumTextModelsPerRequest) {
            try Task.checkCancellation()
            await AIModelPoolManager.shared.markCurrentModel(candidate)
            do {
                let result = try await translateTextUsingModel(
                    text: text,
                    apiKey: apiKey,
                    baseURL: baseURL,
                    model: candidate,
                    targetLanguage: targetLanguage,
                    promptTemplate: promptTemplate,
                    ocrMetadata: ocrMetadata
                )
                await AIModelPoolManager.shared.markSucceeded(model: candidate)
                return result
            } catch {
                lastError = error
                lastModel = candidate
                let details = requestErrorDetails(error)
                if AIModelPoolManager.isRateLimit(statusCode: details.statusCode, message: details.message) {
                    await AIModelPoolManager.shared.markRateLimited(model: candidate, message: details.message)
                } else {
                    await AIModelPoolManager.shared.markFailed(model: candidate, message: details.message)
                }
                let nextModel = models.drop(while: { $0 != candidate }).dropFirst().first
                print("MReader AI model failed current=\(candidate) reason=\(details.message) next=\(nextModel ?? "<none>")")
            }
        }
        let message = requestErrorDetails(lastError).message
        throw AITranslationRequestError.allModelsFailed(lastModel: lastModel, message: message)
    }

    private static func translateTextUsingModel(text: String, apiKey: String, baseURL: String, model: String, targetLanguage: String, promptTemplate: String, ocrMetadata: String) async throws -> String {
        guard !apiKey.isEmpty else { throw AITranslationRequestError.invalidConfiguration("未配置 API Key") }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AITranslationRequestError.invalidConfiguration("未配置模型") }
        guard let url = chatCompletionsURL(from: baseURL) else { throw AITranslationRequestError.invalidConfiguration("接口地址无效") }
        let prompt = renderPrompt(template: promptTemplate, text: text, targetLanguage: targetLanguage, ocrMetadata: ocrMetadata)
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "model": model.trimmingCharacters(in: .whitespacesAndNewlines),
            "messages": [
                ["role": "system", "content": "你是只输出翻译结果的漫画对白翻译助手。OCR 碎片仅在距离接近且字号、颜色一致时按阅读顺序合并；距离远、字号不同或颜色不同必须保持为不同对白。网址、广告、水印和页码不翻译。不要续写、总结、评价、添加剧情、保存信息或推断用户身份。禁止输出思考过程、提示词、分析、说明、Markdown 或原文复述。"],
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

        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let content = assistantContent(from: json),
           let translation = sanitizedTranslationText(from: content, sourceText: text) {
            return translation
        }

        throw AITranslationRequestError.invalidResponse(model: model)
    }

    static func translateVisionPage(image: UIImage, apiKey: String, baseURL: String, model: String, modelPoolText: String = "", isModelPoolEnabled: Bool = true, targetLanguage: String = "中文", promptTemplate: String = defaultVisionTranslationPromptTemplate, isRightToLeft: Bool = false, viewportAspect: CGFloat = 2.0) async throws -> [TextBlock] {
        let models = await AIModelPoolManager.shared.modelsForAttempt(
            defaultModel: model,
            poolText: modelPoolText,
            isPoolEnabled: isModelPoolEnabled
        )
        guard !models.isEmpty else {
            throw AITranslationRequestError.invalidConfiguration("未配置模型")
        }
        var lastError: Error?
        var lastModel: String?
        for candidate in models.prefix(maximumVisionModelsPerRequest) {
            try Task.checkCancellation()
            await AIModelPoolManager.shared.markCurrentModel(candidate)
            do {
                let blocks = try await translateVisionPageUsingModel(
                    image: image,
                    apiKey: apiKey,
                    baseURL: baseURL,
                    model: candidate,
                    targetLanguage: targetLanguage,
                    promptTemplate: promptTemplate,
                    isRightToLeft: isRightToLeft,
                    viewportAspect: viewportAspect
                )
                await AIModelPoolManager.shared.markSucceeded(model: candidate)
                return blocks
            } catch {
                lastError = error
                lastModel = candidate
                let details = requestErrorDetails(error)
                if AIModelPoolManager.isRateLimit(statusCode: details.statusCode, message: details.message) {
                    await AIModelPoolManager.shared.markRateLimited(model: candidate, message: details.message)
                } else {
                    await AIModelPoolManager.shared.markFailed(model: candidate, message: details.message)
                }
                let nextModel = models.drop(while: { $0 != candidate }).dropFirst().first
                print("MReader AI vision model failed current=\(candidate) reason=\(details.message) next=\(nextModel ?? "<none>")")
            }
        }
        throw AITranslationRequestError.allModelsFailed(
            lastModel: lastModel,
            message: requestErrorDetails(lastError).message
        )
    }

    private static func translateVisionPageUsingModel(image: UIImage, apiKey: String, baseURL: String, model: String, targetLanguage: String, promptTemplate: String, isRightToLeft: Bool, viewportAspect: CGFloat) async throws -> [TextBlock] {
        if shouldSliceBeforeVision(image, viewportAspect: viewportAspect) {
            return try await translateVisionSlices(
                image: image,
                apiKey: apiKey,
                baseURL: baseURL,
                model: model,
                targetLanguage: targetLanguage,
                promptTemplate: promptTemplate,
                isRightToLeft: isRightToLeft,
                viewportAspect: viewportAspect
            )
        }
        do {
            let blocks = try await translateVisionImage(
                image: image,
                sourceRect: CGRect(x: 0, y: 0, width: 1, height: 1),
                apiKey: apiKey,
                baseURL: baseURL,
                model: model,
                targetLanguage: targetLanguage,
                promptTemplate: promptTemplate
            )
            guard !blocks.isEmpty else { throw VisionTranslationError.emptyResult }
            return sortedTextBlocks(blocks, isRightToLeft: isRightToLeft)
        } catch {
            guard shouldFallbackToVisionSlices(after: error) else {
                throw error
            }
            let slices = visionSlices(from: image, viewportAspect: viewportAspect)
            guard slices.count > 1 else {
                throw error
            }
            print("MReader vision full-page translation fallback: \(error.localizedDescription)")
            return try await translateVisionSlices(
                image: image,
                apiKey: apiKey,
                baseURL: baseURL,
                model: model,
                targetLanguage: targetLanguage,
                promptTemplate: promptTemplate,
                isRightToLeft: isRightToLeft,
                viewportAspect: viewportAspect
            )
        }
    }

    private static func translateVisionSlices(image: UIImage, apiKey: String, baseURL: String, model: String, targetLanguage: String, promptTemplate: String, isRightToLeft: Bool, viewportAspect: CGFloat) async throws -> [TextBlock] {
        let slices = visionSlices(from: image, viewportAspect: viewportAspect)
        print("MReader vision sliced image=\(Int(image.size.width))x\(Int(image.size.height)) slices=\(slices.count) model=\(model)")
        var fallbackBlocks: [TextBlock] = []
        var lastError: Error?
        for (index, slice) in slices.enumerated() {
            try Task.checkCancellation()
            do {
                let blocks = try await translateVisionImage(
                    image: slice.image,
                    sourceRect: slice.sourceRect,
                    apiKey: apiKey,
                    baseURL: baseURL,
                    model: model,
                    targetLanguage: targetLanguage,
                    promptTemplate: promptTemplate
                )
                fallbackBlocks.append(contentsOf: blocks)
            } catch {
                lastError = error
                print("MReader vision slice translation failed index=\(index) model=\(model) reason=\(error.localizedDescription)")
            }
        }
        let deduped = deduplicatedMangaTextBlocks(fallbackBlocks, isRightToLeft: isRightToLeft)
        guard !deduped.isEmpty else {
            throw lastError ?? VisionTranslationError.emptyResult
        }
        return sortedTextBlocks(deduped, isRightToLeft: isRightToLeft)
    }

    private static func translateVisionImage(image: UIImage, sourceRect: CGRect, apiKey: String, baseURL: String, model: String, targetLanguage: String, promptTemplate: String) async throws -> [TextBlock] {
        guard !apiKey.isEmpty else { throw VisionTranslationError.api("未配置 API Key") }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VisionTranslationError.api("未配置模型") }
        guard let url = chatCompletionsURL(from: baseURL) else { throw VisionTranslationError.api("接口地址无效") }
        let preparedImage = resizedImageForVision(image, maxDimension: 2048)
        guard let imageDataURL = encodedVisionImageDataURL(preparedImage) else { throw VisionTranslationError.imageEncodingFailed }
        let inputPixelSize = pixelSize(of: preparedImage)

        let prompt = renderVisionPrompt(template: promptTemplate, targetLanguage: targetLanguage)
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
                    "content": "你只做漫画图片中文字识别、翻译和精确坐标标注。逐个气泡定位，返回 textBox、bubbleBox、四点多边形和分行建议；不得描述画面，不得翻译网址、广告、水印或页码，不得输出 JSON 之外的内容。"
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
            throw AITranslationRequestError.server(
                model: model,
                statusCode: httpResponse.statusCode,
                message: apiErrorMessage(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
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
            blocks = try parseVisionTranslationBlocks(
                from: content,
                sourceRect: sourceRect,
                inputPixelSize: inputPixelSize
            )
        } catch {
            let excerpt = content
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(500)
            print("MReader vision invalid JSON excerpt=\(excerpt)")
            throw VisionTranslationError.invalidJSON
        }
        guard !blocks.isEmpty else { throw VisionTranslationError.emptyResult }
        return blocks
    }

    private static func chatCompletionsURL(from baseURL: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasSuffix("/chat/completions") {
            return URL(string: trimmed)
        }

        let withoutTrailingSlash = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(withoutTrailingSlash)/chat/completions")
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
        if let outputText = json["output_text"] as? String,
           !outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return outputText
        }
        guard let choices = json["choices"] as? [[String: Any]],
              let choice = choices.first else {
            return nil
        }
        if let text = choice["text"] as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        guard let message = choice["message"] as? [String: Any] else { return nil }
        if let content = message["content"] as? String {
            return content
        }
        if let content = message["content"] as? [[String: Any]] {
            let joined = content.compactMap { part -> String? in
                if let text = part["text"] as? String { return text }
                if let content = part["content"] as? String { return content }
                if let value = part["value"] as? String { return value }
                return nil
            }
            .joined(separator: "\n")
            return joined.isEmpty ? nil : joined
        }
        if let content = message["content"],
           JSONSerialization.isValidJSONObject(content),
           let data = try? JSONSerialization.data(withJSONObject: content),
           let value = String(data: data, encoding: .utf8) {
            return value
        }
        return nil
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
                of: #"^(?:翻译结果|译文|translation|translated text)\s*[:：]\s*"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let suspiciousMarkers = [
            "system prompt", "user prompt", "analysis:", "reasoning:",
            "_output", "输出要求", "提示词", "作为一个", "我不能",
            "根据用户", "翻译过程", "以下是翻译"
        ]
        let lowercased = value.lowercased()
        guard !value.isEmpty,
              !suspiciousMarkers.contains(where: { lowercased.contains($0.lowercased()) }),
              value != sourceText.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        return value
    }

    private static func requestErrorDetails(_ error: Error?) -> (statusCode: Int?, message: String) {
        guard let error else { return (nil, "未知错误") }
        if case let AITranslationRequestError.server(_, statusCode, message) = error {
            return (statusCode, message)
        }
        if let requestError = error as? AITranslationRequestError {
            return (nil, requestError.localizedDescription)
        }
        if let visionError = error as? VisionTranslationError {
            if case .api(let message) = visionError {
                let statusCode = message
                    .split(separator: " ")
                    .compactMap { Int($0) }
                    .first
                return (statusCode, message)
            }
            return (nil, visionError.localizedDescription)
        }
        if let urlError = error as? URLError {
            return (nil, urlError.localizedDescription)
        }
        return (nil, error.localizedDescription)
    }

    private static func renderPrompt(template: String, text: String, targetLanguage: String, ocrMetadata: String) -> String {
        let usableTemplate = template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultTranslationPromptTemplate : template
        return usableTemplate
            .replacingOccurrences(of: "{targetLanguage}", with: targetLanguage)
            .replacingOccurrences(of: "{ocrText}", with: text)
            .replacingOccurrences(of: "{ocrMetadata}", with: ocrMetadata)
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

    private static func renderVisionPrompt(template: String, targetLanguage: String) -> String {
        let usableTemplate = template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultVisionTranslationPromptTemplate : template
        return usableTemplate.replacingOccurrences(of: "{targetLanguage}", with: targetLanguage)
    }

    private enum VisionTranslationError: LocalizedError {
        case api(String)
        case imageEncodingFailed
        case invalidJSON
        case emptyResult

        var errorDescription: String? {
            switch self {
            case .api(let message):
                return message
            case .imageEncodingFailed:
                return "图片编码失败"
            case .invalidJSON:
                return "视觉翻译返回格式无效"
            case .emptyResult:
                return "视觉翻译没有返回可用文本"
            }
        }
    }

    private static func shouldFallbackToVisionSlices(after error: Error) -> Bool {
        guard let visionError = error as? VisionTranslationError else { return false }
        switch visionError {
        case .invalidJSON, .emptyResult:
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

        let blocks = rawItems.compactMap { item -> TextBlock? in
            let text = firstString(in: item, keys: ["text", "sourceText", "source_text", "original", "originalText", "original_text"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let rawLines = ((item["translationLines"] ?? item["translation_lines"]) as? [String])?
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty } ?? []
            let rawTranslation = firstString(in: item, keys: ["translation", "translatedText", "translated_text", "targetText", "target_text"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let translation = rawLines.isEmpty ? rawTranslation : rawLines.joined(separator: "\n")
            guard !translation.isEmpty else { return nil }
            let localPolygon = pointsValue(from: item["bubblePolygon"] ?? item["bubble_polygon"])
                ?? pointsValue(from: item["textPolygon"] ?? item["text_polygon"])
                ?? []
            let localRect = rectValue(from: item["bubbleBox"] ?? item["bubble_box"])
                ?? rectValue(from: item["textBox"] ?? item["text_box"])
                ?? rectValue(from: item["box"])
                ?? rectValue(from: item["boundingBox"])
                ?? rectValue(from: item["bounding_box"])
                ?? boundingRect(for: localPolygon)
            guard let localRect else { return nil }
            let coordinateDivisor = visionCoordinateDivisor(
                rect: localRect,
                polygon: localPolygon,
                inputPixelSize: inputPixelSize
            )
            let normalizedRect = normalizeVisionRect(localRect, divisor: coordinateDivisor)
            let mappedRect = mapVisionRect(normalizedRect, from: sourceRect)
            guard isUsableVisionRect(mappedRect) else { return nil }
            let mappedPolygon = localPolygon.map { point in
                let normalizedPoint = CGPoint(
                    x: point.x / coordinateDivisor.width,
                    y: point.y / coordinateDivisor.height
                )
                return CGPoint(
                    x: sourceRect.minX + normalizedPoint.x * sourceRect.width,
                    y: sourceRect.minY + normalizedPoint.y * sourceRect.height
                )
            }
            let confidence = doubleValue(from: item["confidence"]) ?? 0.75
            return TextBlock(
                text: text.isEmpty ? translation : text,
                boundingBox: mappedRect,
                translation: translation,
                confidence: confidence,
                ocrSource: "vision-model",
                polygon: mappedPolygon,
                translationLines: rawLines
            )
        }
        return blocks
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

    private static func visionCoordinateDivisor(
        rect: CGRect,
        polygon: [CGPoint],
        inputPixelSize: CGSize
    ) -> CGSize {
        let maxX = max(rect.maxX, polygon.map(\.x).max() ?? 0)
        let maxY = max(rect.maxY, polygon.map(\.y).max() ?? 0)
        let largest = max(maxX, maxY)
        if largest <= 1.5 {
            return CGSize(width: 1, height: 1)
        }
        if largest <= 100 {
            return CGSize(width: 100, height: 100)
        }
        return CGSize(
            width: max(inputPixelSize.width, 1),
            height: max(inputPixelSize.height, 1)
        )
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
        normalizeVisionRect(
            rect,
            divisor: visionCoordinateDivisor(
                rect: rect,
                polygon: [],
                inputPixelSize: inputPixelSize
            )
        )
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

    static func annotatedMangaTextBlocks(_ blocks: [TextBlock], safeAreaInset: Double, minimumTextHeight: Double, isRightToLeft: Bool) -> [TextBlock] {
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

    static func filteredMangaTextBlocks(_ blocks: [TextBlock], safeAreaInset: Double, minimumTextHeight: Double, isRightToLeft: Bool) -> [TextBlock] {
        annotatedMangaTextBlocks(blocks, safeAreaInset: safeAreaInset, minimumTextHeight: minimumTextHeight, isRightToLeft: isRightToLeft)
            .filter { !$0.isFiltered }
    }

    nonisolated static func groupedMangaTextBlocks(_ blocks: [TextBlock], isRightToLeft: Bool) -> [TextBlock] {
        let sorted = sortedTextBlocks(deduplicatedMangaTextBlocks(blocks, isRightToLeft: isRightToLeft), isRightToLeft: isRightToLeft)
        guard sorted.count > 1 else { return sorted }

        var groups: [TextBlock] = []
        for block in sorted {
            guard let last = groups.last else {
                groups.append(block)
                continue
            }

            if shouldMerge(last, with: block) {
                let merged = TextBlock(
                    id: last.id,
                    text: joinedOCRText(last.text, block.text),
                    boundingBox: last.boundingBox.union(block.boundingBox),
                    translation: last.translation,
                    confidence: max(last.confidence, block.confidence),
                    ocrSource: last.ocrSource,
                    estimatedFontScale: (last.estimatedFontScale + block.estimatedFontScale) / 2,
                    textColorHex: last.textColorHex
                )
                groups[groups.count - 1] = merged
            } else {
                groups.append(block)
            }
        }

        return sortedTextBlocks(groups, isRightToLeft: isRightToLeft)
    }

    nonisolated static func deduplicatedMangaTextBlocks(_ blocks: [TextBlock], isRightToLeft: Bool) -> [TextBlock] {
        var kept: [TextBlock] = []
        for block in sortedTextBlocks(blocks, isRightToLeft: isRightToLeft) {
            let normalized = normalizedOCRText(block.text)
            guard !normalized.isEmpty else { continue }
            if let existingIndex = kept.firstIndex(where: { existing in
                let overlap = existing.boundingBox.intersection(block.boundingBox)
                let overlapArea = overlap.isNull ? 0 : overlap.width * overlap.height
                let smallerArea = min(
                    rectArea(existing.boundingBox),
                    rectArea(block.boundingBox)
                )
                let overlapRatio = overlapArea / max(smallerArea, 0.0001)
                let centerDistance = hypot(
                    existing.boundingBox.midX - block.boundingBox.midX,
                    existing.boundingBox.midY - block.boundingBox.midY
                )
                let nearbyDuplicate = centerDistance <= max(
                    min(existing.boundingBox.height, block.boundingBox.height) * 0.75,
                    0.018
                )
                guard overlapRatio > 0.48 || nearbyDuplicate else { return false }
                let existingText = normalizedOCRText(existing.text)
                return existingText == normalized
                    || existingText.contains(normalized)
                    || normalized.contains(existingText)
                    || textSimilarity(existingText, normalized) > 0.72
            }) {
                let existing = kept[existingIndex]
                if block.confidence > existing.confidence || rectArea(block.boundingBox) > rectArea(existing.boundingBox) * 1.2 {
                    kept[existingIndex] = block
                }
            } else {
                kept.append(block)
            }
        }
        return sortedTextBlocks(kept, isRightToLeft: isRightToLeft)
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

    nonisolated private static func shouldMerge(_ lhsBlock: TextBlock, with rhsBlock: TextBlock) -> Bool {
        let lhs = lhsBlock.boundingBox
        let rhs = rhsBlock.boundingBox
        let lhsHeight = max(CGFloat(lhsBlock.estimatedFontScale), 0.001)
        let rhsHeight = max(CGFloat(rhsBlock.estimatedFontScale), 0.001)
        let smallerTextHeight = min(lhsHeight, rhsHeight)
        let largerTextHeight = max(lhsHeight, rhsHeight)

        // 不同字号通常属于不同气泡、旁白或页边标注；即便距离很近也不要强行合并。
        if largerTextHeight / smallerTextHeight > 1.32 {
            return false
        }
        if let lhsColor = lhsBlock.textColorHex,
           let rhsColor = rhsBlock.textColorHex,
           lhsColor.caseInsensitiveCompare(rhsColor) != .orderedSame {
            return false
        }

        let horizontalGap = max(0, max(lhs.minX, rhs.minX) - min(lhs.maxX, rhs.maxX))
        let verticalGap = max(0, max(lhs.minY, rhs.minY) - min(lhs.maxY, rhs.maxY))
        let maxSentenceGap = smallerTextHeight * 0.5
        if horizontalGap > maxSentenceGap && verticalGap > maxSentenceGap {
            return false
        }

        let union = lhs.union(rhs)
        guard union.width < 0.72, union.height < 0.28 else { return false }

        let rowCenterTolerance = smallerTextHeight * 0.72
        let columnCenterTolerance = max(min(lhs.width, rhs.width) * 0.62, smallerTextHeight * 0.9)
        let sameLine = abs(lhs.midY - rhs.midY) <= rowCenterTolerance && horizontalGap <= maxSentenceGap
        let sameBalloonColumn = abs(lhs.midX - rhs.midX) <= columnCenterTolerance && verticalGap <= maxSentenceGap

        return sameLine || sameBalloonColumn
    }

    nonisolated private static func joinedOCRText(_ lhs: String, _ rhs: String) -> String {
        let left = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty else { return right }
        guard !right.isEmpty else { return left }

        if left.hasSuffix("-") {
            return String(left.dropLast()) + right
        }
        if containsCJK(left) || containsCJK(right) {
            return left + right
        }
        let noSpaceBefore = CharacterSet(charactersIn: ".,!?;:)]}」』》）！？。，、；：")
        if let first = right.unicodeScalars.first, noSpaceBefore.contains(first) {
            return left + right
        }
        return left + " " + right
    }

    nonisolated private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let value = scalar.value
            return (0x4E00...0x9FFF).contains(value)
                || (0x3040...0x30FF).contains(value)
                || (0xAC00...0xD7AF).contains(value)
        }
    }

    nonisolated private static func normalizedOCRText(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[\\p{P}\\p{S}]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func textSimilarity(_ lhs: String, _ rhs: String) -> CGFloat {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        let leftSet = Set(lhs)
        let rightSet = Set(rhs)
        let intersection = leftSet.intersection(rightSet).count
        let union = leftSet.union(rightSet).count
        let setSimilarity = CGFloat(intersection) / CGFloat(max(union, 1))

        let left = Array(lhs)
        let right = Array(rhs)
        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1]
            for (rightIndex, rightCharacter) in right.enumerated() {
                let insertion = current[rightIndex] + 1
                let deletion = previous[rightIndex + 1] + 1
                let substitution = previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                current.append(min(insertion, deletion, substitution))
            }
            previous = current
        }
        let editDistance = previous.last ?? max(left.count, right.count)
        let editSimilarity = 1 - CGFloat(editDistance) / CGFloat(max(left.count, right.count, 1))
        return max(setSimilarity, editSimilarity)
    }

    nonisolated private static func rectArea(_ rect: CGRect) -> CGFloat {
        max(rect.width, 0) * max(rect.height, 0)
    }

    nonisolated static func sortedTextBlocks(_ blocks: [TextBlock], isRightToLeft: Bool) -> [TextBlock] {
        let validBlocks = blocks.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard validBlocks.count > 1 else { return validBlocks }

        let verticalCount = validBlocks.filter { block in
            block.boundingBox.height > block.boundingBox.width * 1.35
        }.count
        let isMostlyVertical = verticalCount > validBlocks.count / 2

        if isMostlyVertical {
            return validBlocks.sorted { lhs, rhs in
                let columnDistance = abs(lhs.boundingBox.midX - rhs.boundingBox.midX)
                if columnDistance > 0.045 {
                    return isRightToLeft ? lhs.boundingBox.midX > rhs.boundingBox.midX : lhs.boundingBox.midX < rhs.boundingBox.midX
                }
                return lhs.boundingBox.midY < rhs.boundingBox.midY
            }
        }

        return validBlocks.sorted { lhs, rhs in
            let rowDistance = abs(lhs.boundingBox.midY - rhs.boundingBox.midY)
            if rowDistance > 0.035 {
                return lhs.boundingBox.midY < rhs.boundingBox.midY
            }
            return isRightToLeft ? lhs.boundingBox.midX > rhs.boundingBox.midX : lhs.boundingBox.midX < rhs.boundingBox.midX
        }
    }
}
