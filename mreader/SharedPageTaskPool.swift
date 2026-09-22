import Foundation

/// Coalesces page work while keeping cancellation scoped to each consumer.
/// Clearing the pool advances a generation; an old completion cannot remove or
/// commit a replacement request for the same key.
actor SharedPageTaskPool<Value: Sendable> {
    private struct Entry {
        let id: UUID
        let task: Task<Value, Error>
        var consumers: Set<UUID>
    }
    private var entries: [String: Entry] = [:]
    private var generation = UUID()

    func value(
        forKey key: String,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let consumer = UUID()
        let epoch = generation
        let entry: Entry
        if var existing = entries[key] {
            existing.consumers.insert(consumer)
            entries[key] = existing
            entry = existing
        } else {
            entry = Entry(id: UUID(), task: Task { try await operation() }, consumers: [consumer])
            entries[key] = entry
        }
        return try await withTaskCancellationHandler {
            do {
                let value = try await entry.task.value
                release(key: key, requestID: entry.id, consumer: consumer)
                try Task.checkCancellation()
                guard generation == epoch else { throw CancellationError() }
                return value
            } catch {
                release(key: key, requestID: entry.id, consumer: consumer)
                throw error
            }
        } onCancel: {
            Task { await self.release(key: key, requestID: entry.id, consumer: consumer) }
        }
    }

    func cancelAll() {
        generation = UUID()
        for entry in entries.values { entry.task.cancel() }
        entries.removeAll()
    }

    private func release(key: String, requestID: UUID, consumer: UUID) {
        guard var entry = entries[key], entry.id == requestID else { return }
        entry.consumers.remove(consumer)
        if entry.consumers.isEmpty {
            entry.task.cancel()
            entries[key] = nil
        } else {
            entries[key] = entry
        }
    }
}
