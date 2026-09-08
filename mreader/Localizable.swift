import Foundation

private func mreaderLocalizedString(_ key: String) -> String {
    // Keep small wording corrections in a separate table so copy can be polished
    // without rewriting the much larger legacy localization files. Missing keys
    // fall through to the existing Localizable.strings table.
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
