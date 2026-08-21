import Foundation
import SwiftUI
import Combine

nonisolated enum BackgroundTaskDestination: Equatable, Identifiable, Sendable {
    case offlineTranslation(comicID: UUID, jobID: UUID)

    var id: String {
        switch self {
        case .offlineTranslation(let comicID, let jobID):
            return "offlineTranslation:\(comicID.uuidString):\(jobID.uuidString)"
        }
    }
}

struct MReaderBackgroundTask: Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var detail: String?
    var progress: Double?
    var destination: BackgroundTaskDestination?
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
    func begin(
        title: String,
        detail: String? = nil,
        progress: Double? = nil,
        destination: BackgroundTaskDestination? = nil
    ) -> UUID {
        let id = UUID()
        tasks.append(
            MReaderBackgroundTask(
                id: id,
                title: title,
                detail: detail,
                progress: normalizedProgress(progress),
                destination: destination,
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
    var onSelect: (BackgroundTaskDestination) -> Void = { _ in }

    var body: some View {
        Menu {
            ForEach(center.tasks) { task in
                if let destination = task.destination {
                    Button {
                        onSelect(destination)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(task.title)
                            if let detail = task.detail {
                                Text(detail)
                            }
                        }
                    }
                } else {
                    VStack(alignment: .leading) {
                        Text(task.title)
                        if let detail = task.detail {
                            Text(detail)
                        }
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
            .accessibilityLabel("background.processing".localized)
            .accessibilityValue("background.taskCount".localizedFormat(center.tasks.count))
        }
    }
}
