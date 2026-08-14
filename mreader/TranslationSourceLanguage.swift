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

    /// 该语言对应的 Vision OCR 识别语言标识（用于 Apple Vision 语言校正）。
    var recognitionLanguageIdentifiers: [String] {
        switch self {
        case .automatic: return ["zh-Hans", "zh-Hant", "ja-JP", "ko-KR", "en-US"]
        case .simplifiedChinese: return ["zh-Hans"]
        case .traditionalChinese: return ["zh-Hant"]
        case .english: return ["en-US"]
        case .japanese: return ["ja-JP"]
        case .korean: return ["ko-KR"]
        case .french: return ["fr-FR"]
        case .german: return ["de-DE"]
        case .spanish: return ["es-ES"]
        case .italian: return ["it-IT"]
        case .portuguese: return ["pt-BR"]
        case .russian: return ["ru-RU"]
        case .thai: return ["th-TH"]
        case .vietnamese: return ["vi-VN"]
        case .indonesian: return ["id-ID"]
        case .arabic: return ["ar-SA"]
        }
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
