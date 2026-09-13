import Foundation
import os

/// MReader 统一日志出口。
///
/// 规则（审查 #10）：
/// - Release 只记录**内容无关**的元数据：错误类型、provider / 模型名、HTTP 状态、
///   响应体字节数、block / page 标识。
/// - **绝不**记录 `sourceText`、`translation`、模型原始响应、`Authorization`、API Key。
///   因此日志里一律使用 `MReaderLog.describe(_:)` 或错误自身的 `logSummary`，
///   而不是 `error.localizedDescription`（后者可能内嵌模型返回片段）。
/// - 确实需要原始响应时，必须由用户显式打开「AI 诊断日志」开关；默认关闭，
///   关闭状态下连字符串都不会被构造。
nonisolated enum MReaderLog {
    static let subsystem = "cn.mreader.app"

    static let ai = Logger(subsystem: subsystem, category: "ai")
    static let aiPage = Logger(subsystem: subsystem, category: "ai.page")
    static let aiVision = Logger(subsystem: subsystem, category: "ai.vision")
    static let aiTranslation = Logger(subsystem: subsystem, category: "ai.translation")
    static let aiTransport = Logger(subsystem: subsystem, category: "ai.transport")
    static let reader = Logger(subsystem: subsystem, category: "reader")

    /// 「AI 诊断日志」开关的 UserDefaults key（用户主动开启后才允许记录内容片段）。
    static let contentLoggingDefaultsKey = "ai_diagnostic_content_logging"

    static var isContentLoggingEnabled: Bool {
        UserDefaults.standard.bool(forKey: contentLoggingDefaultsKey)
    }

    /// 内容无关的错误摘要。任何进入日志的错误都必须先经过这里。
    static func describe(_ error: Error) -> String {
        AIErrorLogSummary.summary(for: error)
    }

    /// 只在用户开启诊断日志时记录内容片段；关闭时 `message` 闭包根本不会求值。
    /// 使用 `.private` 让值在系统日志中默认被脱敏。
    static func content(
        _ message: @escaping @autoclosure () -> String,
        logger: Logger = MReaderLog.ai,
        isError: Bool = false
    ) {
        guard isContentLoggingEnabled else { return }
        if isError {
            logger.error("\(message(), privacy: .private)")
        } else {
            logger.debug("\(message(), privacy: .private)")
        }
    }
}

/// 把各类 AI 错误压成不含原文 / 译文 / 原始响应体的结构化摘要。
nonisolated enum AIErrorLogSummary {
    static func summary(for error: Error) -> String {
        if let error = error as? AITranslationRequestError {
            return error.logSummary
        }
        if let error = error as? AITranslator.VisionTranslationError {
            return error.logSummary
        }
        if let error = error as? AIPageTranslationParserError {
            return error.logSummary
        }
        if let error = error as? URLError {
            return "URLError(code=\(error.code.rawValue))"
        }
        if error is CancellationError {
            return "CancellationError"
        }
        // 未知错误只记录类型：`localizedDescription` 可能内嵌响应体或部分 JSON。
        return "error(\(String(describing: type(of: error))))"
    }
}

extension AITranslationRequestError {
    /// 内容无关摘要：模型名、HTTP 状态、重试等待、响应体字节数。
    /// 明文的 `message` 与 `excerpt` 一律不进入日志。
    nonisolated var logSummary: String {
        switch self {
        case .invalidConfiguration:
            return "invalidConfiguration"
        case .server(let model, let statusCode, _):
            return "server(model=\(model),status=\(statusCode.map(String.init) ?? "none"))"
        case .serverWithRetryAfter(let model, let statusCode, _, let retryAfterSeconds):
            return "server(model=\(model),status=\(statusCode.map(String.init) ?? "none"),retryAfter=\(retryAfterSeconds.map(String.init) ?? "none"))"
        case .invalidResponse(let model):
            return "invalidResponse(model=\(model))"
        case .invalidResponseEnvelope(let model, let contentType, let excerpt):
            return "invalidResponseEnvelope(model=\(model),contentType=\(contentType ?? "unknown"),bytes=\(excerpt.utf8.count))"
        case .missingAssistantContent(let model, let finishReason):
            return "missingAssistantContent(model=\(model),finishReason=\(finishReason ?? "none"))"
        case .invalidTranslationJSON(let model, let excerpt):
            return "invalidTranslationJSON(model=\(model),bytes=\(excerpt.utf8.count))"
        case .invalidTranslationLanguage(let model):
            return "invalidTranslationLanguage(model=\(model))"
        case .incompleteResponse(let model, let finishReason):
            return "incompleteResponse(model=\(model),finishReason=\(finishReason))"
        }
    }
}

extension AITranslator.VisionTranslationError {
    nonisolated var logSummary: String {
        switch self {
        case .api: return "api"
        case .imageEncodingFailed: return "imageEncodingFailed"
        case .invalidJSON: return "invalidJSON"
        case .invalidCoordinates: return "invalidCoordinates"
        case .missingTextBox: return "missingTextBox"
        case .missingTranslation: return "missingTranslation"
        case .protocolViolation: return "protocolViolation"
        case .emptyResult: return "emptyResult"
        }
    }
}

extension AIPageTranslationParserError {
    nonisolated var logSummary: String {
        switch self {
        case .invalidJSON: return "invalidJSON"
        case .emptyResult: return "emptyResult"
        case .pageLanguageMismatch: return "pageLanguageMismatch"
        }
    }
}
