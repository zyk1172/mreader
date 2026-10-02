import Foundation
import UIKit

/// An abandoned decode may finish after a replacement with the same source key.
/// Identity protects cleanup; cancellation prevents a foreground join of abandoned work.
nonisolated struct ReaderImageLoadEntry: @unchecked Sendable {
    let id = UUID()
    let task: Task<UIImage?, Never>
    var canJoin: Bool { !task.isCancelled }
}
