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

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
