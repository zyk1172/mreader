import Foundation

nonisolated enum AIAPIProtocol: String, Codable, CaseIterable, Sendable {
    case openAIChatCompletions
    case openAIResponses
    case anthropicMessages

    var displayName: String {
        switch self {
        case .openAIChatCompletions:
            return "Chat Completions"
        case .openAIResponses:
            return "Responses"
        case .anthropicMessages:
            return "Anthropic Messages"
        }
    }
}

nonisolated struct AIModelDescriptor: Codable, Hashable, Sendable {
    let id: String
    var apiProtocol: AIAPIProtocol
    /// nil means unknown. Unknown models remain selectable, but the UI can warn
    /// before using them as a vision model.
    var supportsVision: Bool?

    init(
        id: String,
        apiProtocol: AIAPIProtocol = .openAIChatCompletions,
        supportsVision: Bool? = nil
    ) {
        self.id = id
        self.apiProtocol = apiProtocol
        self.supportsVision = supportsVision
    }
}

/// The OpenCode Go catalog is intentionally local and conservative. A user can
/// override any entry in the provider editor, and unknown models default to the
/// legacy Chat Completions behavior.
nonisolated enum AIModelProtocolCatalog {
    static func descriptor(for modelID: String) -> AIModelDescriptor {
        let id = normalizedModelID(modelID)
        let apiProtocol: AIAPIProtocol
        switch id {
        case "grok-4.5", "gpt-5.6-luna", "muse-spark-1.2-contributor":
            apiProtocol = .openAIResponses
        case "minimax-m3", "minimax-m2.7", "minimax-m2.5",
             "qwen3.8-max", "qwen3.7-max", "qwen3.7-plus", "qwen3.6-plus":
            apiProtocol = .anthropicMessages
        default:
            apiProtocol = .openAIChatCompletions
        }
        return AIModelDescriptor(id: modelID, apiProtocol: apiProtocol)
    }

    static func normalizedModelID(_ modelID: String) -> String {
        var value = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("opencode-go/") {
            value.removeFirst("opencode-go/".count)
        }
        return value
    }

    /// OpenCode's configuration uses `opencode-go/<model-id>`, while its API
    /// table and request body use the bare model ID.
    static func apiModelID(for modelID: String) -> String {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "opencode-go/"
        guard trimmed.lowercased().hasPrefix(prefix) else { return trimmed }
        return String(trimmed.dropFirst(prefix.count))
    }

    static func descriptors(
        for models: [String], existing: [AIModelDescriptor] = []
    ) -> [AIModelDescriptor] {
        let existingByID = Dictionary(
            existing.map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        return models.map { model in
            existingByID[model] ?? descriptor(for: model)
        }
    }
}

nonisolated enum AITransportResponseFormat: Sendable, Equatable {
    case jsonObject
    case jsonSchema(name: String, schema: Data)
}

nonisolated struct AITransportRequest: Sendable {
    let model: AIModelDescriptor
    let systemPrompt: String?
    let userPrompt: String
    let imageDataURL: String?
    let responseFormat: AITransportResponseFormat?
    let temperature: Double?
    let maxTokens: Int?
    let timeout: TimeInterval

    init(
        model: AIModelDescriptor,
        systemPrompt: String? = nil,
        userPrompt: String,
        imageDataURL: String? = nil,
        responseFormat: AITransportResponseFormat? = nil,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        timeout: TimeInterval = 60
    ) {
        self.model = model
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.imageDataURL = imageDataURL
        self.responseFormat = responseFormat
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.timeout = timeout
    }
}

nonisolated protocol AITransporting: Sendable {
    func send(_ request: AITransportRequest) async throws -> Data
}

/// One production HTTP client for text, page translation, OCR verification and
/// settings connection tests. The URLSession is injectable for unit tests.
nonisolated final class AITranslationClient: AITransporting, @unchecked Sendable {
    private let apiKey: String
    private let baseURL: String
    private let session: URLSession
    private let requestObserver: ((URLRequest) -> Void)?

    init(
        apiKey: String,
        baseURL: String,
        session: URLSession = .shared,
        requestObserver: ((URLRequest) -> Void)? = nil
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
        self.requestObserver = requestObserver
    }

    func send(_ request: AITransportRequest) async throws -> Data {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AITranslationRequestError.invalidConfiguration("未配置 API Key")
        }
        guard !request.model.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AITranslationRequestError.invalidConfiguration("未配置模型")
        }
        if request.imageDataURL != nil, request.model.supportsVision == false {
            throw AIProviderStoreError.unsupportedVisionModel
        }
        guard let url = AIEndpointResolver.endpointURL(
            for: request.model.apiProtocol,
            from: baseURL
        ) else {
            throw AITranslationRequestError.invalidConfiguration("接口地址无效")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = request.timeout
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addAuthenticationHeaders(to: &urlRequest, protocol: request.model.apiProtocol)
        urlRequest.httpBody = try makeBody(for: request)
        requestObserver?(urlRequest)

        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AITranslationRequestError.invalidConfiguration("响应无效")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AITranslationRequestError.serverWithRetryAfter(
                model: request.model.id,
                statusCode: httpResponse.statusCode,
                message: Self.apiErrorMessage(from: data)
                    ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode),
                retryAfterSeconds: Self.retryAfterSeconds(from: httpResponse)
            )
        }
        if let message = Self.apiErrorMessage(from: data) {
            throw AITranslationRequestError.server(model: request.model.id, statusCode: nil, message: message)
        }
        return data
    }

    private func addAuthenticationHeaders(
        to request: inout URLRequest,
        protocol apiProtocol: AIAPIProtocol
    ) {
        switch apiProtocol {
        case .anthropicMessages:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openAIChatCompletions, .openAIResponses:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
    }

    private func makeBody(for request: AITransportRequest) throws -> Data {
        let model = AIModelProtocolCatalog.apiModelID(for: request.model.id)
        let body: [String: Any]
        switch request.model.apiProtocol {
        case .openAIChatCompletions:
            body = makeChatCompletionsBody(for: request, model: model)
        case .openAIResponses:
            body = makeResponsesBody(for: request, model: model)
        case .anthropicMessages:
            body = try makeAnthropicMessagesBody(for: request, model: model)
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    private func makeChatCompletionsBody(
        for request: AITransportRequest,
        model: String
    ) -> [String: Any] {
        var messages: [[String: Any]] = []
        if let systemPrompt = request.systemPrompt, !systemPrompt.isEmpty {
            messages.append(["role": "system", "content": systemPrompt])
        }
        let userContent: Any
        if let imageDataURL = request.imageDataURL {
            userContent = [
                ["type": "text", "text": request.userPrompt],
                ["type": "image_url", "image_url": ["url": imageDataURL]]
            ]
        } else {
            userContent = request.userPrompt
        }
        messages.append(["role": "user", "content": userContent])

        var body: [String: Any] = ["model": model, "messages": messages]
        if let temperature = request.temperature { body["temperature"] = temperature }
        if let maxTokens = request.maxTokens { body["max_tokens"] = maxTokens }
        if let responseFormat = request.responseFormat {
            body["response_format"] = Self.chatResponseFormat(responseFormat)
        }
        return body
    }

    private func makeResponsesBody(
        for request: AITransportRequest,
        model: String
    ) -> [String: Any] {
        var content: [[String: Any]] = [[
            "type": "input_text",
            "text": request.userPrompt
        ]]
        if let imageDataURL = request.imageDataURL {
            content.append([
                "type": "input_image",
                "image_url": imageDataURL
            ])
        }
        let input: [[String: Any]] = [[
            "role": "user",
            "content": content
        ]]

        var body: [String: Any] = [
            "model": model,
            "input": input
        ]
        if let systemPrompt = request.systemPrompt, !systemPrompt.isEmpty {
            body["instructions"] = systemPrompt
        }
        if let maxTokens = request.maxTokens { body["max_output_tokens"] = maxTokens }
        if let responseFormat = request.responseFormat {
            body["text"] = ["format": Self.responsesResponseFormat(responseFormat)]
        }
        // Responses reasoning models and OpenCode Go do not share Chat
        // Completions' temperature contract; omit it deliberately.
        return body
    }

    private func makeAnthropicMessagesBody(
        for request: AITransportRequest,
        model: String
    ) throws -> [String: Any] {
        var messages: [[String: Any]] = []
        if let imageDataURL = request.imageDataURL {
            guard let source = Self.anthropicImageSource(from: imageDataURL) else {
                throw AITranslationRequestError.invalidConfiguration("图片格式无效")
            }
            messages.append([
                "role": "user",
                "content": [
                    source,
                    ["type": "text", "text": request.userPrompt]
                ]
            ])
        } else {
            messages.append([
                "role": "user",
                "content": [["type": "text", "text": request.userPrompt]]
            ])
        }

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "max_tokens": request.maxTokens ?? 1024
        ]
        if let systemPrompt = request.systemPrompt, !systemPrompt.isEmpty {
            body["system"] = systemPrompt
        }
        if let temperature = request.temperature { body["temperature"] = temperature }
        // Anthropic Messages has no portable response_format equivalent. The
        // prompt remains the source of truth for strict JSON responses.
        return body
    }

    private static func chatResponseFormat(_ format: AITransportResponseFormat) -> [String: Any] {
        switch format {
        case .jsonObject:
            return ["type": "json_object"]
        case .jsonSchema(let name, let schema):
            let schemaObject = (try? JSONSerialization.jsonObject(with: schema)) ?? [:]
            return [
                "type": "json_schema",
                "json_schema": ["name": name, "strict": true, "schema": schemaObject]
            ]
        }
    }

    private static func responsesResponseFormat(_ format: AITransportResponseFormat) -> [String: Any] {
        switch format {
        case .jsonObject:
            return ["type": "json_object"]
        case .jsonSchema(let name, let schema):
            let schemaObject = (try? JSONSerialization.jsonObject(with: schema)) ?? [:]
            return [
                "type": "json_schema",
                "name": name,
                "strict": true,
                "schema": schemaObject
            ]
        }
    }

    private static func anthropicImageSource(from dataURL: String) -> [String: Any]? {
        let parts = dataURL.split(separator: ",", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              parts[0].hasPrefix("data:image/"),
              parts[0].contains(";base64"),
              let separator = parts[0].firstIndex(of: ":"),
              let mediaEnd = parts[0].firstIndex(of: ";") else {
            return nil
        }
        let mediaType = String(parts[0][parts[0].index(after: separator)..<mediaEnd])
        return [
            "type": "image",
            "source": [
                "type": "base64",
                "media_type": mediaType,
                "data": parts[1]
            ]
        ]
    }

    private static func apiErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let error = json["error"] as? [String: Any] {
            if let message = error["message"] as? String, !message.isEmpty { return message }
            if let code = error["code"] as? String, !code.isEmpty { return code }
            if let type = error["type"] as? String, !type.isEmpty { return type }
        }
        if let message = json["message"] as? String, !message.isEmpty { return message }
        return nil
    }

    private static func retryAfterSeconds(from response: HTTPURLResponse) -> UInt64? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              seconds >= 0 else {
            return nil
        }
        return UInt64(ceil(seconds))
    }
}
