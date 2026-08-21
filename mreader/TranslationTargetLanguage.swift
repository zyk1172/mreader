import Foundation

nonisolated enum TranslationTargetLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
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

    var localizedTitle: String {
        "translation.language.\(rawValue)".localized
    }

    var modelInstruction: String {
        let name: String
        switch self {
        case .simplifiedChinese: name = "简体中文"
        case .traditionalChinese: name = "繁体中文"
        case .english: name = "English"
        case .japanese: name = "日本語"
        case .korean: name = "한국어"
        case .french: name = "français"
        case .german: name = "Deutsch"
        case .spanish: name = "español"
        case .italian: name = "italiano"
        case .portuguese: name = "português"
        case .russian: name = "русский"
        case .thai: name = "ไทย"
        case .vietnamese: name = "Tiếng Việt"
        case .indonesian: name = "Bahasa Indonesia"
        case .arabic: name = "العربية"
        }
        return "\(name)（语言代码：\(rawValue)）"
    }

    static func migrateLegacyValue(_ value: String) -> TranslationTargetLanguage {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let current = TranslationTargetLanguage(rawValue: trimmed) {
            return current
        }
        switch trimmed.lowercased() {
        case "中文", "简体中文", "简体", "chinese", "simplified chinese":
            return .simplifiedChinese
        case "繁体中文", "繁体", "traditional chinese":
            return .traditionalChinese
        case "英文", "英语", "english":
            return .english
        case "日文", "日语", "japanese":
            return .japanese
        case "韩文", "韩语", "korean":
            return .korean
        case "法文", "法语", "french":
            return .french
        case "德文", "德语", "german":
            return .german
        case "西班牙语", "spanish":
            return .spanish
        case "意大利语", "italian":
            return .italian
        case "葡萄牙语", "portuguese":
            return .portuguese
        case "俄语", "russian":
            return .russian
        case "泰语", "thai":
            return .thai
        case "越南语", "vietnamese":
            return .vietnamese
        case "印尼语", "印度尼西亚语", "indonesian":
            return .indonesian
        case "阿拉伯语", "arabic":
            return .arabic
        default:
            return .simplifiedChinese
        }
    }
}
