from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text(encoding="utf-8")
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one match, found {count}: {old[:100]!r}")
    p.write_text(text.replace(old, new, 1), encoding="utf-8")


# 1) Settings connection probes: keep connection tests tiny and deterministic.
p = Path("mreader/AIProviderSettingsView.swift")
text = p.read_text(encoding="utf-8")
old_probe = '    static let prompt = "读取图片中央的 6 位大写字母/数字验证码。答案只存在于图片中。只返回你看到的验证码，不要解释。"'
new_probe = '    static let prompt = "这是视觉连通性测试。图片中央只有一行 6 位大写字母/数字验证码。请读取图片本身，只返回这 6 位验证码，不要解释、不要 JSON、不要猜测；确实看不清时返回 UNREADABLE。"'
if text.count(old_probe) != 1:
    raise SystemExit("AIProviderSettingsView.swift: vision probe prompt not found")
text = text.replace(old_probe, new_probe, 1)

marker = "\nstruct AIProviderSettingsView: View {"
if text.count(marker) != 1:
    raise SystemExit("AIProviderSettingsView.swift: insertion marker not found")
text_probe = r'''

nonisolated enum AITextConnectionProbe {
    static func makeChallengeCode(length: Int = 6) -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return "MR" + String((0..<max(length, 1)).compactMap { _ in alphabet.randomElement() })
    }

    static func prompt(for challenge: String) -> String {
        "这是 API 文本连通性测试。请只回复下面这一串验证码，不要解释、不要 Markdown、不要 JSON：\n\(challenge)"
    }

    static func response(_ response: String, contains challenge: String) -> Bool {
        let expected = normalizedASCIIAlphanumerics(challenge)
        guard !expected.isEmpty else { return false }
        return normalizedASCIIAlphanumerics(response).contains(expected)
    }

    private static func normalizedASCIIAlphanumerics(_ value: String) -> String {
        value.uppercased().unicodeScalars
            .filter { $0.value < 128 && CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }
}
'''
text = text.replace(marker, text_probe + marker, 1)

