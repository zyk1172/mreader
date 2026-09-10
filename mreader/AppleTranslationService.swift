import CryptoKit
import Foundation
import SwiftUI
import Translation
import UIKit

/// 单个漫画气泡的 Apple Translation 请求。
nonisolated struct AppleTranslationBlockRequest: Sendable, Identifiable, Equatable {
    let id: UUID
    let text: String
}

/// Apple 本地翻译的会话内页缓存。
///
/// 让“翻回旧页”时能直接命中上次 Apple 翻译结果，而不必重新 OCR + 重新翻译。
/// 按页面、语言和 OCR 分组输入分键，只做内存缓存（会话内有效）。
/// OCR/分组几何变化时必须换 key，不能把旧的 translation unit 数量带回当前页面。
actor AppleTranslationPageCache {
    static let shared = AppleTranslationPageCache()

    private var memoryCache: [String: [TextBlock]] = [:]
    private var memoryOrder: [String] = []
    private let memoryPageLimit = 40

    func cachedBlocks(key: String) -> [TextBlock]? {
        if let blocks = memoryCache[key] {
            touch(key)
            return blocks
        }
        return nil
    }

    func store(_ blocks: [TextBlock], key: String) {
        if memoryCache[key] == nil {
            memoryOrder.append(key)
        }
        memoryCache[key] = blocks
        if memoryOrder.count > memoryPageLimit {
            let oldest = memoryOrder.removeFirst()
            memoryCache.removeValue(forKey: oldest)
        }
    }

    private func touch(_ key: String) {
        if let index = memoryOrder.firstIndex(of: key) {
            memoryOrder.remove(at: index)
            memoryOrder.append(key)
        }
    }

    nonisolated static func key(
        pageURL: URL,
        sourceLanguage: String,
        targetLanguage: String,
        segmentationRevision: String,
        ocrRecognitionMode: OCRRecognitionMode,
        usesVisualOCRVerification: Bool,
        isRightToLeft: Bool,
        minimumTextHeight: Double,
        safeAreaInset: Double
    ) -> String {
        let raw = [
            pageURL.absoluteString,
            sourceLanguage,
            targetLanguage,
            "segmentation=\(segmentationRevision)",
            "ocr-mode=\(ocrRecognitionMode.rawValue)",
            usesVisualOCRVerification ? "visual-review" : "local-only",
            isRightToLeft ? "rtl" : "ltr",
            String(format: "min=%.6f", minimumTextHeight),
            String(format: "safe-area=%.6f", safeAreaInset)
        ].joined(separator: "#")
        return SHA256.hash(data: Data(raw.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// 驱动 Apple `TranslationSession` 的轻量桥接视图。
///
/// 负责用 `.translationTask` 取得会话，以 `translate(batch:)` 批量翻译一页气泡，
/// 并通过 `clientIdentifier` 把异步返回的结果映射回原文气泡：
/// - `onResult` 在每条结果完成时立即回调（增量显示，而不是全部结束才一次性给）；
/// - `onFinished` 在整批结束后回调（用于缓存与缺失项兜底）。
struct AppleTranslationBridge: View {
    let sourceLanguage: Locale.Language
    let targetLanguage: Locale.Language
    let requests: [AppleTranslationBlockRequest]
    let onResult: @MainActor (UUID, String) -> Void
    let onFinished: @MainActor (Set<UUID>) -> Void

    private var configuration: TranslationSession.Configuration {
        if #available(iOS 26.4, *) {
            // 低延迟策略（传统翻译模型，速度优先）
            return TranslationSession.Configuration(
                source: sourceLanguage,
                target: targetLanguage,
                preferredStrategy: .lowLatency
            )
        } else {
            return TranslationSession.Configuration(source: sourceLanguage, target: targetLanguage)
        }
    }

    var body: some View {
        Color.clear
            .translationTask(configuration) { session in
                let translationRequests = requests.map {
                    TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id.uuidString)
                }
                var seen = Set<UUID>()
                do {
                    for try await response in session.translate(batch: translationRequests) {
                        guard let identifier = response.clientIdentifier,
                              let id = UUID(uuidString: identifier),
                              seen.insert(id).inserted else {
                            continue
                        }
                        let text = response.targetText
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { continue }
                        // 增量：这一条先完成就先显示
                        await MainActor.run { onResult(id, text) }
                    }
                } catch {
                    // Apple Translation 不可用（未安装语言包 / 不支持语言对 / 系统限制）：
                    // 由 onFinished 把缺失项交给云端兜底。
                }
                await MainActor.run { onFinished(seen) }
            }
    }
}
