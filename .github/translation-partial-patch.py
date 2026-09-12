from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one match, found {count}")
    p.write_text(text.replace(old, new, 1))


# AITranslator: expose explicit completeness metadata for ordinary vision translation.
p = Path("mreader/AITranslator.swift")
text = p.read_text()
marker = "class AITranslator {"
if marker not in text:
    raise SystemExit("AITranslator marker missing")
result_type = '''nonisolated struct AIVisionTranslationResult: Sendable {\n    let blocks: [TextBlock]\n    let failedSlices: Int\n    let missingBlockIDs: [UUID]\n\n    var isComplete: Bool {\n        failedSlices == 0 && missingBlockIDs.isEmpty\n    }\n}\n\n'''
if "struct AIVisionTranslationResult" not in text:
    text = text.replace(marker, result_type + marker, 1)

start = text.index("    static func translateVisionPage(\n")
end = text.index("    static func recognizeVisionPage(\n", start)
new_section = '''    static func translateVisionPage(\n        image: UIImage,\n        apiKey: String,\n        baseURL: String,\n        visionModel: String,\n        textFallbackModel: String,\n        targetLanguage: String = TranslationTargetLanguage.simplifiedChinese.rawValue,\n        promptTemplate: String = defaultVisionTranslationPromptTemplate,\n        isRightToLeft: Bool = false,\n        viewportAspect: CGFloat = 2.0,\n        sourceLanguage: TranslationSourceLanguage? = nil,\n        visionModelDescriptor: AIModelDescriptor? = nil,\n        textFallbackModelDescriptor: AIModelDescriptor? = nil\n    ) async throws -> [TextBlock] {\n        let result = try await translateVisionPageWithStatus(\n            image: image,\n            apiKey: apiKey,\n            baseURL: baseURL,\n            visionModel: visionModel,\n            textFallbackModel: textFallbackModel,\n            targetLanguage: targetLanguage,\n            promptTemplate: promptTemplate,\n            isRightToLeft: isRightToLeft,\n            viewportAspect: viewportAspect,\n            sourceLanguage: sourceLanguage,\n            visionModelDescriptor: visionModelDescriptor,\n            textFallbackModelDescriptor: textFallbackModelDescriptor\n        )\n        return result.blocks\n    }\n\n    static func translateVisionPageWithStatus(\n        image: UIImage,\n        apiKey: String,\n        baseURL: String,\n        visionModel: String,\n        textFallbackModel: String,\n        targetLanguage: String = TranslationTargetLanguage.simplifiedChinese.rawValue,\n        promptTemplate: String = defaultVisionTranslationPromptTemplate,\n        isRightToLeft: Bool = false,\n        viewportAspect: CGFloat = 2.0,\n        sourceLanguage: TranslationSourceLanguage? = nil,\n        visionModelDescriptor: AIModelDescriptor? = nil,\n        textFallbackModelDescriptor: AIModelDescriptor? = nil\n    ) async throws -> AIVisionTranslationResult {\n        let target = TranslationTargetLanguage.migrateLegacyValue(targetLanguage)\n        let recognition = try await recognizeVisionPageUsingModelWithStats(\n            image: image,\n            apiKey: apiKey,\n            baseURL: baseURL,\n            model: visionModel,\n            modelDescriptor: visionModelDescriptor ?? AIModelProtocolCatalog.descriptor(for: visionModel),\n            isRightToLeft: isRightToLeft,\n            viewportAspect: viewportAspect,\n            additionalInstructions: \"\",\n            translationTarget: target,\n            translationPromptTemplate: promptTemplate,\n            strictTranslationGeometry: false\n        )\n        try Task.checkCancellation()\n\n        var translated = recognition.blocks\n        let missingIndexes = translated.indices.filter {\n            (translated[$0].translation ?? \"\").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty\n        }\n        if !missingIndexes.isEmpty {\n            let missingBlocks = missingIndexes.map { translated[$0] }\n            let pageResult = try await translatePage(\n                blocks: missingBlocks,\n                apiKey: apiKey,\n                baseURL: baseURL,\n                model: textFallbackModel,\n                target: target,\n                promptTemplate: defaultTranslationPromptTemplate,\n                sourceLanguage: sourceLanguage,\n                modelDescriptor: textFallbackModelDescriptor ?? AIModelProtocolCatalog.descriptor(for: textFallbackModel)\n            )\n            for (position, index) in missingIndexes.enumerated() {\n                if let result = pageResult.translation(for: \"b\\(position)\") {\n                    translated[index].translation = result.translation\n                    translated[index].translationLines = result.translationLines\n                }\n            }\n        }\n\n        let completed = translated.filter {\n            !($0.translation ?? \"\").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty\n        }\n        guard !completed.isEmpty else { throw VisionTranslationError.emptyResult }\n        let missingBlockIDs = translated.compactMap { block -> UUID? in\n            let translation = (block.translation ?? \"\").trimmingCharacters(in: .whitespacesAndNewlines)\n            return translation.isEmpty ? block.id : nil\n        }\n        return AIVisionTranslationResult(\n            blocks: translated,\n            failedSlices: recognition.failedSlices,\n            missingBlockIDs: missingBlockIDs\n        )\n    }\n\n'''
text = text[:start] + new_section + text[end:]
p.write_text(text)


