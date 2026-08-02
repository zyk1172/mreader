import Foundation
import Security

nonisolated struct AIProviderProfile: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var baseURL: String
    var models: [String]
    var selectedModel: String
    var createdAt: Date
    var updatedAt: Date

    static func normalized(
        id: UUID = UUID(),
        name: String,
        baseURL: String,
        modelsText: String,
        selectedModel: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) -> AIProviderProfile {
        let models = normalizedModels(from: modelsText)
        let requestedSelection = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let selection = models.contains(requestedSelection)
            ? requestedSelection
            : (models.first ?? requestedSelection)
        return AIProviderProfile(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "默认接口"
                : name.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: normalizedBaseURL(baseURL),
            models: models,
            selectedModel: selection,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    static func fromLegacySettings(
        apiDisplayName: String,
        baseURL: String,
        defaultModel: String,
        poolText: String
    ) -> AIProviderProfile {
        let primary = defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = ([primary] + normalizedModels(from: poolText))
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return normalized(
            name: apiDisplayName,
            baseURL: baseURL,
            modelsText: combined,
            selectedModel: primary
        )
    }

    static func normalizedModels(from rawValue: String) -> [String] {
        var seen = Set<String>()
        return rawValue
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func normalizedBaseURL(_ rawValue: String) -> String {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }
}

nonisolated struct AIActiveConfiguration: Sendable, Equatable {
    let profileID: UUID
    let profileName: String
    let baseURL: String
    let apiKey: String
    let model: String
}

nonisolated enum AIProviderStoreError: LocalizedError, Sendable {
    case missingProfile
    case missingAPIKey
    case missingModel
    case credentialFailure(OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingProfile: return "尚未选择 AI 接口配置"
        case .missingAPIKey: return "当前 AI 接口没有 API Key"
        case .missingModel: return "当前 AI 接口没有选择子模型"
        case .credentialFailure(let status): return "AI 凭据保存失败（\(status)）"
        }
    }
}

@MainActor
protocol AICredentialStoring: AnyObject {
    func apiKey(for profileID: UUID) -> String?
    func saveAPIKey(_ apiKey: String, for profileID: UUID) throws
    func removeAPIKey(for profileID: UUID)
}

@MainActor
final class AIProviderKeychainStore: AICredentialStoring {
    private let service = "zhengyk.mreader.ai-provider"

    func apiKey(for profileID: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func saveAPIKey(_ apiKey: String, for profileID: UUID) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString
        ]
        let value = Data(apiKey.utf8)
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: value] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw AIProviderStoreError.credentialFailure(updateStatus)
        }
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = value
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AIProviderStoreError.credentialFailure(addStatus)
        }
    }

    func removeAPIKey(for profileID: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString
        ]
        SecItemDelete(query as CFDictionary)
    }
}

@MainActor
final class AIProviderStore {
    static let shared = AIProviderStore()

    private enum Keys {
        static let profiles = "ai_provider_profiles_v1"
        static let activeProfileID = "ai_provider_active_profile_id"
        static let didMigrateLegacy = "ai_provider_did_migrate_legacy"
    }

    private let defaults: UserDefaults
    private let credentials: AICredentialStoring

    init(
        defaults: UserDefaults = .standard,
        credentials: AICredentialStoring? = nil
    ) {
        self.defaults = defaults
        self.credentials = credentials ?? AIProviderKeychainStore()
    }

    func profiles() -> [AIProviderProfile] {
        guard let data = defaults.data(forKey: Keys.profiles),
              let value = try? JSONDecoder().decode([AIProviderProfile].self, from: data) else {
            return []
        }
        return value.sorted { $0.createdAt < $1.createdAt }
    }

    func activeProfileID() -> UUID? {
        defaults.string(forKey: Keys.activeProfileID).flatMap(UUID.init(uuidString:))
    }

