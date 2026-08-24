import UIKit

/// 翻译运行时边界。AITranslator 保留现有诊断接口与兼容 façade，阅读器和协调器
/// 通过此服务调用网络翻译/视觉 OCR，避免把 provider 细节继续扩散到 UI。
nonisolated enum TranslationRuntimeService {
    static func translate(
        text: String,
        ocrMetadata: String = "",
        pageContext: String = "",
        apiKey: String,
        baseURL: String,
        model: String,
        targetLanguage: TranslationTargetLanguage = .simplifiedChinese,
        promptTemplate: String = AITranslator.defaultTranslationPromptTemplate,
        requestTimeout: TimeInterval = 45,
        modelDescriptor: AIModelDescriptor? = nil
    ) async throws -> String {
        try await AITranslator.translate(
            text: text,
            ocrMetadata: ocrMetadata,
            pageContext: pageContext,
            apiKey: apiKey,
            baseURL: baseURL,
            model: model,
            targetLanguage: targetLanguage,
            promptTemplate: promptTemplate,
            requestTimeout: requestTimeout,
            modelDescriptor: modelDescriptor
        )
    }

    static func translatePage(
        blocks: [TextBlock],
        apiKey: String,
        baseURL: String,
        model: String,
        target: TranslationTargetLanguage,
        promptTemplate: String = AITranslator.defaultTranslationPromptTemplate,
        sourceLanguage: TranslationSourceLanguage? = nil,
        previousContext: String = "",
        modelDescriptor: AIModelDescriptor? = nil
    ) async throws -> AIPageTranslationResult {
        try await AITranslator.translatePage(
            blocks: blocks,
            apiKey: apiKey,
            baseURL: baseURL,
            model: model,
            target: target,
            promptTemplate: promptTemplate,
            sourceLanguage: sourceLanguage,
            previousContext: previousContext,
            modelDescriptor: modelDescriptor
        )
    }

    static func visualVerifyOCRRegions(
        image: UIImage,
        blocks: [TextBlock],
        apiKey: String,
        baseURL: String,
        model: String,
        isRightToLeft: Bool,
        modelDescriptor: AIModelDescriptor? = nil
    ) async throws -> [TextBlock] {
        try await AITranslator.visualVerifyOCRRegions(
            image: image,
            blocks: blocks,
            apiKey: apiKey,
            baseURL: baseURL,
            model: model,
            isRightToLeft: isRightToLeft,
            modelDescriptor: modelDescriptor
        )
    }

    static func translateVisionPage(
        image: UIImage,
        apiKey: String,
        baseURL: String,
        visionModel: String,
        textFallbackModel: String,
        targetLanguage: String = TranslationTargetLanguage.simplifiedChinese.rawValue,
        promptTemplate: String = AITranslator.defaultVisionTranslationPromptTemplate,
        isRightToLeft: Bool = false,
        viewportAspect: CGFloat = 2.0,
        sourceLanguage: TranslationSourceLanguage? = nil,
        visionModelDescriptor: AIModelDescriptor? = nil,
        textFallbackModelDescriptor: AIModelDescriptor? = nil
    ) async throws -> [TextBlock] {
        try await AITranslator.translateVisionPage(
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
            visionModelDescriptor: visionModelDescriptor,
            textFallbackModelDescriptor: textFallbackModelDescriptor
        )
    }
}
