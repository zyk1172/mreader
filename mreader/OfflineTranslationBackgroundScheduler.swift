import BackgroundTasks
import Foundation

/// 后台续行只服务于用户已经显式启动的离线任务，不会在启动时自行创建 AI 请求。
@MainActor
final class OfflineTranslationBackgroundScheduler {
    static let shared = OfflineTranslationBackgroundScheduler()

    private let continuedIdentifier = "zhengyk.mreader.offline-translation.continued"
    private let processingIdentifier = "zhengyk.mreader.offline-translation.processing"
    private let pendingJobKey = "offline_translation_pending_background_job"
    private let pendingComicKey = "offline_translation_pending_background_comic"
    private var didRegister = false

    private init() {}

    func register() {
        guard !didRegister else { return }
        didRegister = true
        if #available(iOS 26.0, *) {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: continuedIdentifier, using: nil) { [weak self] task in
                Task { @MainActor [weak self] in
                    await self?.handle(task)
                }
            }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: processingIdentifier, using: nil) { [weak self] task in
            Task { @MainActor [weak self] in
                await self?.handle(task)
            }
        }
    }

    func submit(job: OfflineTranslationJobRecord, comic: ComicBook) {
        UserDefaults.standard.set(job.id.uuidString, forKey: pendingJobKey)
        UserDefaults.standard.set(comic.id.uuidString, forKey: pendingComicKey)

        if #available(iOS 26.0, *) {
            let request = BGContinuedProcessingTaskRequest(
                identifier: continuedIdentifier,
                title: "offlineTranslation.title".localized,
                subtitle: comic.title
            )
            request.strategy = .queue
            try? BGTaskScheduler.shared.submit(request)
        } else {
            let request = BGProcessingTaskRequest(identifier: processingIdentifier)
            request.requiresNetworkConnectivity = true
            request.earliestBeginDate = Date(timeIntervalSinceNow: 30)
            try? BGTaskScheduler.shared.submit(request)
        }
    }

    func clearPending(jobID: UUID) {
        guard UserDefaults.standard.string(forKey: pendingJobKey) == jobID.uuidString else { return }
        UserDefaults.standard.removeObject(forKey: pendingJobKey)
        UserDefaults.standard.removeObject(forKey: pendingComicKey)
    }

    private func handle(_ task: BGTask) async {
        task.expirationHandler = {
            Task { @MainActor in
                OfflineTranslationCoordinator.shared.pause()
            }
        }
        let success = await resumePendingTask(task: task)
        task.setTaskCompleted(success: success)
    }

    private func resumePendingTask(task: BGTask) async -> Bool {
        guard let jobIDString = UserDefaults.standard.string(forKey: pendingJobKey),
              let comicIDString = UserDefaults.standard.string(forKey: pendingComicKey),
              let jobID = UUID(uuidString: jobIDString),
              let comicID = UUID(uuidString: comicIDString) else {
            return false
        }
        if OfflineTranslationCoordinator.shared.isRunning {
            return true
        }

        let library = ComicLibraryStore()
        var comic: ComicBook?
        for _ in 0..<20 {
            comic = library.comics.first(where: { $0.id == comicID })
            if comic != nil { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard let comic,
              let job = await OfflineTranslationJobStore.shared.load(comicID: comicID, jobID: jobID) else {
            return false
        }

        if #available(iOS 26.0, *), let continued = task as? BGContinuedProcessingTask {
            OfflineTranslationCoordinator.shared.resume(job, comic: comic)
            await waitForContinuedCoordinator(jobID: jobID, continuedTask: continued)
        } else {
            OfflineTranslationCoordinator.shared.resume(job, comic: comic)
            await waitForCoordinator(jobID: jobID)
        }
        let state = OfflineTranslationCoordinator.shared.job?.state
        if state?.isTerminal == true {
            clearPending(jobID: jobID)
        }
        return state == .completed || state == .completedWithFailures
    }

    private func waitForCoordinator(jobID: UUID) async {
        let startupDeadline = Date().addingTimeInterval(30)
        while true {
            let coordinator = OfflineTranslationCoordinator.shared
            if let currentJob = coordinator.job, currentJob.id == jobID {
                if !coordinator.isRunning {
                    return
                }
            } else if coordinator.canStart {
                // 恢复阶段在创建有效运行状态前失败，避免后台任务无限等待。
                return
            } else if Date() >= startupDeadline {
                return
            }

            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    @available(iOS 26.0, *)
    private func waitForContinuedCoordinator(
        jobID: UUID,
        continuedTask: BGContinuedProcessingTask
    ) async {
        let startupDeadline = Date().addingTimeInterval(30)
        while true {
            let coordinator = OfflineTranslationCoordinator.shared
            if let currentJob = coordinator.job, currentJob.id == jobID {
                if !coordinator.isRunning {
                    return
                }
            } else if coordinator.canStart {
                return
            } else if Date() >= startupDeadline {
                return
            }

            continuedTask.progress.totalUnitCount = 100
            continuedTask.progress.completedUnitCount = Int64(coordinator.progress * 100)
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }
}