    func activeConfiguration() -> AIActiveConfiguration? {
        let allProfiles = profiles()
        guard let profile = allProfiles.first(where: { $0.id == activeProfileID() })
                ?? allProfiles.first,
              !profile.selectedModel.isEmpty,
              let apiKey = credentials.apiKey(for: profile.id),
              !apiKey.isEmpty else {
            return nil
        }
        return AIActiveConfiguration(
            profileID: profile.id,
            profileName: profile.name,
            baseURL: profile.baseURL,
            apiKey: apiKey,
            model: profile.selectedModel
        )
    }

    func apiKey(for profileID: UUID) -> String {
        credentials.apiKey(for: profileID) ?? ""
    }

    func save(profile: AIProviderProfile, apiKey: String, activate: Bool = false) throws {
        var allProfiles = profiles()
        if let index = allProfiles.firstIndex(where: { $0.id == profile.id }) {
            allProfiles[index] = profile
        } else {
            allProfiles.append(profile)
        }
        try persist(allProfiles)
        if !apiKey.isEmpty {
            try credentials.saveAPIKey(apiKey, for: profile.id)
        }
        if activate || activeProfileID() == nil {
            setActiveProfile(id: profile.id)
        }
    }

    func setActiveProfile(id: UUID) {
        guard profiles().contains(where: { $0.id == id }) else { return }
        defaults.set(id.uuidString, forKey: Keys.activeProfileID)
    }

    func setSelectedModel(_ model: String, for profileID: UUID, activate: Bool = true) throws {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        var allProfiles = profiles()
        guard let index = allProfiles.firstIndex(where: { $0.id == profileID }) else {
            throw AIProviderStoreError.missingProfile
        }
        guard allProfiles[index].models.contains(trimmedModel) else {
            throw AIProviderStoreError.missingModel
        }
        allProfiles[index].selectedModel = trimmedModel
        allProfiles[index].updatedAt = Date()
        try persist(allProfiles)
        if activate {
            setActiveProfile(id: profileID)
        }
    }

    func deleteProfile(id: UUID) throws {
        var allProfiles = profiles()
        allProfiles.removeAll { $0.id == id }
        try persist(allProfiles)
        credentials.removeAPIKey(for: id)
        if activeProfileID() == id {
            if let next = allProfiles.first {
                defaults.set(next.id.uuidString, forKey: Keys.activeProfileID)
            } else {
                defaults.removeObject(forKey: Keys.activeProfileID)
            }
        }
    }

    @discardableResult
    func migrateLegacyIfNeeded(
        apiKey: String,
        baseURL: String,
        defaultModel: String,
        poolText: String
    ) throws -> AIProviderProfile? {
        guard profiles().isEmpty else {
            defaults.set(true, forKey: Keys.didMigrateLegacy)
            return nil
        }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !defaultModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let profile = AIProviderProfile.fromLegacySettings(
            apiDisplayName: "默认接口",
            baseURL: baseURL,
            defaultModel: defaultModel,
            poolText: poolText
        )
        try save(profile: profile, apiKey: apiKey)
        setActiveProfile(id: profile.id)
        defaults.set(true, forKey: Keys.didMigrateLegacy)
        return profile
    }

    func replaceProfiles(
        _ profiles: [(profile: AIProviderProfile, apiKey: String)],
        activeProfileID: UUID?
    ) throws {
        let existingIDs = Set(self.profiles().map(\.id))
        let newIDs = Set(profiles.map(\.profile.id))
        for removedID in existingIDs.subtracting(newIDs) {
            credentials.removeAPIKey(for: removedID)
        }
        try persist(profiles.map(\.profile))
        for value in profiles where !value.apiKey.isEmpty {
            try credentials.saveAPIKey(value.apiKey, for: value.profile.id)
        }
        if let activeProfileID, newIDs.contains(activeProfileID) {
            setActiveProfile(id: activeProfileID)
        } else if let first = profiles.first?.profile {
            setActiveProfile(id: first.id)
        }
    }

    private func persist(_ profiles: [AIProviderProfile]) throws {
        let data = try JSONEncoder().encode(profiles)
        defaults.set(data, forKey: Keys.profiles)
    }
}
