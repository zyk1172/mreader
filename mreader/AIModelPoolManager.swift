import Foundation

nonisolated struct AIModelPoolStatus: Identifiable, Codable, Hashable, Sendable {
    let modelName: String
    let isRateLimited: Bool
    let rateLimitedAt: Date?
    let cooldownUntil: Date?
    let lastErrorMessage: String?
    let isCurrent: Bool

    var id: String { modelName }
}

nonisolated private struct AIModelRateLimitRecord: Codable, Sendable {
    var rateLimitedAt: Date
    var cooldownUntil: Date
    var lastErrorMessage: String
}

actor AIModelPoolManager {
    static let shared = AIModelPoolManager()

    private enum Keys {
        static let currentIndex = "ai_model_pool_current_index"
        static let rateLimitRecords = "ai_model_pool_rate_limit_records"
        static let lastResetDate = "ai_model_pool_last_reset_date"
        static let currentModel = "ai_model_pool_current_model"
    }

    private let defaults: UserDefaults
    private var calendar: Calendar

    init(defaults: UserDefaults = .standard, calendar: Calendar = .current) {
        self.defaults = defaults
        self.calendar = calendar
    }

    nonisolated static func normalizedModels(from rawValue: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",\n")
        var seen = Set<String>()
        return rawValue
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }

    nonisolated static func isRateLimit(statusCode: Int?, message: String?) -> Bool {
        if statusCode == 429 {
            return true
        }
        let value = (message ?? "").lowercased()
        return [
            "rate_limit_exceeded",
            "quota_exceeded",
            "resource_exhausted",
            "too many requests",
            "insufficient_quota",
            "rate limit",
            "额度不足",
            "请求过多",
            "限流"
        ].contains { value.contains($0) }
    }

    func modelsForAttempt(
        defaultModel: String,
        poolText: String,
        isPoolEnabled: Bool = true,
        now: Date = Date()
    ) -> [String] {
        resetExpiredRateLimitsIfNeeded(now: now)
        let pool = Self.normalizedModels(from: poolText)
        let fallback = defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPoolEnabled, !pool.isEmpty else {
            if !fallback.isEmpty {
                defaults.set(fallback, forKey: Keys.currentModel)
                return [fallback]
            }
            return []
        }

        let startIndex = normalizedCurrentIndex(modelCount: pool.count)
        defaults.set((startIndex + 1) % pool.count, forKey: Keys.currentIndex)
        let records = loadRateLimitRecords()
        let rotated = Array(pool[startIndex...]) + Array(pool[..<startIndex])
        var candidates = rotated.filter { model in
            guard let record = records[model] else { return true }
            return record.cooldownUntil <= now
        }
        if !fallback.isEmpty && (!pool.contains(fallback) || candidates.isEmpty) {
            candidates.append(fallback)
        }
        if let first = candidates.first {
            defaults.set(first, forKey: Keys.currentModel)
        }
        return candidates
    }

    func selectModel(_ model: String, poolText: String) {
        let pool = Self.normalizedModels(from: poolText)
        guard let index = pool.firstIndex(of: model) else { return }
        defaults.set(calendar.startOfDay(for: Date()), forKey: Keys.lastResetDate)
        defaults.set(index, forKey: Keys.currentIndex)
        defaults.set(model, forKey: Keys.currentModel)
    }

    func markCurrentModel(_ model: String) {
        defaults.set(model, forKey: Keys.currentModel)
    }

    func markSucceeded(model: String) {
        defaults.set(model, forKey: Keys.currentModel)
    }

    func markFailed(model: String, message: String) {
        defaults.set(model, forKey: Keys.currentModel)
        var records = loadRateLimitRecords()
        if var record = records[model] {
            record.lastErrorMessage = message
            records[model] = record
            saveRateLimitRecords(records)
        }
    }

    func markRateLimited(model: String, message: String, now: Date = Date()) {
        let nextMidnight = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: now)
        ) ?? now.addingTimeInterval(86_400)
        var records = loadRateLimitRecords()
        records[model] = AIModelRateLimitRecord(
            rateLimitedAt: now,
            cooldownUntil: nextMidnight,
            lastErrorMessage: message
        )
        saveRateLimitRecords(records)
    }

    func statuses(poolText: String, now: Date = Date()) -> [AIModelPoolStatus] {
        resetExpiredRateLimitsIfNeeded(now: now)
        let records = loadRateLimitRecords()
        let currentModel = defaults.string(forKey: Keys.currentModel)
        return Self.normalizedModels(from: poolText).map { model in
            let record = records[model]
            return AIModelPoolStatus(
                modelName: model,
                isRateLimited: record.map { $0.cooldownUntil > now } ?? false,
                rateLimitedAt: record?.rateLimitedAt,
                cooldownUntil: record?.cooldownUntil,
                lastErrorMessage: record?.lastErrorMessage,
                isCurrent: currentModel == model
            )
        }
    }

    func clearRateLimits() {
        defaults.removeObject(forKey: Keys.rateLimitRecords)
        defaults.set(0, forKey: Keys.currentIndex)
        defaults.set(calendar.startOfDay(for: Date()), forKey: Keys.lastResetDate)
    }

    private func normalizedCurrentIndex(modelCount: Int) -> Int {
        guard modelCount > 0 else { return 0 }
        let stored = defaults.integer(forKey: Keys.currentIndex)
        return max(stored, 0) % modelCount
    }

    private func resetExpiredRateLimitsIfNeeded(now: Date) {
        let today = calendar.startOfDay(for: now)
        let lastReset = defaults.object(forKey: Keys.lastResetDate) as? Date
        if lastReset.map({ calendar.startOfDay(for: $0) < today }) ?? true {
            defaults.removeObject(forKey: Keys.rateLimitRecords)
            defaults.set(0, forKey: Keys.currentIndex)
            defaults.set(today, forKey: Keys.lastResetDate)
        }
    }

    private func loadRateLimitRecords() -> [String: AIModelRateLimitRecord] {
        guard let data = defaults.data(forKey: Keys.rateLimitRecords),
              let records = try? JSONDecoder().decode([String: AIModelRateLimitRecord].self, from: data) else {
            return [:]
        }
        return records
    }

    private func saveRateLimitRecords(_ records: [String: AIModelRateLimitRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: Keys.rateLimitRecords)
    }
}
