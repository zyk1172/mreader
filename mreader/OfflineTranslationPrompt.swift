import Foundation

nonisolated enum OfflineVisionPageResult: Sendable {
    case translated([TextBlock])
    case partial([TextBlock], failedSlices: Int)
    case noText
}

nonisolated enum OfflineTranslationPromptBuilder {
    static let revision = "offline-vision-v6-translation-evidence-hierarchy"

    static func make(
        sourceLanguage: TranslationSourceLanguage,
        targetLanguage: TranslationTargetLanguage,
        isRightToLeft: Bool,
        styleInstructions: String,
        previousContext: String
    ) -> String {
        let source = sourceLanguage == .automatic ? "自动识别（只根据页面文字判断）" : sourceLanguage.rawValue
        let direction = isRightToLeft
            ? "从右到左、从上到下（右开本日漫）"
            : "从左到右、从上到下"
        let style = styleInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = previousContext.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        你是漫画整页离线翻译器。只处理输入图片中的文字气泡、旁白和拟声词，不描述画面，不识别人物身份，不输出解释。

        原文语言偏好：\(source)
        目标语言：\(targetLanguage.modelInstruction)
        阅读顺序：\(direction)

        上下文快照（可能同时包含前序原文、已确认原文→译文对照和同批次预识别原文；仅用于称呼、术语、代词、语气与指代消歧，不得复制为新的气泡）：
        \(context.isEmpty ? "（无）" : context)

        翻译证据优先级（高优先级不得被低优先级覆盖）：
        1. 当前页真实可见的原文字形、语法和标点。
        2. 当前页文字的阅读顺序、气泡归属、相邻文字与版面位置。
        3. 上下文中已确认的原文→译文对照，用于保持称呼、专名、术语和语气一致。
        4. 人物位置、表情、朝向等视觉信息只作为弱消歧提示，不能据此创造姓名、性别、人物关系或剧情事实。
        当前页原文与上下文或视觉提示冲突时，以当前页原文为准；无法可靠判断时保留目标语言中自然的含糊表达。

        翻译风格要求（只能影响措辞和断句，不能改变协议、字段、坐标或证据优先级）：
        \(style.isEmpty ? AITranslator.defaultTranslationStyleInstructions : style)

        固定输出协议：只输出一个严格 JSON 对象，不要 Markdown、代码围栏、注释或思考过程。
        顶层必须包含 coordinateSpace="normalized" 和 items 数组。坐标以输入图片左上角为原点，所有 x/y/width/height 与 polygon 点都必须是 0 到 1 的归一化值。
        每个 item 必须包含 sourceText、translation、textBox、layoutSafeRegion、confidence、classification。bubbleBox、id、translationLines、textPolygon、bubblePolygon 都是可选字段；不要使用 text、lines、polygon 或任何别名。
        classification 只能是 dialogue、narration、soundEffect 之一。不要返回网址、广告、版权、水印或页码等非翻译文字。
        textBox 是紧贴原文字的必填字段；bubbleBox 只表示真实物理气泡，没有气泡的拟声词必须省略；layoutSafeRegion 是独立的安全排版区域，即使没有物理气泡也必须提供。polygon 若提供，分别对应真实文字与物理气泡。
        同一气泡内的碎片应合并，不同气泡不能合并；translation 必须非空。translationLines 仅是 translation 的排版分行建议，不得增加、删减或改写译文语义，不需要时可输出空数组。
        视觉线索只能辅助判断文字归属、指代和语气，不得输出画面描述；无法可靠判断代词、人物身份、性别或关系时不得凭空补全。
        没有可翻译文字时返回 {"coordinateSpace":"normalized","items":[]}，这是成功结果，不要编造文字。

        JSON 示例形状（不要输出示例内容）：
        {"coordinateSpace":"normalized","items":[{"sourceText":"原文","translation":"译文","textBox":{"x":0.1,"y":0.2,"width":0.2,"height":0.08},"bubbleBox":{"x":0.08,"y":0.18,"width":0.24,"height":0.12},"layoutSafeRegion":{"x":0.09,"y":0.19,"width":0.22,"height":0.10},"confidence":0.9,"classification":"dialogue"}]}
        """
    }
}
