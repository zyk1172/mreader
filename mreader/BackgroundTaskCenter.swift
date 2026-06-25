import Foundation
import SwiftUI
import Combine

struct MReaderBackgroundTask: Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var detail: String?
    var progress: Double?
    let startedAt: Date
}

@MainActor
final class BackgroundTaskCenter: ObservableObject {
    static let shared = BackgroundTaskCenter()

    @Published private(set) var tasks: [MReaderBackgroundTask] = []

    var isActive: Bool {
        !tasks.isEmpty
    }

    @discardableResult
    func begin(title: String, detail: String? = nil, progress: Double? = nil) -> UUID {
        let id = UUID()
        tasks.append(
            MReaderBackgroundTask(
                id: id,
                title: title,
                detail: detail,
                progress: normalizedProgress(progress),
                startedAt: Date()
            )
        )
        return id
    }

    func update(_ id: UUID, detail: String? = nil, progress: Double? = nil) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        if let detail {
            tasks[index].detail = detail
        }
        if let progress {
            tasks[index].progress = normalizedProgress(progress)
        }
    }

    func finish(_ id: UUID) {
        tasks.removeAll { $0.id == id }
    }

    private func normalizedProgress(_ progress: Double?) -> Double? {
        guard let progress else { return nil }
        return min(max(progress, 0), 1)
    }
}

struct BackgroundTaskIndicator: View {
    @ObservedObject var center: BackgroundTaskCenter

    var body: some View {
        Menu {
            ForEach(center.tasks) { task in
                VStack(alignment: .leading) {
                    Text(task.title)
                    if let detail = task.detail {
                        Text(detail)
                    }
                }
            }
        } label: {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let angle = timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 1.1) / 1.1 * 360
                ZStack {
                    Circle()
                        .stroke(Color.blue.opacity(0.24), lineWidth: 3)
                    Circle()
                        .trim(from: 0.08, to: 0.72)
                        .stroke(
                            Color.blue,
                            style: StrokeStyle(lineWidth: 3, lineCap: .round)
                        )
                        .rotationEffect(.degrees(angle))
                    Image(systemName: "gearshape.2.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.blue)
                }
                .frame(width: 25, height: 25)
            }
            .accessibilityLabel("后台处理中")
            .accessibilityValue("\(center.tasks.count) 个任务")
        }
    }
}
