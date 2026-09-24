import Foundation

/// 阅读器各类图片/数据缓存的预算。集中在一处，避免解码位图与远程页数据各自维护一份
/// 分档表后再次出现「同机型两条缓存差一个数量级」的问题。
nonisolated struct ReaderMemoryBudget: Equatable {
    /// 解码后位图常驻内存上限（`ReaderImageCache` 的 `totalCostLimit`）。
    let decodedImageCacheMB: Int
    /// 解码位图预取队列的内存预算，控制在途预取量。
    let decodedImagePreloadMB: Int
    /// 远程页压缩数据（`Data`）的内存上限。
    let remotePageDataCacheMB: Int
    /// 远程页压缩数据的磁盘上限。
    let remotePageDataDiskMB: Int
    /// 远程页预取的并发内存预算。
    let remotePrefetchMB: Int
}

/// 按设备物理内存分档。
///
/// 基线机型是 **iPad mini 5（A12 / 3GB RAM）**：它是本工程支持的最低内存设备
/// （`IPHONEOS_DEPLOYMENT_TARGET = 26.0`，iPadOS 26 仍支持 iPad mini 5）。3GB 机型的
/// 单进程 jetsam 上限约 1.3GB，所以最保守的一档必须按「设备能承受多少」来给，而不是按
/// 「比它更弱的设备」留余量：旧的 180MB 只放得下 4 页 4096px 位图，往回翻一页就要重新解码。
///
/// 6GB 以上设备把远程压缩页缓存提高到至少 800MB。超大 Komga 条漫（数 GB / 数千页）
/// 连续翻页时，384MB 会过早逐出刚预取的压缩页，导致下一页重新走磁盘甚至网络。
/// 该缓存使用 NSCache，收到 memory warning 时会主动整体清空，因此 800MB 是上限而非强制常驻。
nonisolated enum ReaderMemoryBudgetPlanner {
    static func budget(forPhysicalMemoryBytes bytes: UInt64) -> ReaderMemoryBudget {
        let ramGB = Double(bytes) / (1024 * 1024 * 1024)
        switch ramGB {
        case 8...:
            return ReaderMemoryBudget(
                decodedImageCacheMB: 1_024,
                decodedImagePreloadMB: 768,
                remotePageDataCacheMB: 1_024,
                remotePageDataDiskMB: 3_072,
                remotePrefetchMB: 1_024
            )
        case 6..<8:
            return ReaderMemoryBudget(
                decodedImageCacheMB: 896,
                decodedImagePreloadMB: 672,
                remotePageDataCacheMB: 800,
                remotePageDataDiskMB: 2_048,
                remotePrefetchMB: 768
            )
        case 4..<6:
            return ReaderMemoryBudget(
                decodedImageCacheMB: 640,
                decodedImagePreloadMB: 480,
                remotePageDataCacheMB: 256,
                remotePageDataDiskMB: 1_536,
                remotePrefetchMB: 512
            )
        case 3..<4:
            return ReaderMemoryBudget(
                decodedImageCacheMB: 512,
                decodedImagePreloadMB: 384,
                remotePageDataCacheMB: 192,
                remotePageDataDiskMB: 1_024,
                remotePrefetchMB: 384
            )
        default:
            return ReaderMemoryBudget(
                decodedImageCacheMB: 384,
                decodedImagePreloadMB: 288,
                remotePageDataCacheMB: 128,
                remotePageDataDiskMB: 512,
                remotePrefetchMB: 256
            )
        }
    }

    /// 解码位图缓存的下限（3GB 机型，即 iPad mini 5）。
    static let minimumDecodedImageCacheMB = 384

    static func budget() -> ReaderMemoryBudget {
        budget(forPhysicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
    }
}