# Runtime boundary: expose the status-bearing call without changing legacy callers.
p = Path("mreader/TranslationRuntimeService.swift")
text = p.read_text()
insert = '''\n    static func translateVisionPageWithStatus(\n        image: UIImage,\n        apiKey: String,\n        baseURL: String,\n        visionModel: String,\n        textFallbackModel: String,\n        targetLanguage: String = TranslationTargetLanguage.simplifiedChinese.rawValue,\n        promptTemplate: String = AITranslator.defaultVisionTranslationPromptTemplate,\n        isRightToLeft: Bool = false,\n        viewportAspect: CGFloat = 2.0,\n        sourceLanguage: TranslationSourceLanguage? = nil,\n        visionModelDescriptor: AIModelDescriptor? = nil,\n        textFallbackModelDescriptor: AIModelDescriptor? = nil\n    ) async throws -> AIVisionTranslationResult {\n        try await AITranslator.translateVisionPageWithStatus(\n            image: image,\n            apiKey: apiKey,\n            baseURL: baseURL,\n            visionModel: visionModel,\n            textFallbackModel: textFallbackModel,\n            targetLanguage: targetLanguage,\n            promptTemplate: promptTemplate,\n            isRightToLeft: isRightToLeft,\n            viewportAspect: viewportAspect,\n            sourceLanguage: sourceLanguage,\n            visionModelDescriptor: visionModelDescriptor,\n            textFallbackModelDescriptor: textFallbackModelDescriptor\n        )\n    }\n'''
if "translateVisionPageWithStatus" not in text:
    head, tail = text.rsplit("\n}", 1)
    text = head + insert + "\n}" + tail
p.write_text(text)


# Coordinator/pipeline: cache only outputs explicitly known to be complete.
replace_once(
    "mreader/AITranslationPageCoordinator.swift",
    '''nonisolated struct AITranslationOCRResult: Sendable {\n    let blocks: [TextBlock]\n    let missingBlockIDs: [UUID]\n}\n''',
    '''nonisolated struct AITranslationOCRResult: Sendable {\n    let blocks: [TextBlock]\n    let missingBlockIDs: [UUID]\n}\n\nnonisolated struct AITranslationPipelineResult: Sendable {\n    let blocks: [TextBlock]\n    let isComplete: Bool\n}\n'''
)
replace_once(
    "mreader/AITranslationPageCoordinator.swift",
    "private var inFlight: [String: Task<[TextBlock], Error>] = [:]",
    "private var inFlight: [String: Task<AITranslationPipelineResult, Error>] = [:]"
)
replace_once(
    "mreader/AITranslationPageCoordinator.swift",
    '''        if let existing = inFlight[key] {\n            print("MReader AI translation joined in-flight key=\\(key.prefix(10))")\n            return try await existing.value\n        }\n''',
    '''        if let existing = inFlight[key] {\n            print("MReader AI translation joined in-flight key=\\(key.prefix(10))")\n            return try await existing.value.blocks\n        }\n'''
)
replace_once(
    "mreader/AITranslationPageCoordinator.swift",
    '''        do {\n            let blocks = try await task.value\n            inFlight[key] = nil\n            store(blocks, forKey: key)\n            return blocks\n        } catch {\n''',
    '''        do {\n            let result = try await task.value\n            inFlight[key] = nil\n            if result.isComplete {\n                store(result.blocks, forKey: key)\n            } else {\n                print("MReader AI translation cache skipped explicit partial key=\\(key.prefix(10)) blocks=\\(result.blocks.count)")\n            }\n            return result.blocks\n        } catch {\n'''
)

p = Path("mreader/AITranslationPageCoordinator.swift")
text = p.read_text()
start = text.index("    static func translate(_ request: AITranslationPageRequest) async throws -> [TextBlock] {")
end = text.index("    /// Vision 明确返回空页", start)
new_pipeline = '''    static func translate(_ request: AITranslationPageRequest) async throws -> AITranslationPipelineResult {\n        switch request.mode {\n        case .ocr:\n            let result = try await translateOCRPageWithStatus(request)\n            return AITranslationPipelineResult(\n                blocks: result.blocks,\n                isComplete: result.missingBlockIDs.isEmpty\n            )\n        case .vision:\n            let result = try await TranslationRuntimeService.translateVisionPageWithStatus(\n                image: request.image,\n                apiKey: request.configuration.apiKey,\n                baseURL: request.configuration.baseURL,\n                visionModel: request.configuration.visionModel,\n                textFallbackModel: request.configuration.textModel,\n                targetLanguage: request.target.rawValue,\n                promptTemplate: request.visionPromptTemplate,\n                isRightToLeft: request.isRightToLeft,\n                viewportAspect: request.viewportAspect,\n                sourceLanguage: request.sourceLanguagePreference,\n                visionModelDescriptor: request.configuration.visionModelDescriptor,\n                textFallbackModelDescriptor: request.configuration.textModelDescriptor\n            )\n            return AITranslationPipelineResult(\n                blocks: result.blocks,\n                isComplete: result.isComplete\n            )\n        }\n    }\n\n'''
text = text[:start] + new_pipeline + text[end:]
p.write_text(text)


# Regression coverage for explicit slice-level partial state.
p = Path("mreaderTests/TranslationReliabilityRegressionTests.swift")
text = p.read_text()
needle = "    func testReadingOrderIsStableAcrossPermutationCounterexample() {"
case = '''    func testFailedVisionSliceCannotBeMarkedComplete() {\n        let result = AIVisionTranslationResult(\n            blocks: [],\n            failedSlices: 1,\n            missingBlockIDs: []\n        )\n        XCTAssertFalse(result.isComplete)\n    }\n\n'''
if case not in text:
    if needle not in text:
        raise SystemExit("test insertion point missing")
    text = text.replace(needle, case + needle, 1)
p.write_text(text)
