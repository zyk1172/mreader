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
        requestTimeout: TimeInterval = AITranslationRequestPolicy.bubbleRequestTimeout,
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
        modelDescriptor: AIModelDescriptor? = nil,
        sourceLanguagePreference: TranslationSourceLanguage? = nil,
        detectedLanguage: String? = nil,
        visualVerificationEnabled: Bool = true,
        coverageRecoveryRequested: Bool = false
    ) async throws -> [TextBlock] {
        try await AITranslator.visualVerifyOCRRegions(
            image: image,
            blocks: blocks,
            apiKey: apiKey,
            baseURL: baseURL,
            model: model,
            isRightToLeft: isRightToLeft,
            modelDescriptor: modelDescriptor,
            sourceLanguagePreference: sourceLanguagePreference,
            detectedLanguage: detectedLanguage,
            visualVerificationEnabled: visualVerificationEnabled,
            coverageRecoveryRequested: coverageRecoveryRequested
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
        previousContext: String = "",
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
            previousContext: previousContext,
            visionModelDescriptor: visionModelDescriptor,
            textFallbackModelDescriptor: textFallbackModelDescriptor
        )
    }

    /// 视觉链路原文真实性复核：对可疑 block 裁剪局部图片做 text-first 复核，
    /// 只重新确认 sourceText；被修正的 block 由调用方单独重译（审查 #3）。
    static func reverifyVisionSourceTexts(
        image: UIImage,
        blocks: [TextBlock],
        apiKey: String,
        baseURL: String,
        visionModel: String,
        visionModelDescriptor: AIModelDescriptor? = nil,
        sourceLanguagePreference: TranslationSourceLanguage? = nil,
        maximumRegionCount: Int = 6
    ) async throws -> AITranslator.VisionSourceReviewResult {
        try await AITranslator.reverifyVisionSourceText(
            image: image,
            blocks: blocks,
            apiKey: apiKey,
            baseURL: baseURL,
            model: visionModel,
            modelDescriptor: visionModelDescriptor,
            sourceLanguagePreference: sourceLanguagePreference,
            maximumRegionCount: maximumRegionCount
        )
    }

    static func translateVisionPageWithStatus(
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
        previousContext: String = "",
        visionModelDescriptor: AIModelDescriptor? = nil,
        textFallbackModelDescriptor: AIModelDescriptor? = nil
    ) async throws -> AIVisionTranslationResult {
        try await AITranslator.translateVisionPageWithStatus(
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
    }
}
