import Foundation
import SwiftUI
import Translation
import UIKit

/// 单个漫画气泡的 Apple Translation 请求。
nonisolated struct AppleTranslationBlockRequest: Sendable, Identifiable, Equatable {
    let id: UUID
    let text: String
}

/// 驱动 Apple `TranslationSession` 的轻量桥接视图。
///
/// 它负责用 `.translationTask` 取得会话，然后以 `translate(batch:)` 一次性批量翻译
/// 一页里的所有气泡（通过 `clientIdentifier` 把异步返回的结果映射回原文气泡），
/// 替代“每个气泡一次云端 HTTP 请求”。翻译失败/缺失的气泡通过 `onMissing` 交回
/// 云端 AI 兜底。
struct AppleTranslationBridge: View {
    let sourceLanguage: Locale.Language?
    let targetLanguage: Locale.Language
    let requests: [AppleTranslationBlockRequest]
    let onResult: @MainActor ([UUID: String]) -> Void
    let onMissing: @MainActor ([UUID]) -> Void

    private var configuration: TranslationSession.Configuration {
        if #available(iOS 26.4, *) {
            // 低延迟策略（传统翻译模型，速度优先）；高保真/不可用时会回退
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
                var results: [UUID: String] = [:]
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
                        if !text.isEmpty {
                            results[id] = text
                        }
                    }
                } catch {
                    // Apple Translation 不可用（未安装语言包 / 不支持语言对 / 系统限制）：
                    // 交给 onMissing 全部走云端兜底。
                }
                let missing = requests.filter { results[$0.id] == nil }.map(\.id)
                await MainActor.run {
                    onResult(results)
                    onMissing(missing)
                }
            }
    }
}
