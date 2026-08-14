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

    /// V2 提示词迁移（审查 #4）：旧 `translation_prompt_template` 是“整页/逐气泡完整提示词”，
    /// 与新固定 JSON 协议冲突。一次性备份到 `translation_prompt_legacy_backup` 并移除旧键，
    /// 让 AppStorage 回落为默认“翻译风格要求”，不再把旧提示词注入新协议。
    private func migrateLegacyTranslationPromptIfNeeded() {
        let defaults = UserDefaults.standard
        let key = "translation_prompt_template"
        guard let legacy = defaults.string(forKey: key),
              !legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              legacy != AITranslator.defaultTranslationStyleInstructions else {
            return
        }
        defaults.set(legacy, forKey: "translation_prompt_legacy_backup")
        defaults.removeObject(forKey: key)
        print("MReader migrated legacy translation prompt to translation_prompt_legacy_backup")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