start = text.index("    private func testConnection(kind: ConnectionTestKind) {")
end = text.index("    private func visionProbePNGDataURL(code: String) -> String? {", start)
new_test_function = r'''    private func testConnection(kind: ConnectionTestKind) {
        let model = kind == .text
            ? (normalizedModels.contains(selectedTextModel) ? selectedTextModel : (normalizedModels.first ?? ""))
            : (visionModels.contains(selectedVisionModel) ? selectedVisionModel : (visionModels.first ?? ""))
        guard !model.isEmpty else { return }
        let modelDescriptor = descriptor(for: model)
        guard kind != .vision || modelDescriptor.supportsVision != false else {
            testFailed = true
            testMessage = "当前模型明确不支持视觉输入。"
            return
        }

        testingKind = kind
        testMessage = nil
        testFailed = false
        Task {
            defer { testingKind = nil }
            do {
                let request: AITransportRequest
                let challenge: String
                if kind == .vision {
                    challenge = AIVisionConnectionProbe.makeChallengeCode()
                    guard let imageURL = visionProbePNGDataURL(code: challenge) else {
                        throw AITranslationRequestError.invalidConfiguration("settings.imageEncodingFailed".localized)
                    }
                    request = AITransportRequest(
                        model: modelDescriptor,
                        systemPrompt: "你正在执行视觉 API 连通性测试。必须实际读取用户提供的图片并按用户要求给出最终文本答案。",
                        userPrompt: AIVisionConnectionProbe.prompt,
                        imageDataURL: imageURL,
                        temperature: 0,
                        maxTokens: 512,
                        timeout: AITranslationRequestPolicy.connectionTestTimeout,
                        kind: .connectionTest
                    )
                } else {
                    challenge = AITextConnectionProbe.makeChallengeCode()
                    request = AITransportRequest(
                        model: modelDescriptor,
                        systemPrompt: "你正在执行 API 连通性测试。请直接给出用户要求的最终文本，不要进入长推理。",
                        userPrompt: AITextConnectionProbe.prompt(for: challenge),
                        temperature: 0,
                        maxTokens: 256,
                        timeout: AITranslationRequestPolicy.connectionTestTimeout,
                        kind: .connectionTest
                    )
                }

                let data = try await AITranslationClient(apiKey: apiKey, baseURL: baseURL).send(request)
                let decoded = AIChatResponseDecoder.decode(data)
                guard let rawContent = decoded.content else {
                    testFailed = true
                    testMessage = decoded.hasReasoningOnly
                        ? "接口已返回，但输出预算被推理内容占用，没有最终答案。已提高测试预算；若仍出现此提示，请检查模型/API 协议。"
                        : "接口已返回，但没有可读取的最终文本。请检查模型对应的 API 协议。"
                    HapticManager.shared.play(.error)
                    return
                }
                let content = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !content.isEmpty else {
                    testFailed = true
                    testMessage = "接口已返回空文本。请检查模型对应的 API 协议。"
                    HapticManager.shared.play(.error)
                    return
                }

                let passed: Bool
                if kind == .vision {
                    passed = AIVisionConnectionProbe.response(content, contains: challenge)
                    if passed, modelDescriptor.supportsVision != true {
                        modelDescriptors[model] = AIModelDescriptor(
                            id: modelDescriptor.id,
                            apiProtocol: modelDescriptor.apiProtocol,
                            supportsVision: true
                        )
                    }
                } else {
                    passed = AITextConnectionProbe.response(content, contains: challenge)
                }

                guard passed else {
                    testFailed = true
                    let excerpt = String(content.prefix(180)).replacingOccurrences(of: "\n", with: " ")
                    testMessage = kind == .vision
                        ? "视觉接口可连接，但模型没有读出测试图片验证码。请检查视觉能力或 API 协议。返回：\(excerpt)"
                        : "文本接口可连接，但没有按测试协议返回验证码。请检查 API 协议。返回：\(excerpt)"
                    HapticManager.shared.play(.error)
                    return
                }

                testFailed = false
                let kindLabel = kind == .text
                    ? "settings.testTextConnection".localized
                    : "settings.testVisionConnection".localized
                testMessage = "settings.connectionSuccess".localizedFormat("\(kindLabel) · \(model)")
                HapticManager.shared.play(.success)
            } catch {
                testFailed = true
                testMessage = error.localizedDescription
                HapticManager.shared.play(.error)
            }
        }
    }

'''
text = text[:start] + new_test_function + text[end:]
p.write_text(text, encoding="utf-8")


