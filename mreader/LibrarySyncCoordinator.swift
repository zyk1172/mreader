import Foundation

nonisolated struct LibrarySyncScope: OptionSet, Sendable {
    let rawValue: Int

    static let local = LibrarySyncScope(rawValue: 1 << 0)
    static let komga = LibrarySyncScope(rawValue: 1 << 1)
    static let opds = LibrarySyncScope(rawValue: 1 << 2)
    static let prewarmKomga = LibrarySyncScope(rawValue: 1 << 3)

    static let all: LibrarySyncScope = [.local, .komga, .opds]
    static let startupRemote: LibrarySyncScope = [.komga, .opds, .prewarmKomga]
}

/// Serializes library refreshes and folds overlapping requests into one trailing pass.
actor LibrarySyncCoordinator {
    private var pendingScope: LibrarySyncScope = []
    private var runner: Task<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func perform(
        scope: LibrarySyncScope,
        operation: @escaping @Sendable (LibrarySyncScope) async -> Void
    ) async {
        await withCheckedContinuation { continuation in
            pendingScope.formUnion(scope)
            waiters.append(continuation)

            guard runner == nil else { return }
            runner = Task {
                await drain(operation: operation)
            }
        }
    }

    func isRefreshingForDiagnostics() -> Bool {
        runner != nil
    }

    func pendingScopeForDiagnostics() -> LibrarySyncScope {
        pendingScope
    }

    private func drain(operation: @escaping @Sendable (LibrarySyncScope) async -> Void) async {
        while !pendingScope.isEmpty {
            let scope = pendingScope
            pendingScope = []
            await operation(scope)
        }

        runner = nil
        let completedWaiters = waiters
        waiters.removeAll()
        for waiter in completedWaiters {
            waiter.resume()
        }
    }
}
