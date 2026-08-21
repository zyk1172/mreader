import BackgroundTasks
import Foundation

/// 后台续行只服务于用户已经显式启动的离线任务，不会在启动时自行创建 AI 请求。
@MainActor
final class OfflineTranslationBackgroundScheduler {
    static let shared = OfflineTranslationBackgroundScheduler()

    private let continuedIdentifier = "\(Bundle.main.bundleIdentifier ?? "zhengyk.mreader").offline-translation.continued"
    private let processingIdentifier = "zhengyk.mreader.offline-translation.processing"
    private let pendingJobKey = "offline_translation_pending_background_job"
    private let pendingComicKey = "offline_translation_pending_background_comic"
    private var didRegister = false
    private var registeredContinuedIdentifiers: Set<String> = []
    private var startupRecoveryTask: Task<Void, Never>?

    private init() {}

    func register() {
        guard !didRegister else { return }
        didRegister = true
        if #available(iOS 26.0, *) {
            if let pendingJobID {
                registerContinuedTask(identifier: continuedTaskIdentifier(for: pendingJobID))
            }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: processingIdentifier, using: nil) { [weak self] task in
            Task { @MainActor [weak self] in
                await self?.handle(task)
            }
        }
        startupRecoveryTask = Task { @MainActor in
            if let count = try? await OfflineTranslationJobStore.shared.markRunningJobsInterrupted(), count > 0 {
                print("MReader marked \(count) offline translation jobs interrupted after relaunch")
            }
            if let reconciled = try? await OfflineTranslationStorageManager.shared.reconcileAllManifests(), reconciled > 0 {
                print("MReader reconciled \(reconciled) offline translation manifests after relaunch")
            }
        }
    }

    var pendingJobID: UUID? {
        UserDefaults.standard.string(forKey: pendingJobKey).flatMap(UUID.init(uuidString:))
    }

    func submit(job: OfflineTranslationJobRecord, comic: ComicBook) {
        UserDefaults.standard.set(job.id.uuidString, forKey: pendingJobKey)
        UserDefaults.standard.set(comic.id.uuidString, forKey: pendingComicKey)

        if #available(iOS 26.0, *) {
            let identifier = continuedTaskIdentifier(for: job.id)
            registerContinuedTask(identifier: identifier)
            let request = BGContinuedProcessingTaskRequest(
                identifier: identifier,
                title: "offlineTranslation.title".localized,
                subtitle: comic.title
            )
            request.strategy = .queue
            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                // 前台执行仍会继续；记录失败便于定位系统未接受后台续行的原因。
                print("MReader failed to submit continued offline translation job \(job.id): \(error.localizedDescription)")
            }
        } else {
            let request = BGProcessingTaskRequest(identifier: processingIdentifier)
            request.requiresNetworkConnectivity = true
            request.earliestBeginDate = Date(timeIntervalSinceNow: 30)
            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                print("MReader failed to submit processing offline translation job \(job.id): \(error.localizedDescription)")
            }
        }
    }

    @available(iOS 26.0, *)
    private func registerContinuedTask(identifier: String) {
        guard registeredContinuedIdentifiers.insert(identifier).inserted else { return }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { [weak self] task in
            Task { @MainActor [weak self] in
                await self?.handle(task)
            }
        }
    }

    private func continuedTaskIdentifier(for jobID: UUID) -> String {
        "\(continuedIdentifier).\(jobID.uuidString)"
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
        await startupRecoveryTask?.value
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
            guard OfflineTranslationCoordinator.shared.job?.id == jobID else { return false }
            if #available(iOS 26.0, *), let continued = task as? BGContinuedProcessingTask {
                await waitForContinuedCoordinator(jobID: jobID, continuedTask: continued)
            } else {
                await waitForCoordinator(jobID: jobID)
            }
            let state = OfflineTranslationCoordinator.shared.job?.state
            return state == .completed || state == .completedWithFailures
        }

        let library = ComicLibraryStore()
        var comic: ComicBook?
        for _ in 0..<20 {
            comic = library.comics.first(where: { $0.id == comicID })
            if comic != nil { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard let comic else {
            return false
        }
        guard let job = try? await OfflineTranslationJobStore.shared.claimJobForBackgroundExecution(
            comicID: comicID,
            jobID: jobID
        ) else { return false }

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
