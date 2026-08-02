import Foundation

extension String {
    nonisolated var localized: String {
        NSLocalizedString(self, comment: "")
    }

    nonisolated func localizedFormat(_ arg: CVarArg) -> String {
        String(format: NSLocalizedString(self, comment: ""), locale: .current, arg)
    }

    nonisolated func localizedFormat(_ arg1: CVarArg, _ arg2: CVarArg) -> String {
        String(format: NSLocalizedString(self, comment: ""), locale: .current, arg1, arg2)
    }
}