# 2) Production vision translation contract and structured-output fallback.
p = Path("mreader/AITranslator.swift")
text = p.read_text(encoding="utf-8")
prompt_start = text.index('    nonisolated static let defaultVisionTranslationPromptTemplate = """')
prompt_end = text.index('    nonisolated static let defaultOCRVisualVerificationPromptTemplate', prompt_start)
new_prompt = r'''    nonisolated static let defaultVisionTranslationPromptTemplate = """
    你负责一整页漫画的文字识别与翻译。目标语言：{targetLanguage}。阅读顺序：{readingOrder}。

    只处理图片中真实可见的对白、旁白、拟声词和必要画面文字。视觉信息只能用于断句、阅读顺序、代词和语气消歧；不要描述人物、身体、动作、场景或剧情，不要总结、续写、解释，也不要补写图片中不存在的文字。忽略网址、广告、版权、水印和页码。

    分组规则：
    1. 一个真实物理气泡、一个旁白框或一个独立拟声词只能对应一个 item。
    2. 同一气泡里被切成多列、多行或多个识别碎片的文字，必须先按阅读顺序合并成一个 sourceText，再生成一个 translation；禁止为同一个气泡返回多个互相重叠的 items。
    3. 不同气泡、不同说话单元、明显独立的拟声词不要错误合并。
    4. translationLines 只表示最终译文的自然分行，不得通过重复或扩写文字去填满区域。

    几何与协议：
    - 顶层 coordinateSpace 固定为 "normalized"；全部坐标以整张输入图片左上角为原点，范围 0...1，禁止像素和百分比。
    - textBox 必须紧贴 sourceText 的真实文字范围。
    - bubbleBox 只表示真实物理气泡；没有气泡时必须返回 null，bubblePolygon 返回 []。
    - layoutSafeRegion 必须始终给出：有可靠气泡时取气泡内适合排字的保守区域；没有气泡时取 textBox 周围最小且不覆盖相邻文字的保守区域。
    - textPolygon / bubblePolygon 只有在可靠时给点；不可靠时返回 []，不要猜测轮廓。
    - confidence 是 0...1。classification 只能是 dialogue、narration 或 soundEffect。
    - 每个 item 必须包含 id、sourceText、translation、translationLines、textBox、bubbleBox、layoutSafeRegion、textPolygon、bubblePolygon、confidence、classification；不得使用 text、lines、polygon、center 等别名。

    只输出严格 JSON，不要 Markdown、解释或代码围栏：
    {
      "coordinateSpace": "normalized",
      "items": [
        {
          "id": "b0",
          "sourceText": "原文",
          "translation": "译文",
          "translationLines": ["译文"],
          "textBox": {"x": 0.10, "y": 0.20, "width": 0.30, "height": 0.08},
          "bubbleBox": null,
          "layoutSafeRegion": {"x": 0.09, "y": 0.19, "width": 0.32, "height": 0.10},
          "textPolygon": [],
          "bubblePolygon": [],
          "confidence": 0.90,
          "classification": "dialogue"
        }
      ]
    }
    如果没有可翻译文字，输出 {"coordinateSpace":"normalized","items":[]}。
    """

'''
text = text[:prompt_start] + new_prompt + text[prompt_end:]

old_system = '            systemPrompt = "你只做漫画图片中的文字识别、断句、翻译和精确坐标标注。只使用 coordinateSpace、items、id、sourceText、translation、translationLines、textBox、bubbleBox、layoutSafeRegion、textPolygon、bubblePolygon、confidence、classification 这一套 JSON 字段；不得描述画面，不得输出 JSON 之外的内容。"'
new_system = '            systemPrompt = "你只做漫画图片中文字识别、断句、翻译和坐标标注。同一物理气泡只能返回一个 item；同气泡碎片必须先合并。严格只输出约定 JSON；无气泡用 bubbleBox=null、bubblePolygon=[]，不得省略协议字段，不得描述画面。"'
if text.count(old_system) != 1:
    raise SystemExit("AITranslator.swift: translation vision system prompt not found")
text = text.replace(old_system, new_system, 1)

token_needle = "                    temperature: 0.1,\n                    timeout: AITranslationRequestPolicy.visionRequestTimeout,"
token_replacement = "                    temperature: 0.1,\n                    maxTokens: 4096,\n                    timeout: AITranslationRequestPolicy.visionRequestTimeout,"
if text.count(token_needle) != 1:
    raise SystemExit(f"AITranslator.swift: vision token budget marker count={text.count(token_needle)}")
text = text.replace(token_needle, token_replacement, 1)

old = '            || message.contains("invalid parameter")'
new = '            || message.contains("invalid parameter")\n            || message.contains("invalid schema")\n            || message.contains("schema validation")\n            || message.contains("invalid response format")'
if text.count(old) != 1:
    raise SystemExit(f"AITranslator.swift: first format fallback marker count={text.count(old)}")
text = text.replace(old, new, 1)

old = '                || normalized.contains("invalid parameter")'
new = '                || normalized.contains("invalid parameter")\n                || normalized.contains("invalid schema")\n                || normalized.contains("schema validation")\n                || normalized.contains("invalid response format")'
if text.count(old) != 1:
    raise SystemExit(f"AITranslator.swift: second format fallback marker count={text.count(old)}")
text = text.replace(old, new, 1)

