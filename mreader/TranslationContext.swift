import CoreGraphics
import CryptoKit
import Foundation

/// Immutable, deterministic context formatting shared by realtime, prefetch,
/// offline, supplement, text-model and vision-model translation paths.
nonisolated enum TranslationContextBuilder {
    static let revision = "translation-context-v1"
    static let maximumContextCharacters = 5_000

    static func scopeID(
        comicID: UUID?,
        target: TranslationTargetLanguage
    ) -> String? {
        guard let comicID else { return nil }
        return "comic=\(comicID.uuidString)|target=\(target.rawValue)"
    }

    static func mergeContexts(_ values: [String]) -> String {
        let merged = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return bounded(merged)
    }

    static func versionedContext(_ values: [String]) -> String {
        let merged = mergeContexts(values)
        guard !merged.isEmpty else { return "" }
        let digest = SHA256.hash(data: Data(merged.utf8))
            .prefix(6)
            .map { String(format: "%02x", $0) }
            .joined()
        return "contextVersion=\(revision)-\(digest)\n\(merged)"
    }

    /// Adds the full current-page semantic picture even when only a subset of
    /// IDs is being retried. Already translated neighbours remain evidence,
    /// while requested IDs are clearly marked as pending.
    static func promptContext(
        previousContext: String,
        pageBlocks: [TextBlock],
        requestedIndexes: [Int]? = nil
    ) -> String {
        let requested = requestedIndexes.map(Set.init)
        let pageLines = pageBlocks.enumerated().compactMap { index, block -> String? in
            let source = compact(block.text)
            guard !source.isEmpty else { return nil }
            let translation = compact(block.translation ?? "")
            let state: String
            if let requested {
                state = requested.contains(index) ? "待翻译" : (translation.isEmpty ? "同页参考" : "已译")
            } else {
                state = translation.isEmpty ? "待翻译" : "已译"
            }
            let rect = block.boundingBox
            let geometry = String(
                format: "x=%.3f,y=%.3f,w=%.3f,h=%.3f",
                Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)
            )
            let translatedPart = translation.isEmpty ? "" : " | 译文=\(translation)"
            return "#\(index + 1) [\(state)] 原文=\(source)\(translatedPart) | \(geometry) | \(block.textOrientation.rawValue)"
        }
        let pageSection = pageLines.isEmpty
            ? ""
            : "本页完整语义与阅读顺序（只作翻译依据，不得复述）：\n" + pageLines.joined(separator: "\n")
        return mergeContexts([previousContext, pageSection])
    }

    static func visionPrompt(basePrompt: String, previousContext: String) -> String {
        let context = previousContext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !context.isEmpty else { return basePrompt }
        return """
        \(basePrompt)

        上下文快照（仅用于称呼、术语、代词、语气和指代消歧；不得把上下文文字复制成当前页 item，也不得新增剧情事实）：
        \(bounded(context))
        无法从当前页文字、画面线索或上下文可靠判断代词指向时，不得凭空补人名。
        """
    }

    static func sourceTranslationSummary(pageIndex: Int, blocks: [TextBlock]) -> String {
        let pairs = blocks.compactMap { block -> String? in
            let source = compact(block.text)
            let translation = compact(block.translation ?? "")
            guard !source.isEmpty, !translation.isEmpty else { return nil }
            return "原文=\(source) → 译文=\(translation)"
        }
        guard !pairs.isEmpty else { return "" }
        return "第\(pageIndex + 1)页已确认对照：\n" + pairs.joined(separator: "\n")
    }

    static func sourceOnlySummary(pageIndex: Int, blocks: [TextBlock]) -> String {
        let sources = blocks
            .map { compact($0.text) }
            .filter { !$0.isEmpty }
        guard !sources.isEmpty else { return "" }
        return "第\(pageIndex + 1)页原文预识别（尚未依赖该页译文）：\n" + sources.joined(separator: "\n")
    }

    private static func compact(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func bounded(_ value: String) -> String {
        guard value.count > maximumContextCharacters else { return value }
        return String(value.suffix(maximumContextCharacters))
    }
}

/// Recent translated-page memory for live Reader and prefetch. Pages are keyed
/// by page index, never by completion order, so the same available page set
/// produces the same snapshot and version.
actor TranslationContextRegistry {
    static let shared = TranslationContextRegistry()

    private var pagesByScope: [String: [Int: String]] = [:]
    private let lookBackPageCount = 2

    func context(
        scopeID: String?,
        pageIndex: Int?,
        seed: String = ""
    ) -> String {
        guard let scopeID, let pageIndex, pageIndex > 0 else {
            return TranslationContextBuilder.versionedContext([seed])
        }
        let pages = pagesByScope[scopeID] ?? [:]
        let start = max(0, pageIndex - lookBackPageCount)
        let ordered = (start..<pageIndex).compactMap { pages[$0] }
        return TranslationContextBuilder.versionedContext([seed] + ordered)
    }

    func record(
        scopeID: String?,
        pageIndex: Int?,
        blocks: [TextBlock]
    ) {
        guard let scopeID, let pageIndex else { return }
        let summary = TranslationContextBuilder.sourceTranslationSummary(
            pageIndex: pageIndex,
            blocks: blocks
        )
        guard !summary.isEmpty else { return }
        var pages = pagesByScope[scopeID] ?? [:]
        pages[pageIndex] = summary
        // Keep a small bounded chapter-local working set without coupling the
        // context version to task completion order.
        if pages.count > 12 {
            let keep = Set(pages.keys.sorted().suffix(12))
            pages = pages.filter { keep.contains($0.key) }
        }
        pagesByScope[scopeID] = pages
    }

    func resetForDiagnostics() {
        pagesByScope.removeAll()
    }
}
