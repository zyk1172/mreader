import Foundation

nonisolated private func mreaderLocalizedString(_ key: String) -> String {
    // Only the handful of reviewed copy keys pay the override-table lookup cost.
    // Everything else stays on the original one-lookup Localizable.strings path.
    switch key {
    case "tab.continueReading",
         "shelf.filterCategory",
         "series.addChapters",
         "settings.selectLibraryDescription",
         "mediaSources.title",
         "mediaSources.noServers",
         "mediaSources.add",
         "import.webServer",
         "import.webServerDescription",
         "ocr.appleTranslation",
         "ocr.colorStyle.jewel":
        let polished = NSLocalizedString(
            key,
            tableName: "CopyPolish",
            bundle: .main,
            value: key,
            comment: ""
        )
        if polished != key {
            return polished
        }
    default:
        break
    }

    return NSLocalizedString(key, comment: "")
}

extension String {
    nonisolated var localized: String {
        mreaderLocalizedString(self)
    }

    nonisolated func localizedFormat(_ arg: CVarArg) -> String {
        String(format: localized, locale: .current, arg)
    }

    nonisolated func localizedFormat(_ arg1: CVarArg, _ arg2: CVarArg) -> String {
        String(format: localized, locale: .current, arg1, arg2)
    }

    nonisolated func localizedFormat(_ arg1: CVarArg, _ arg2: CVarArg, _ arg3: CVarArg) -> String {
        String(format: localized, locale: .current, arg1, arg2, arg3)
    }
}