schema_start = text.index("    private static func offlineVisionTranslationSchema() -> [String: Any] {")
schema_end = text.index("    static func assistantContentForDiagnostics", schema_start)
new_schema = r'''    private static func offlineVisionTranslationSchema() -> [String: Any] {
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
        let nullableRect: [String: Any] = ["anyOf": [rect, ["type": "null"]]]
        let polygon: [String: Any] = ["type": "array", "items": point]
        let item: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": [
                "id", "sourceText", "translation", "translationLines", "textBox",
                "bubbleBox", "layoutSafeRegion", "textPolygon", "bubblePolygon",
                "confidence", "classification"
            ],
            "properties": [
                "id": ["type": "string"],
                "sourceText": ["type": "string"],
                "translation": ["type": "string"],
                "translationLines": ["type": "array", "items": ["type": "string"]],
                "textBox": rect,
                "bubbleBox": nullableRect,
                "layoutSafeRegion": rect,
                "textPolygon": polygon,
                "bubblePolygon": polygon,
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

'''
text = text[:schema_start] + new_schema + text[schema_end:]
p.write_text(text, encoding="utf-8")


# 3) Regression coverage for overlap resolution and connection/prompt contracts.
Path("mreaderTests/TranslationOverlayCollisionTests.swift").write_text(r'''import CoreGraphics
import Testing
@testable import mreader

@Suite
struct TranslationOverlayCollisionTests {
    @Test func collisionResolverFindsAFreeSlotWhenOneExists() {
        let bounds = CGRect(x: 0, y: 0, width: 360, height: 500)
        let original = CGRect(x: 140, y: 180, width: 100, height: 54)
        let occupied = [
            CGRect(x: 132, y: 172, width: 116, height: 70),
            CGRect(x: 132, y: 110, width: 116, height: 60),
            CGRect(x: 132, y: 244, width: 116, height: 60)
        ]

        let result = OCRBubbleLayoutEngine.nonOverlappingRect(
            original,
            anchor: CGPoint(x: original.midX, y: original.midY),
            occupiedRects: occupied,
            bounds: bounds,
            margin: 8
        )

        #expect(bounds.insetBy(dx: 8, dy: 8).contains(result))
        #expect(!occupied.contains(where: { $0.intersects(result) }))
    }

    @Test func collisionResolverIsDeterministic() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 300)
        let original = CGRect(x: 100, y: 100, width: 90, height: 48)
        let occupied = [CGRect(x: 95, y: 95, width: 100, height: 58)]
        let anchor = CGPoint(x: original.midX, y: original.midY)

        let first = OCRBubbleLayoutEngine.nonOverlappingRect(
            original,
            anchor: anchor,
            occupiedRects: occupied,
            bounds: bounds,
            margin: 4
        )
        let second = OCRBubbleLayoutEngine.nonOverlappingRect(
            original,
            anchor: anchor,
            occupiedRects: occupied,
            bounds: bounds,
            margin: 4
        )

        #expect(first == second)
    }
}
''', encoding="utf-8")

Path("mreaderTests/AIConnectionProbeTests.swift").write_text(r'''import Testing
@testable import mreader

@Suite
struct AIConnectionProbeTests {
    @Test func textProbeAcceptsChallengeInsideMinimalFormatting() {
        let challenge = "MRABC234"
        #expect(AITextConnectionProbe.response("`MR-ABC234`", contains: challenge))
        #expect(!AITextConnectionProbe.response("OTHER", contains: challenge))
        #expect(!AITextConnectionProbe.response("ANYTHING", contains: ""))
    }

    @Test func visionProbeRequiresTheImageChallenge() {
        let challenge = "AB12CD"
        #expect(AIVisionConnectionProbe.response("AB12CD", contains: challenge))
        #expect(!AIVisionConnectionProbe.response("UNREADABLE", contains: challenge))
    }

    @Test func defaultVisionPromptKeepsSingleBubbleAndStrictGeometryContract() {
        let prompt = AITranslator.defaultVisionTranslationPromptTemplate
        #expect(prompt.contains("同一气泡"))
        #expect(prompt.contains("bubbleBox"))
        #expect(prompt.contains("null"))
        #expect(prompt.contains("layoutSafeRegion"))
        #expect(prompt.contains("translationLines"))
        #expect(prompt.contains("{targetLanguage}"))
        #expect(prompt.contains("{readingOrder}"))
    }
}
''', encoding="utf-8")
