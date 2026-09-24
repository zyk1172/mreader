import Darwin
import Foundation

/// Reader image/data budgets. Physical RAM chooses the baseline tier; the runtime
/// budget is then clamped against the process headroom reported by
/// `os_proc_available_memory()`. The latter is advisory and must not be cached.
nonisolated struct ReaderMemoryBudget: Equatable {
    let decodedImageCacheMB: Int
    let decodedImagePreloadMB: Int
    let remotePageDataCacheMB: Int
    let remotePageDataDiskMB: Int
    let remotePrefetchMB: Int
}

nonisolated enum ReaderMemoryBudgetPlanner {
    static func budget(
        forPhysicalMemoryBytes bytes: UInt64,
        availableMemoryBytes: UInt64? = nil
    ) -> ReaderMemoryBudget {
        let ramGB = Double(bytes) / (1024 * 1024 * 1024)
        let baseline: ReaderMemoryBudget
        switch ramGB {
        case 8...:
            baseline = ReaderMemoryBudget(
                decodedImageCacheMB: 896,
                decodedImagePreloadMB: 512,
                remotePageDataCacheMB: 384,
                remotePageDataDiskMB: 3_072,
                remotePrefetchMB: 640
            )
        case 6..<8:
            baseline = ReaderMemoryBudget(
                decodedImageCacheMB: 768,
                decodedImagePreloadMB: 448,
                remotePageDataCacheMB: 320,
                remotePageDataDiskMB: 2_048,
                remotePrefetchMB: 512
            )
        case 4..<6:
            baseline = ReaderMemoryBudget(
                decodedImageCacheMB: 512,
                decodedImagePreloadMB: 288,
                remotePageDataCacheMB: 192,
                remotePageDataDiskMB: 1_536,
                remotePrefetchMB: 320
            )
        case 3..<4:
            baseline = ReaderMemoryBudget(
                decodedImageCacheMB: 384,
                decodedImagePreloadMB: 224,
                remotePageDataCacheMB: 128,
                remotePageDataDiskMB: 1_024,
                remotePrefetchMB: 224
            )
        default:
            baseline = ReaderMemoryBudget(
                decodedImageCacheMB: 288,
                decodedImagePreloadMB: 160,
                remotePageDataCacheMB: 96,
                remotePageDataDiskMB: 512,
                remotePrefetchMB: 160
            )
        }

        guard let availableMemoryBytes, availableMemoryBytes > 0 else {
            return baseline
        }

        // Headroom is dynamic and already excludes the process' current footprint.
        // Keep each reader subsystem to a conservative share instead of pretending
        // the physical-RAM tier is a process-wide hard allocation budget.
        let availableMB = max(1, Int(availableMemoryBytes / (1024 * 1024)))
        func clamped(_ value: Int, fraction: Double, floor: Int) -> Int {
            min(value, max(floor, Int(Double(availableMB) * fraction)))
        }

        let decoded = clamped(baseline.decodedImageCacheMB, fraction: 0.32, floor: 96)
        let preload = min(
            clamped(baseline.decodedImagePreloadMB, fraction: 0.18, floor: 64),
            max(64, decoded * 2 / 3)
        )
        return ReaderMemoryBudget(
            decodedImageCacheMB: decoded,
            decodedImagePreloadMB: preload,
            remotePageDataCacheMB: clamped(baseline.remotePageDataCacheMB, fraction: 0.10, floor: 48),
            remotePageDataDiskMB: baseline.remotePageDataDiskMB,
            remotePrefetchMB: clamped(baseline.remotePrefetchMB, fraction: 0.18, floor: 64)
        )
    }

    /// Static baseline for the lowest-memory supported tier before runtime headroom clamping.
    static let minimumDecodedImageCacheMB = 384

    static func currentAvailableMemoryBytes() -> UInt64 {
        os_proc_available_memory()
    }

    static func budget() -> ReaderMemoryBudget {
        budget(
            forPhysicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            availableMemoryBytes: currentAvailableMemoryBytes()
        )
    }
}


/// Main-actor ownership marker used to reject late setup work from a Reader that
/// has already disappeared. Per-service session IDs still guard teardown; this
/// registry prevents a cancelled old setup task from claiming a service after a
/// newer Reader has become active.
@MainActor
final class ReaderSessionRegistry {
    static let shared = ReaderSessionRegistry()

    private(set) var activeSessionID: UUID?

    private init() {}

    func activate(_ sessionID: UUID) {
        activeSessionID = sessionID
    }

    func deactivate(_ sessionID: UUID) {
        guard activeSessionID == sessionID else { return }
        activeSessionID = nil
    }

    func isActive(_ sessionID: UUID) -> Bool {
        activeSessionID == sessionID
    }
}
