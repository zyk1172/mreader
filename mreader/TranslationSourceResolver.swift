import Foundation
import NaturalLanguage

nonisolated struct TranslationSourceDecision: Sendable {
    let languageCode: String
    let confidence: Double
}

/// MReader 自己负责“原文语言”判断，而不是让 Apple TranslationSession 承担。
///
/// 策略（与审查报告一致）：
/// 1. 用户手动指定 → 永远最高优先级；
/// 2. `.automatic` → 把整页气泡文本聚合后交给 `NLLanguageRecognizer`，
///    并利用本地 OCR 的语言线索（如 `ocrSource` 含 `:en`）作为先验；
/// 3. 结果不确定时回退到这本漫画之前已稳定的语言；
/// 4. 仍然无法判断 → 返回 nil，调用方不要创建 `source = nil` 的 Apple 会话，
///    而是直接走云端文本模型兜底。
nonisolated enum TranslationSourceResolver {
    static func resolve(
        preference: TranslationSourceLanguage,
        blocks: [TextBlock],
        previousStableLanguage: String? = nil,
        ocrHint: String? = nil
    ) -> TranslationSourceDecision? {
        if preference != .automatic {
            return TranslationSourceDecision(languageCode: preference.rawValue, confidence: 1)
        }

        let pageText = blocks
            .map(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pageText.isEmpty else {
            return previousStableLanguage.map {
                TranslationSourceDecision(languageCode: $0, confidence: 0.5)
            }
        }

        let recognizer = NLLanguageRecognizer()

        // 本地 OCR 的语言线索（例如 script 分类得到 en/ja/ko）作为先验
        if let ocrHint, ocrHint != "auto" {
            // NLLanguage(rawValue:) 非可失败：任意语言代码都能构造，直接用即可
            recognizer.languageHints[NLLanguage(rawValue: ocrHint)] = 0.6
        }

        // OCR 主要走了 :en pass 时给英文一个先验，抵消拉丁字母短句的混淆
        let englishVotes = blocks.filter { $0.ocrSource.contains(":en") }.count
        if englishVotes * 2 >= blocks.count, !blocks.isEmpty {
            recognizer.languageHints[.english] = 0.75
        }

        recognizer.processString(pageText)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
            .sorted { $0.value > $1.value }
        guard let first = hypotheses.first else {
            return previousStableLanguage.map {
                TranslationSourceDecision(languageCode: $0, confidence: 0.5)
            }
        }

        let secondProbability = hypotheses.dropFirst().first?.value ?? 0
        guard first.value >= 0.60, first.value - secondProbability >= 0.12 else {
            return previousStableLanguage.map {
                TranslationSourceDecision(languageCode: $0, confidence: 0.5)
            }
        }

        return TranslationSourceDecision(languageCode: first.key.rawValue, confidence: first.value)
    }
}
