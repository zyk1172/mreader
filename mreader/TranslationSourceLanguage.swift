import Foundation

/// 漫画原文语言。`automatic` 表示由 MReader 在整页 OCR 后自行判断，
/// 不再把 `source = nil` 交给 Apple TranslationSession 去猜。
nonisolated enum TranslationSourceLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic = "auto"

    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case german = "de"
    case spanish = "es"
    case italian = "it"
    case portuguese = "pt"
    case russian = "ru"
    case thai = "th"
    case vietnamese = "vi"
    case indonesian = "id"
    case arabic = "ar"

    var id: String { rawValue }

    /// 只有明确选择的语言才返回 Locale.Language；`.automatic` 返回 nil，
    /// 但调用方必须在解析出结果后再传给 Apple Translation，绝不能把 nil 直接传下去。
    var localeLanguage: Locale.Language? {
        guard self != .automatic else { return nil }
        return Locale.Language(identifier: rawValue)
    }

    var localizedTitle: String {
        switch self {
        case .automatic:
            return "translation.source.auto".localized
        default:
            let displayName = Locale.current.localizedString(forLanguageCode: rawValue) ?? rawValue
            return "\(displayName) (\(rawValue))"
        }
    }
}
