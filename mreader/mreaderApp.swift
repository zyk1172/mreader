//
//  mreaderApp.swift
//  mreader
//
//  Created by 郑云凯 on 2026/6/17.
//

import SwiftUI

@main
struct mreaderApp: App {
    init() {
        Task { @MainActor in
            OfflineDownloadManager.shared.reconcileStorage()
        }
        OfflineTranslationBackgroundScheduler.shared.register()
        Task { @MainActor in
            await OfflineTranslationBackgroundScheduler.shared.resumePendingJobIfNeeded()
        }
        RemoteImageLoader.migrateLegacyCoversIfNeeded()
        migrateLegacyTranslationPromptIfNeeded()
        let defaults = UserDefaults.standard
        let legacyAPIKey = defaults.string(forKey: "openai_api_key") ?? ""
        do {
            let migrated = try AIProviderStore.shared.migrateLegacyIfNeeded(
                apiKey: legacyAPIKey,
                baseURL: defaults.string(forKey: "openai_base_url") ?? "https://api.openai.com/v1",
                defaultModel: defaults.string(forKey: "openai_model") ?? "gpt-4o-mini",
                poolText: defaults.string(forKey: "ai_model_pool") ?? ""
            )
            if migrated != nil {
                defaults.removeObject(forKey: "openai_api_key")
                defaults.removeObject(forKey: "ai_model_pool_current_index")
                defaults.removeObject(forKey: "ai_model_pool_rate_limit_records")
                defaults.removeObject(forKey: "ai_model_pool_last_reset_date")
                defaults.removeObject(forKey: "ai_model_pool_current_model")
            }
        } catch {
            print("MReader AI legacy configuration migration failed: \(error.localizedDescription)")
        }
    }

    private static let translationPromptProtocolVersionKey = "translation_prompt_protocol_version"
    private static let legacyTranslationPromptKey = "translation_prompt_template"
    private static let styleTranslationPromptKey = "translation_style_instructions"

    /// V2 提示词迁移（项3）：换用新 key `translation_style_instructions`，旧 `translation_prompt_template`
    /// 只作为 legacy 数据读取一次，并用 `translation_prompt_protocol_version` 标记“已迁移”。
    /// 迁移完成后绝不再碰用户在新版里设置的 custom style。
    private func migrateLegacyTranslationPromptIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: Self.translationPromptProtocolVersionKey) < 2 else { return }

        if let legacy = defaults.string(forKey: Self.legacyTranslationPromptKey),
           !legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // 启发式：旧完整 Prompt 含 {ocrText}/{targetLanguage}/{pageContext} 占位符；
            // 不含占位符的值更可能是用户在上一版已填写的风格说明，直接迁移到新 key。
            let hasLegacyPlaceholders = legacy.contains("{ocrText}")
                || legacy.contains("{targetLanguage}")
                || legacy.contains("{pageContext}")
            if hasLegacyPlaceholders {
                defaults.set(legacy, forKey: "translation_prompt_legacy_backup")
            } else if defaults.string(forKey: Self.styleTranslationPromptKey) == nil {
                defaults.set(legacy, forKey: Self.styleTranslationPromptKey)
            }
        }
        defaults.removeObject(forKey: Self.legacyTranslationPromptKey)
        defaults.set(2, forKey: Self.translationPromptProtocolVersionKey)
        print("MReader migrated translation prompt protocol (legacy -> style instructions)")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
