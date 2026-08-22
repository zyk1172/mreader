import BackgroundTasks
import Foundation

nonisolated enum OfflineTranslationPendingRecoveryDecision: Equatable, Sendable {
    case waitForLibrary
    case clearPending
    case resume

    static func resolve(
        libraryLoaded: Bool,
        comicExists: Bool,
        job: OfflineTranslationJobRecord?
    ) -> Self {
        guard libraryLoaded else { return .waitForLibrary }
        guard comicExists, let job else { return .clearPending }
        return job.state.isBackgroundResumable ? .resume : .clearPending
    }
}

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
    private var resumeInFlightJobIDs: Set<UUID> = []

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

    private var pendingComicID: UUID? {
        UserDefaults.standard.string(forKey: pendingComicKey).flatMap(UUID.init(uuidString:))
    }

    /// 应用冷启动后自动接管仍应继续的任务。用户主动暂停/取消、策略暂停、磁盘不足和配置错误
    /// 都会清除 pending 标记，因此不会在这里被重新启动。
    func resumePendingJobIfNeeded() async {
        await startupRecoveryTask?.value
        guard !OfflineTranslationCoordinator.shared.isRunning else { return }
        guard let jobID = pendingJobID,
              let comicID = pendingComicID else {
            if UserDefaults.standard.object(forKey: pendingJobKey) != nil
                || UserDefaults.standard.object(forKey: pendingComicKey) != nil {
                clearMalformedPendingMarker()
            }
            return
        }
        guard resumeInFlightJobIDs.insert(jobID).inserted else { return }
        defer { resumeInFlightJobIDs.remove(jobID) }

        let library = ComicLibraryStore()
        var comic: ComicBook?
        for _ in 0..<20 where !library.isLoaded {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard library.isLoaded else {
            // 书架仍在初始化，不能把暂时的空数组当作“漫画已删除”。保留 marker，
            // 交给下一次启动或后台唤醒继续尝试。
            return
        }
        comic = library.comics.first(where: { $0.id == comicID })
        let job = await OfflineTranslationJobStore.shared.load(comicID: comicID, jobID: jobID)
        switch OfflineTranslationPendingRecoveryDecision.resolve(
            libraryLoaded: true,
            comicExists: comic != nil,
            job: job
        ) {
        case .waitForLibrary:
            return
        case .clearPending:
            clearPending(jobID: jobID)
            return
        case .resume:
            break
        }
        guard let comic, let job else {
            clearPending(jobID: jobID)
            return
        }
        OfflineTranslationCoordinator.shared.resume(
            job,
            comic: comic,
            submitBackgroundContinuation: false
        )
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
        let isCurrentPendingJob = UserDefaults.standard.string(forKey: pendingJobKey) == jobID.uuidString
        if #available(iOS 26.0, *) {
            // 每个 continued request 都绑定单独 Job；即使 pending 指针已指向新 Job，也要撤销
            // 旧 Job 的系统请求，避免它迟到唤醒后参与任何恢复路径。
            BGTaskScheduler.shared.cancel(
                taskRequestWithIdentifier: continuedTaskIdentifier(for: jobID)
            )
        } else if isCurrentPendingJob {
            // 旧系统版本复用 processing identifier，只能在清当前 pending 时取消，不能误伤新任务。
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: processingIdentifier)
        }
        guard isCurrentPendingJob else { return }
        UserDefaults.standard.removeObject(forKey: pendingJobKey)
        UserDefaults.standard.removeObject(forKey: pendingComicKey)
    }

    private func clearMalformedPendingMarker() {
        if #unavailable(iOS 26.0) {
            // 旧系统使用共享 identifier；iOS 26 的 request 必须绑定合法 Job UUID，
            // 损坏的 marker 无法安全推导对应 request。
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: processingIdentifier)
        }
        UserDefaults.standard.removeObject(forKey: pendingJobKey)
        UserDefaults.standard.removeObject(forKey: pendingComicKey)
    }

    private func handle(_ task: BGTask) async {
        task.expirationHandler = {
            Task { @MainActor in
                OfflineTranslationCoordinator.shared.suspendForSystemExpiration()
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
        if #available(iOS 26.0, *), let continued = task as? BGContinuedProcessingTask,
           continued.identifier != continuedTaskIdentifier(for: jobID) {
            // 系统迟到交付的 Job A 绝不能读取当前 pending Job B 并错误恢复 B。
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

        guard resumeInFlightJobIDs.insert(jobID).inserted else { return false }
        defer { resumeInFlightJobIDs.remove(jobID) }

        let library = ComicLibraryStore()
        var comic: ComicBook?
        for _ in 0..<20 {
            comic = library.comics.first(where: { $0.id == comicID })
            if comic != nil { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard let comic else {
            clearPending(jobID: jobID)
            return false
        }
        guard let job = try? await OfflineTranslationJobStore.shared.claimJobForBackgroundExecution(
            comicID: comicID,
            jobID: jobID
        ) else {
            let storedJob = await OfflineTranslationJobStore.shared.load(comicID: comicID, jobID: jobID)
            if storedJob == nil || storedJob?.state.isBackgroundResumable == false {
                clearPending(jobID: jobID)
            }
            return false
        }

        if #available(iOS 26.0, *), let continued = task as? BGContinuedProcessingTask {
            OfflineTranslationCoordinator.shared.resume(
                job,
                comic: comic,
                submitBackgroundContinuation: false
            )
            await waitForContinuedCoordinator(jobID: jobID, continuedTask: continued)
        } else {
            OfflineTranslationCoordinator.shared.resume(
                job,
                comic: comic,
                submitBackgroundContinuation: false
            )
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
