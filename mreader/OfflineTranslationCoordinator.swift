import Foundation
import UIKit
import Combine

nonisolated private enum OfflineTranslationRunError: LocalizedError {
    case needsConfiguration(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .needsConfiguration(let message), .failed(let message):
            return message
        }
    }
}

nonisolated private struct OfflineTranslationPageWork: @unchecked Sendable {
    let page: ComicPage
    let comic: ComicBook
    let sourceSession: OfflineTranslationPageProvider.SourceSession
    let configuration: AIActiveConfiguration
    let sourceLanguage: TranslationSourceLanguage
    let targetLanguage: TranslationTargetLanguage
    let styleInstructions: String
    let previousContext: String
    let isRightToLeft: Bool
    let processingMode: OfflineTranslationProcessingMode
    let ocrRecognitionMode: OCRRecognitionMode
    let usesVisualOCRVerification: Bool
    let setID: UUID
}

nonisolated private struct OfflineTranslationPageWorkerResult: @unchecked Sendable {
    let pageIndex: Int
    let state: OfflineTranslationPageState?
    let retryCount: Int
    let resolvedSourceLanguage: String?
    let resolvedSourceLanguageConfidence: Double?
    let errorMessage: String?
    let isPolicyRefusal: Bool
    let needsConfiguration: Bool
}

nonisolated private struct OfflineTranslationRetryFailure: LocalizedError {
    let message: String
    let retryCount: Int
    let isPolicyRefusal: Bool

    var errorDescription: String? { message }
}

nonisolated enum OfflineTranslationStopMode: Equatable, Sendable {
    case pause
    case cancel
    case systemInterruption
}

nonisolated enum OfflineTranslationCancellationDisposition: Equatable, Sendable {
    case paused
    case cancelled
    case interrupted

    static func resolve(stopMode: OfflineTranslationStopMode?) -> Self {
        switch stopMode {
        case .cancel:
            return .cancelled
        case .systemInterruption:
            return .interrupted
        default:
            return .paused
        }
    }
}

nonisolated enum OfflineTranslationExpirationDecision: Equatable, Sendable {
    case ignore
    case interrupt

    static func resolve(expiredJobID: UUID?, activeTaskJobID: UUID?) -> Self {
        guard let expiredJobID, let activeTaskJobID,
              expiredJobID == activeTaskJobID else {
            return .ignore
        }
        return .interrupt
    }
}

/// 整本任务的唯一执行协调器：全局单任务、固定批次并发，checkpoint 顺序为 page -> manifest -> job。
@MainActor
final class OfflineTranslationCoordinator: ObservableObject {
    static let shared = OfflineTranslationCoordinator()
    private static let maxConcurrentPages = 3
    private static let expensiveRevisionValidationPageInterval = 48
    private static let expensiveRevisionValidationTimeInterval: TimeInterval = 60

    @Published private(set) var job: OfflineTranslationJobRecord?
    @Published private(set) var manifest: OfflineTranslationSetManifest?
    @Published private(set) var progress: Double = 0
    @Published private(set) var isRunning = false
    @Published private(set) var preparingJobID: UUID?
    @Published private(set) var activeTaskJobID: UUID?
    @Published private(set) var lastError: String?

    private let storage = OfflineTranslationStorageManager.shared
    private let jobStore = OfflineTranslationJobStore.shared
    private var task: Task<Void, Never>?
    private var stopMode: OfflineTranslationStopMode?
    private var isPreparingRebind = false

    private init() {}

    var canStart: Bool { task == nil && !isPreparingRebind }

    func start(
        comic: ComicBook,
        selection: OfflineTranslationSelection,
        sourceLanguage: TranslationSourceLanguage,
        targetLanguage: TranslationTargetLanguage,
        styleInstructions: String,
        readingDirectionRaw: String,
        activateWhenComplete: Bool = true,
        providerID: UUID? = nil,
        visionModel: String? = nil,
        processingMode: OfflineTranslationProcessingMode = .ocrText,
        textModel: String? = nil,
        ocrRecognitionMode: OCRRecognitionMode = .adaptive,
        usesVisualOCRVerification: Bool = false,
        sourceSetID: UUID? = nil
    ) {
        guard task == nil else { return }
        lastError = nil
        stopMode = nil
        let taskJobID = UUID()
        preparingJobID = taskJobID
        activeTaskJobID = taskJobID
        task = Task { [weak self] in
            guard let self else { return }
            await self.startNewJob(
                jobID: taskJobID,
                comic: comic,
                selection: selection,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                styleInstructions: styleInstructions,
                readingDirectionRaw: readingDirectionRaw,
                activateWhenComplete: activateWhenComplete,
                providerID: providerID,
                visionModel: visionModel,
                processingMode: processingMode,
                textModel: textModel,
                ocrRecognitionMode: ocrRecognitionMode,
                usesVisualOCRVerification: usesVisualOCRVerification,
                sourceSetID: sourceSetID
            )
        }
    }

    /// 用户主动继续时才提交新的后台续行请求。系统已经交付后台任务、或冷启动自动恢复时，
    /// 只恢复现有 Job，不能在后台 handler 内再次创建 BGContinuedProcessingTaskRequest。
    func resume(
        _ savedJob: OfflineTranslationJobRecord,
        comic: ComicBook,
        submitBackgroundContinuation: Bool = true
    ) {
        guard task == nil else { return }
        lastError = nil
        preparingJobID = savedJob.id
        activeTaskJobID = savedJob.id
        task = Task { [weak self] in
            guard let self else { return }
            await self.resumeJob(
                savedJob,
                comic: comic,
                styleInstructions: savedJob.styleInstructions
                    ?? AITranslator.defaultTranslationStyleInstructions,
                submitBackgroundContinuation: submitBackgroundContinuation
            )
        }
    }

    /// 重新绑定已暂停任务的 Provider/Vision 模型。旧任务保留为历史记录，
    /// 新任务从旧 Set 继承仍有效页面，并只处理失败页和未处理页。
    func rebind(
        _ savedJob: OfflineTranslationJobRecord,
        comic: ComicBook,
        providerID: UUID,
        visionModel: String,
        textModel: String
    ) {
        guard canStart else { return }
        isPreparingRebind = true
        Task { [weak self] in
            guard let self else { return }
            let sourceSession = OfflineTranslationPageProvider.sourceSession(for: comic)
            do {
                try await self.validateSourceRevision(
                    for: savedJob,
                    comic: comic,
                    sourceSession: sourceSession
                )
            } catch {
                self.isPreparingRebind = false
                await self.markNeedsConfiguration(savedJob, message: error.localizedDescription)
                return
            }
            let states = await self.storage.pageStates(
                comicID: savedJob.comicID,
                setID: savedJob.setID
            )
            // nextPageOffset 和旧 Job 数组都只是兼容字段；重新绑定同样按页文件状态计算剩余页。
            let remaining = OfflineTranslationPageFacts.remainingPageIndexes(
                plannedPageIndexes: savedJob.pageIndexes,
                states: states
            )
            self.isPreparingRebind = false
            guard !remaining.isEmpty else { return }
            self.start(
                comic: comic,
                selection: .explicitPages(remaining),
                sourceLanguage: savedJob.sourceLanguage,
                targetLanguage: savedJob.targetLanguage,
                styleInstructions: savedJob.styleInstructions ?? AITranslator.defaultTranslationStyleInstructions,
                readingDirectionRaw: savedJob.readingDirectionRaw,
                activateWhenComplete: savedJob.activateWhenComplete ?? true,
                providerID: providerID,
                visionModel: visionModel,
                processingMode: savedJob.processingMode ?? .vision,
                textModel: textModel,
                ocrRecognitionMode: savedJob.ocrRecognitionMode ?? .adaptive,
                usesVisualOCRVerification: savedJob.usesVisualOCRVerification ?? false,
                sourceSetID: savedJob.setID
            )
        }
    }

    func pause() {
        guard task != nil else { return }
        stopMode = .pause
        task?.cancel()
    }

    /// BGTask 到期属于系统中断：保存为 interrupted 并保留 pending 标记，供下次启动自动续传。
    func suspendForSystemExpiration(for expiredJobID: UUID) {
        guard task != nil,
              OfflineTranslationExpirationDecision.resolve(
                  expiredJobID: expiredJobID,
                  activeTaskJobID: activeTaskJobID
              ) == .interrupt else {
            return
        }
        stopMode = .systemInterruption
        task?.cancel()
    }

    func cancel() {
        guard task != nil else { return }
        stopMode = .cancel
        task?.cancel()
    }

    func clearError() {
        lastError = nil
    }

    private func startNewJob(
        jobID: UUID,
        comic: ComicBook,
        selection: OfflineTranslationSelection,
        sourceLanguage: TranslationSourceLanguage,
        targetLanguage: TranslationTargetLanguage,
        styleInstructions: String,
        readingDirectionRaw: String,
        activateWhenComplete: Bool,
        providerID: UUID?,
        visionModel: String?,
        processingMode: OfflineTranslationProcessingMode,
        textModel: String?,
        ocrRecognitionMode: OCRRecognitionMode,
        usesVisualOCRVerification: Bool,
        sourceSetID: UUID?
    ) async {
        defer {
            if preparingJobID == jobID {
                preparingJobID = nil
            }
            if activeTaskJobID == jobID {
                activeTaskJobID = nil
            }
        }
        var persistedSetID: UUID?
        var jobWasSaved = false
        do {
            let configuration = try frozenConfiguration(
                for: providerID,
                expectedVisionModel: visionModel,
                expectedTextModel: textModel,
                requiresVision: processingMode == .vision || usesVisualOCRVerification
            )
            let sourceSession = OfflineTranslationPageProvider.sourceSession(for: comic)
            let pages = try await loadPages(for: comic)
            let totalPages = pages.count
            let sourceRevision = try await OfflineTranslationPageProvider.sourceRevision(for: comic, session: sourceSession)
            let promptSnapshot = OfflineTranslationPromptBuilder.make(
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                isRightToLeft: readingDirectionRaw == "rightToLeft",
                styleInstructions: styleInstructions,
                previousContext: ""
            )
            let active = await storage.activeManifest(for: comic.id, targetLanguage: targetLanguage)
            // 范围任务通常不会成为 active Set；下一次范围翻译仍应从最新可渲染的 Set
            // 派生，才能累积此前已经完成的页面，而不是只保留本次选中的范围。
            let latestRenderable = await storage.latestRenderableManifest(
                for: comic.id,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage
            )
            let sourceSet: OfflineTranslationSetManifest?
            if let sourceSetID {
                // A retry/missing-pages request must inherit from the explicitly selected set,
                // even when that set is not currently active.
                sourceSet = await storage.manifest(comicID: comic.id, setID: sourceSetID)
            } else {
                sourceSet = latestRenderable ?? active
            }
            let canReuseSourceSet = sourceSet.map {
                $0.targetLanguage == targetLanguage
                    && $0.sourceLanguage == sourceLanguage
                    && $0.sourceRevision == sourceRevision
                    && OfflineTranslationPageProvider.isReliableSourceRevision(sourceRevision)
            } ?? false
            let existingStates: [Int: OfflineTranslationPageState]
            if let sourceSet, canReuseSourceSet {
                existingStates = await storage.pageStates(comicID: comic.id, setID: sourceSet.id)
            } else {
                existingStates = [:]
            }
            let pageIndexes = try selection.pageIndexes(
                totalPages: totalPages,
                currentPageIndex: min(max(comic.currentPageIndex, 0), max(totalPages - 1, 0)),
                existingStates: existingStates
            )

            let manifestValue = OfflineTranslationSetManifest(
                comicID: comic.id,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                providerID: configuration.profileID,
                providerName: configuration.profileName,
                baseURL: configuration.baseURL,
                visionModel: configuration.visionModel,
                promptRevision: OfflineTranslationPromptBuilder.revision,
                promptSnapshot: promptSnapshot,
                totalPages: totalPages,
                derivedFromSetID: sourceSet?.id,
                sourceRevision: sourceRevision,
                processingMode: processingMode,
                textModel: configuration.textModel,
                ocrRecognitionMode: ocrRecognitionMode,
                usesVisualOCRVerification: usesVisualOCRVerification
            )
            persistedSetID = manifestValue.id
            try await storage.saveManifest(manifestValue, activate: false)
            if let sourceSet, canReuseSourceSet {
                _ = try await storage.copyValidPages(
                    from: sourceSet.id,
                    to: manifestValue,
                    excludingPageIndexes: Set(pageIndexes)
                )
            }

            var record = OfflineTranslationJobRecord(
                id: jobID,
                comicID: comic.id,
                setID: manifestValue.id,
                selection: selection,
                pageIndexes: pageIndexes,
                providerID: configuration.profileID,
                providerName: configuration.profileName,
                baseURL: configuration.baseURL,
                visionModel: configuration.visionModel,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                promptRevision: OfflineTranslationPromptBuilder.revision,
                promptSnapshot: promptSnapshot,
                styleInstructions: styleInstructions,
                activateWhenComplete: activateWhenComplete,
                readingDirectionRaw: readingDirectionRaw,
                totalPages: totalPages,
                processingMode: processingMode,
                textModel: configuration.textModel,
                ocrRecognitionMode: ocrRecognitionMode,
                usesVisualOCRVerification: usesVisualOCRVerification
            )
            record.state = .running
            try await jobStore.save(record)
            jobWasSaved = true
            OfflineTranslationBackgroundScheduler.shared.submit(job: record, comic: comic)
            job = record
            manifest = await storage.manifest(comicID: comic.id, setID: manifestValue.id)
            progress = record.pageIndexes.isEmpty
                ? 1
                : Double(record.nextPageOffset) / Double(record.pageIndexes.count)
            isRunning = true
            preparingJobID = nil
            await execute(
                record,
                comic: comic,
                pages: pages,
                configuration: configuration,
                styleInstructions: styleInstructions,
                sourceSession: sourceSession
            )
        } catch {
            if !jobWasSaved, let persistedSetID {
                try? await storage.discardUncommittedSet(comicID: comic.id, setID: persistedSetID)
            }
            isRunning = false
            lastError = error.localizedDescription
            task = nil
        }
    }

    private func resumeJob(
        _ savedJob: OfflineTranslationJobRecord,
        comic: ComicBook,
        styleInstructions: String,
        submitBackgroundContinuation: Bool
    ) async {
        defer {
            if preparingJobID == savedJob.id {
                preparingJobID = nil
            }
            if activeTaskJobID == savedJob.id {
                activeTaskJobID = nil
            }
        }
        do {
            guard savedJob.promptRevision == OfflineTranslationPromptBuilder.revision else {
                throw OfflineTranslationRunError.needsConfiguration(
                    "翻译协议已更新，请基于现有译本创建新的翻译任务"
                )
            }
            let configuration = try frozenConfiguration(
                for: savedJob.providerID,
                expectedVisionModel: savedJob.visionModel,
                expectedTextModel: savedJob.textModel,
                expectedBaseURL: savedJob.baseURL,
                requiresVision: (savedJob.processingMode ?? .vision) == .vision
                    || (savedJob.usesVisualOCRVerification ?? false)
            )
            let sourceSession = OfflineTranslationPageProvider.sourceSession(for: comic)
            let pages = try await loadPages(for: comic)
            guard pages.count == savedJob.totalPages else {
                throw OfflineTranslationRunError.failed("漫画页数已变化，无法安全续传")
            }
            try await validateSourceRevision(
                for: savedJob,
                comic: comic,
                sourceSession: sourceSession
            )
            var record = savedJob
            record.state = .running
            record.lastError = nil
            record.updatedAt = Date()
            try await jobStore.save(record)
            if submitBackgroundContinuation {
                OfflineTranslationBackgroundScheduler.shared.submit(job: record, comic: comic)
            }
            job = record
            manifest = try? await storage.reconcileManifest(comicID: record.comicID, setID: record.setID)
            progress = record.pageIndexes.isEmpty
                ? 1
                : Double(min(record.nextPageOffset, record.pageIndexes.count)) / Double(record.pageIndexes.count)
            isRunning = true
            preparingJobID = nil
            await execute(
                record,
                comic: comic,
                pages: pages,
                configuration: configuration,
                styleInstructions: styleInstructions,
                sourceSession: sourceSession
            )
        } catch is CancellationError {
            isRunning = false
            var recoveryJob = savedJob
            switch OfflineTranslationCancellationDisposition.resolve(stopMode: stopMode) {
            case .cancelled:
                recoveryJob.state = .cancelled
                recoveryJob.pauseReason = nil
                recoveryJob.lastError = "用户取消了任务"
            case .interrupted:
                recoveryJob.state = .interrupted
                recoveryJob.pauseReason = OfflineTranslationPauseReason.interrupted.rawValue
                recoveryJob.lastError = "系统中断，应用下次启动后自动继续"
            case .paused:
                recoveryJob.state = .paused
                recoveryJob.pauseReason = OfflineTranslationPauseReason.userRequested.rawValue
                recoveryJob.lastError = "任务已暂停，可继续处理"
            }
            recoveryJob.updatedAt = Date()
            try? await jobStore.save(recoveryJob)
            job = recoveryJob
            lastError = recoveryJob.lastError
            if OfflineTranslationCancellationDisposition.resolve(stopMode: stopMode) != .interrupted {
                OfflineTranslationBackgroundScheduler.shared.clearPending(jobID: savedJob.id)
            }
            manifest = await storage.manifest(comicID: recoveryJob.comicID, setID: recoveryJob.setID)
            stopMode = nil
            task = nil
        } catch {
            isRunning = false
            lastError = error.localizedDescription
            var recoveryJob = savedJob
            if error is OfflineTranslationConfigurationError {
                recoveryJob.state = .needsConfiguration
            } else if case OfflineTranslationRunError.needsConfiguration = error {
                recoveryJob.state = .needsConfiguration
            } else {
                recoveryJob.state = .interrupted
            }
            recoveryJob.lastError = error.localizedDescription
            recoveryJob.updatedAt = Date()
            try? await jobStore.save(recoveryJob)
            job = recoveryJob
            OfflineTranslationBackgroundScheduler.shared.clearPending(jobID: savedJob.id)
            task = nil
        }
    }

    /// 已完成页面是断点续传的事实来源，因此恢复、重绑和运行中的每个批次都必须确认
    /// 它们仍属于同一版漫画。仅比较页数会让“前半本旧文件 + 后半本新文件”混进同一 Set。
    private func validateSourceRevision(
        for record: OfflineTranslationJobRecord,
        comic: ComicBook,
        sourceSession: OfflineTranslationPageProvider.SourceSession,
        allowsUnverifiedCurrentRun: Bool = false
    ) async throws {
        guard let savedManifest = await storage.manifest(
            comicID: record.comicID,
            setID: record.setID
        ) else {
            throw OfflineTranslationRunError.failed("找不到离线翻译任务对应的译本")
        }
        let currentRevision = try await OfflineTranslationPageProvider.sourceRevision(
            for: comic,
            session: sourceSession
        )
        guard allowsUnverifiedCurrentRun
                || (OfflineTranslationPageProvider.isReliableSourceRevision(savedManifest.sourceRevision)
                    && OfflineTranslationPageProvider.isReliableSourceRevision(currentRevision)) else {
            throw OfflineTranslationRunError.needsConfiguration(
                "远程漫画源未提供可验证版本信息，不能安全恢复或继承旧翻译任务，请重新开始翻译"
            )
        }
        guard savedManifest.sourceRevision == currentRevision else {
            throw OfflineTranslationRunError.needsConfiguration(
                "漫画原文件已发生变化，不能继续写入原翻译任务，请重新建立翻译任务"
            )
        }
    }

    private func markNeedsConfiguration(
        _ savedJob: OfflineTranslationJobRecord,
        message: String
    ) async {
        var record = savedJob
        record.state = .needsConfiguration
        record.lastError = message
        record.updatedAt = Date()
        try? await jobStore.save(record)
        job = record
        lastError = message
        OfflineTranslationBackgroundScheduler.shared.clearPending(jobID: record.id)
    }

    private func execute(
        _ initialJob: OfflineTranslationJobRecord,
        comic: ComicBook,
        pages: [ComicPage],
        configuration: AIActiveConfiguration,
        styleInstructions: String,
        sourceSession: OfflineTranslationPageProvider.SourceSession
    ) async {
        var record = initialJob
        let taskID = BackgroundTaskCenter.shared.begin(
            title: "offlineTranslation.title".localized,
            detail: comic.title,
            progress: progress,
            destination: .offlineTranslation(comicID: comic.id, jobID: record.id)
        )
        defer {
            BackgroundTaskCenter.shared.finish(taskID)
            isRunning = false
            task = nil
            stopMode = nil
            if activeTaskJobID == initialJob.id {
                activeTaskJobID = nil
            }
        }

        // 页文件状态是断点续传的事实来源，但不能在每个 3 页 batch 重复扫描整本 JSON。
        // 启动/恢复时读一次，随后按 worker 的落盘结果增量更新；结束时再做一次最终 reconcile。
        var pageStateSnapshot = await storage.pageStates(
            comicID: initialJob.comicID,
            setID: initialJob.setID
        )
        do {
            var attemptedThisRun = Set<Int>()
            let usesExpensiveRevision = OfflineTranslationPageProvider.usesExpensiveSourceRevision(
                for: comic,
                session: sourceSession
            )
            let shouldPeriodicallyValidateRevision = OfflineTranslationPageProvider
                .shouldPeriodicallyValidateSourceRevision(for: comic)
            // startNewJob 已在建 Set 前生成 revision，resume/rebind 也已经强制校验。目录
            // 漫画只在最终激活前再次做全内容哈希；远程源才按页数/时间轮询版本 metadata。
            var lastFullRevisionValidation = Date()
            var pagesSinceFullRevisionValidation = 0
            while true {
                try Task.checkCancellation()
                if !usesExpensiveRevision
                    || (shouldPeriodicallyValidateRevision
                        && (pagesSinceFullRevisionValidation >= Self.expensiveRevisionValidationPageInterval
                            || Date().timeIntervalSince(lastFullRevisionValidation) >= Self.expensiveRevisionValidationTimeInterval)) {
                    try await validateSourceRevision(
                        for: record,
                        comic: comic,
                        sourceSession: sourceSession,
                        allowsUnverifiedCurrentRun: true
                    )
                    lastFullRevisionValidation = Date()
                    pagesSinceFullRevisionValidation = 0
                }
                try await storage.ensureSufficientDiskSpace()

                // nextPageOffset 只保留为旧 UI 的兼容字段；当前执行期使用同一份内存快照，
                // 避免每个 batch 都全量读取所有 page JSON。
                synchronizeRecordWithPageFacts(&record, states: pageStateSnapshot)
                let remaining = remainingPageIndexes(
                    for: record,
                    states: pageStateSnapshot,
                    excluding: attemptedThisRun
                )
                guard !remaining.isEmpty else { break }

                let batch = Array(remaining.prefix(Self.maxConcurrentPages))
                let contextSnapshot = await fixedBatchContexts(
                    for: batch,
                    comicID: record.comicID,
                    setID: record.setID,
                    minimumPageIndex: record.pageIndexes.min() ?? 0
                )
                let processingMode = record.processingMode ?? .vision
                let sourcePreference = TranslationSourceLanguage(rawValue: record.resolvedSourceLanguage ?? "")
                    ?? record.sourceLanguage
                let works = try batch.map { pageIndex in
                    OfflineTranslationPageWork(
                        page: try pageAt(pageIndex, pages: pages),
                        comic: comic,
                        sourceSession: sourceSession,
                        configuration: configuration,
                        sourceLanguage: sourcePreference,
                        targetLanguage: record.targetLanguage,
                        styleInstructions: styleInstructions,
                        previousContext: contextSnapshot[pageIndex] ?? "",
                        isRightToLeft: record.readingDirectionRaw == "rightToLeft",
                        processingMode: processingMode,
                        ocrRecognitionMode: record.ocrRecognitionMode ?? .adaptive,
                        usesVisualOCRVerification: record.usesVisualOCRVerification ?? false,
                        setID: record.setID
                    )
                }

                record.activePageIndexes = batch
                record.currentPageIndex = batch.first
                record.state = .running
                record.updatedAt = Date()
                progress = progressValue(for: record)
                try await checkpoint(record)
                BackgroundTaskCenter.shared.update(
                    taskID,
                    detail: "\(comic.title) · \(batch.map { $0 + 1 }.sorted().map(String.init).joined(separator: ", "))/\(record.totalPages)",
                    progress: progress
                )

                let workerStorage = storage
                var results: [OfflineTranslationPageWorkerResult] = []
                try await withThrowingTaskGroup(of: OfflineTranslationPageWorkerResult.self) { group in
                    for work in works {
                        group.addTask {
                            try await Self.processPage(work, storage: workerStorage)
                        }
                    }
                    for try await result in group {
                        results.append(result)
                        if result.state != nil {
                            // worker 在返回前已经完成 page -> manifest 落盘；按完成顺序通知 Reader，
                            // 不必等待同一批的其他页面结束。
                            NotificationCenter.default.post(
                                name: .offlineTranslationPageDidUpdate,
                                object: nil,
                                userInfo: [
                                    OfflineTranslationNotificationKey.comicID: record.comicID,
                                    OfflineTranslationNotificationKey.setID: record.setID,
                                    OfflineTranslationNotificationKey.pageIndex: result.pageIndex
                                ]
                            )
                        }
                    }
                }

                var hasFailure = false
                var needsConfigurationMessage: String?
                var providerPolicyBlocked = false
                for result in results.sorted(by: { $0.pageIndex < $1.pageIndex }) {
                    attemptedThisRun.insert(result.pageIndex)
                    record.retryCounts[String(result.pageIndex), default: 0] += result.retryCount
                    if record.sourceLanguage == .automatic,
                       record.resolvedSourceLanguage == nil,
                       let resolvedSourceLanguage = result.resolvedSourceLanguage,
                       let confidence = result.resolvedSourceLanguageConfidence {
                        var consensus = OfflineTranslationSourceLanguageConsensus(
                            votes: record.sourceLanguageVotes ?? [:],
                            sampleCount: record.sourceLanguageSampleCount ?? 0
                        )
                        consensus.register(
                            languageCode: resolvedSourceLanguage,
                            confidence: confidence
                        )
                        record.sourceLanguageVotes = consensus.votes
                        record.sourceLanguageSampleCount = consensus.sampleCount
                        record.resolvedSourceLanguage = consensus.resolvedLanguageCode
                    }

                    if let state = result.state {
                        registerSuccess(state, pageIndex: result.pageIndex, in: &record)
                        pageStateSnapshot[result.pageIndex] = state
                    } else if result.needsConfiguration {
                        needsConfigurationMessage = needsConfigurationMessage ?? result.errorMessage
                        // worker 在请求前已写入 processing；配置错误会立即退出本轮，保留这一
                        // 状态供重绑/恢复路径重新计算 remaining pages。
                        pageStateSnapshot[result.pageIndex] = .processing
                    } else {
                        hasFailure = true
                        registerFailure(result.pageIndex, in: &record)
                        record.lastError = result.errorMessage
                        // 失败 worker 已尽力将 .failed 落盘；即使失败页写入本身失败，也不能
                        // 在本轮被重复调度，attemptedThisRun 会和快照共同保证这一点。
                        pageStateSnapshot[result.pageIndex] = .failed
                    }

                    if result.isPolicyRefusal {
                        let failures = (record.consecutiveProviderPolicyFailures ?? 0) + 1
                        record.consecutiveProviderPolicyFailures = failures
                        providerPolicyBlocked = providerPolicyBlocked
                            || failures >= OfflineTranslationPolicyCircuit.refusalThreshold
                    } else if !result.needsConfiguration {
                        // 以页索引排序处理结果，保证并发完成顺序不会改变熔断计数。
                        record.consecutiveProviderPolicyFailures = 0
                    }
                }

                record.activePageIndexes = []
                record.currentPageIndex = nil
                synchronizeRecordWithPageFacts(&record, states: pageStateSnapshot)
                record.updatedAt = Date()
                if providerPolicyBlocked {
                    record.state = .paused
                    record.pauseReason = OfflineTranslationPauseReason.providerPolicyBlocked.rawValue
                    let modelRole = record.processingMode == .ocrText ? "Text" : "Vision"
                    record.lastError = "当前模型连续多页触发内容策略限制，任务已暂停。请更换 \(modelRole) 模型后继续。"
                    try await checkpoint(record)
                    lastError = record.lastError
                    OfflineTranslationBackgroundScheduler.shared.clearPending(jobID: record.id)
                    return
                }
                if let needsConfigurationMessage {
                    record.state = .needsConfiguration
                    record.lastError = needsConfigurationMessage
                    try await checkpoint(record)
                    lastError = needsConfigurationMessage
                    OfflineTranslationBackgroundScheduler.shared.clearPending(jobID: record.id)
                    return
                }
                if !hasFailure {
                    record.lastError = nil
                }
                try await checkpoint(record)
                progress = progressValue(for: record)
                pagesSinceFullRevisionValidation += results.count
            }

            // 整本任务可能持续数小时；在最终激活前再做一次校验，不能把已经被替换的
            // 源文件对应的旧页自动设为 active。
            try await validateSourceRevision(
                for: record,
                comic: comic,
                sourceSession: sourceSession,
                allowsUnverifiedCurrentRun: true
            )
            let finalManifest = try? await storage.reconcileManifest(
                comicID: record.comicID,
                setID: record.setID
            )
            pageStateSnapshot = await storage.pageStates(
                comicID: record.comicID,
                setID: record.setID
            )
            synchronizeRecordWithPageFacts(&record, states: pageStateSnapshot)
            record.state = OfflineTranslationJobState.completionState(
                failedPageCount: record.failedPageIndexes.count,
                partialPageCount: finalManifest?.partialPageCount ?? 0
            )
            record.activePageIndexes = []
            record.currentPageIndex = nil
            record.updatedAt = Date()
            try await checkpoint(record)
            if record.state == .completed,
               record.activateWhenComplete ?? true,
               finalManifest?.isCompleteSet == true,
               (finalManifest?.coveredPageCount ?? 0) > 0 {
                try? await storage.setActive(comicID: record.comicID, setID: record.setID)
            }
            OfflineTranslationBackgroundScheduler.shared.clearPending(jobID: record.id)
            manifest = finalManifest
        } catch OfflineTranslationRunError.needsConfiguration(let message) {
            synchronizeRecordWithPageFacts(&record, states: pageStateSnapshot)
            record.activePageIndexes = []
            record.currentPageIndex = nil
            record.state = .needsConfiguration
            record.pauseReason = nil
            record.lastError = message
            record.updatedAt = Date()
            try? await jobStore.save(record)
            job = record
            lastError = message
            OfflineTranslationBackgroundScheduler.shared.clearPending(jobID: record.id)
            manifest = await storage.manifest(comicID: record.comicID, setID: record.setID)
        } catch OfflineTranslationStorageError.lowDiskSpace {
            synchronizeRecordWithPageFacts(&record, states: pageStateSnapshot)
            record.activePageIndexes = []
            record.currentPageIndex = nil
            record.state = .paused
            record.pauseReason = OfflineTranslationPauseReason.lowDiskSpace.rawValue
            record.lastError = OfflineTranslationStorageError.lowDiskSpace.localizedDescription
            record.updatedAt = Date()
            try? await jobStore.save(record)
            job = record
            lastError = record.lastError
            OfflineTranslationBackgroundScheduler.shared.clearPending(jobID: record.id)
            manifest = await storage.manifest(comicID: record.comicID, setID: record.setID)
        } catch is CancellationError {
            synchronizeRecordWithPageFacts(&record, states: pageStateSnapshot)
            record.activePageIndexes = []
            record.currentPageIndex = nil
            switch OfflineTranslationCancellationDisposition.resolve(stopMode: stopMode) {
            case .cancelled:
                record.state = .cancelled
                record.pauseReason = nil
                record.lastError = "用户取消了任务"
            case .interrupted:
                record.state = .interrupted
                record.pauseReason = OfflineTranslationPauseReason.interrupted.rawValue
                record.lastError = "系统中断，应用下次启动后自动继续"
            case .paused:
                record.state = .paused
                record.pauseReason = OfflineTranslationPauseReason.userRequested.rawValue
                record.lastError = "任务已暂停，可继续处理"
            }
            record.updatedAt = Date()
            try? await jobStore.save(record)
            job = record
            lastError = record.lastError
            if OfflineTranslationCancellationDisposition.resolve(stopMode: stopMode) != .interrupted {
                OfflineTranslationBackgroundScheduler.shared.clearPending(jobID: record.id)
            }
            manifest = await storage.manifest(comicID: record.comicID, setID: record.setID)
        } catch {
            synchronizeRecordWithPageFacts(&record, states: pageStateSnapshot)
            record.activePageIndexes = []
            record.currentPageIndex = nil
            record.state = .interrupted
            record.pauseReason = OfflineTranslationPauseReason.interrupted.rawValue
            record.lastError = error.localizedDescription
            record.updatedAt = Date()
            try? await jobStore.save(record)
            job = record
            OfflineTranslationBackgroundScheduler.shared.clearPending(jobID: record.id)
            lastError = error.localizedDescription
            manifest = await storage.manifest(comicID: record.comicID, setID: record.setID)
        }
    }

    nonisolated private static func processPage(
        _ work: OfflineTranslationPageWork,
        storage: OfflineTranslationStorageManager
    ) async throws -> OfflineTranslationPageWorkerResult {
        try Task.checkCancellation()
        try await storage.ensureSufficientDiskSpace()

        var sourceData: Data?
        var sourceFingerprint = ""
        var pixelWidth = 0
        var pixelHeight = 0
        do {
            let loadedData = try await OfflineTranslationPageProvider.data(
                for: work.comic,
                page: work.page,
                session: work.sourceSession
            )
            sourceData = loadedData
            sourceFingerprint = OfflineTranslationPageProvider.fingerprint(
                for: loadedData,
                pageURL: work.page.url
            )
            let image = try OfflineTranslationPageProvider.image(
                for: loadedData,
                pageIndex: work.page.index
            )
            pixelWidth = image.cgImage?.width ?? Int(image.size.width * image.scale)
            pixelHeight = image.cgImage?.height ?? Int(image.size.height * image.scale)

            if let existing = await storage.page(
                comicID: work.comic.id,
                setID: work.setID,
                pageIndex: work.page.index
            ),
               (existing.state == .completed || existing.state == .noText),
               existing.sourceFingerprint == sourceFingerprint {
                return OfflineTranslationPageWorkerResult(
                    pageIndex: work.page.index,
                    state: existing.state,
                    retryCount: 0,
                    resolvedSourceLanguage: existing.resolvedSourceLanguage,
                    resolvedSourceLanguageConfidence: nil,
                    errorMessage: nil,
                    isPolicyRefusal: false,
                    needsConfiguration: false
                )
            }

            let processingPage = OfflineTranslatedPage(
                comicID: work.comic.id,
                setID: work.setID,
                pageIndex: work.page.index,
                sourceFingerprint: sourceFingerprint,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                blocks: [],
                state: .processing,
                providerID: work.configuration.profileID,
                visionModel: work.configuration.visionModel
            )
            try await storage.savePageAndUpdateManifest(processingPage)

            let (initialTranslationResult, initialRetryCount) = try await translatePageWithRetry(
                pageURL: work.page.url,
                image: image,
                configuration: work.configuration,
                sourceLanguage: work.sourceLanguage,
                targetLanguage: work.targetLanguage,
                styleInstructions: work.styleInstructions,
                previousContext: work.previousContext,
                isRightToLeft: work.isRightToLeft,
                viewportAspect: max(image.size.height / max(image.size.width, 1), 1.25),
                processingMode: work.processingMode,
                ocrRecognitionMode: work.ocrRecognitionMode,
                usesVisualOCRVerification: work.usesVisualOCRVerification
            )
            var translationResult = initialTranslationResult
            var retryCount = initialRetryCount

            if work.processingMode == .vision {
                var localOCR: OCRPipelineResult?
                var localOCRError: Error?
                do {
                    localOCR = try await MangaOCRPipeline.recognize(
                        in: image,
                        options: OCRPreprocessor.Options(
                            isRightToLeft: work.isRightToLeft,
                            minimumTextHeight: 0.002,
                            recognitionMode: work.ocrRecognitionMode,
                            sourceLanguagePreference: work.sourceLanguage
                        )
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    localOCR = nil
                    localOCRError = error
                    print("MReader offline geometry refinement skipped page=\(work.page.index + 1) reason=\(error.localizedDescription)")
                }

                if case .noText = translationResult, let localOCRError {
                    // Vision 的 noText 只有在本地 OCR 成功确认无正文时才成立；验证过程失败
                    // 必须让页面进入失败/重试路径，不能永久伪装成空页。
                    throw localOCRError
                }

                if let localOCR {
                    let localOCRLineBlocks = localOCR.lineBlocks
                    switch translationResult {
                    case .translated(let blocks):
                        translationResult = .translated(
                            TranslationGeometryRefiner.refine(
                                visionBlocks: blocks,
                                localOCRBlocks: localOCRLineBlocks,
                                isRightToLeft: work.isRightToLeft
                            )
                        )
                    case .partial(let blocks, let failedSlices):
                        translationResult = .partial(
                            TranslationGeometryRefiner.refine(
                                visionBlocks: blocks,
                                localOCRBlocks: localOCRLineBlocks,
                                isRightToLeft: work.isRightToLeft
                            ),
                            failedSlices: failedSlices
                        )
                    case .noText:
                        // 合法 Vision 空页只有在本地 OCR 也没有正文时才可保存为 noText。
                        // 本地已识别到文字则改走 Text Model，失败会按页重试/失败处理。
                        let filteredLocalBubbles = AITranslationPagePipeline.filteredOCRBubbles(
                            from: localOCR,
                            minimumTextHeight: 0.008,
                            isRightToLeft: work.isRightToLeft
                        )
                        guard !filteredLocalBubbles.isEmpty else { break }
                        let fallback = try await translateLocalOCRFallbackWithRetry(
                            filteredLocalBubbles,
                            work: work,
                            image: image
                        )
                        translationResult = fallback.result.missingBlockIDs.isEmpty
                            ? .translated(fallback.result.blocks)
                            : .partial(fallback.result.blocks, failedSlices: fallback.result.missingBlockIDs.count)
                        retryCount += fallback.retryCount
                    }
                }
            }

            let pageState: OfflineTranslationPageState
            let blocks: [OfflineTranslatedBlock]
            var sourceLanguageDecision: TranslationSourceDecision?
            switch translationResult {
            case .noText:
                pageState = .noText
                blocks = []
            case .translated(let translatedBlocks):
                pageState = translatedBlocks.isEmpty ? .noText : .completed
                blocks = translatedBlocks.enumerated().map { index, block in
                    block.offlineTranslatedBlock(id: "b\(index)")
                }
                sourceLanguageDecision = Self.sourceLanguageDecision(from: translatedBlocks)
            case .partial(let translatedBlocks, _):
                pageState = translatedBlocks.isEmpty ? .noText : .partial
                blocks = translatedBlocks.enumerated().map { index, block in
                    block.offlineTranslatedBlock(id: "b\(index)")
                }
                sourceLanguageDecision = Self.sourceLanguageDecision(from: translatedBlocks)
            }

            let savedPage = OfflineTranslatedPage(
                comicID: work.comic.id,
                setID: work.setID,
                pageIndex: work.page.index,
                sourceFingerprint: sourceFingerprint,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                blocks: blocks,
                state: pageState,
                providerID: work.configuration.profileID,
                visionModel: work.configuration.visionModel,
                resolvedSourceLanguage: sourceLanguageDecision?.languageCode
            )
            try await storage.savePageAndUpdateManifest(savedPage)
            return OfflineTranslationPageWorkerResult(
                pageIndex: work.page.index,
                state: pageState,
                retryCount: retryCount,
                resolvedSourceLanguage: sourceLanguageDecision?.languageCode,
                resolvedSourceLanguageConfidence: sourceLanguageDecision?.confidence,
                errorMessage: nil,
                isPolicyRefusal: false,
                needsConfiguration: false
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch OfflineTranslationStorageError.lowDiskSpace {
            throw OfflineTranslationStorageError.lowDiskSpace
        } catch OfflineTranslationRunError.needsConfiguration(let message) {
            return OfflineTranslationPageWorkerResult(
                pageIndex: work.page.index,
                state: nil,
                retryCount: 0,
                resolvedSourceLanguage: nil,
                resolvedSourceLanguageConfidence: nil,
                errorMessage: message,
                isPolicyRefusal: false,
                needsConfiguration: true
            )
        } catch let retryFailure as OfflineTranslationRetryFailure {
            let failedPage = OfflineTranslatedPage(
                comicID: work.comic.id,
                setID: work.setID,
                pageIndex: work.page.index,
                sourceFingerprint: sourceFingerprint.isEmpty
                    ? sourceData.map { OfflineTranslationFingerprint.sha256(for: $0) } ?? ""
                    : sourceFingerprint,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                blocks: [],
                state: .failed,
                providerID: work.configuration.profileID,
                visionModel: work.configuration.visionModel,
                errorMessage: retryFailure.message
            )
            try? await storage.savePageAndUpdateManifest(failedPage)
            return OfflineTranslationPageWorkerResult(
                pageIndex: work.page.index,
                state: nil,
                retryCount: retryFailure.retryCount,
                resolvedSourceLanguage: nil,
                resolvedSourceLanguageConfidence: nil,
                errorMessage: retryFailure.message,
                isPolicyRefusal: retryFailure.isPolicyRefusal,
                needsConfiguration: false
            )
        } catch {
            let message = error.localizedDescription
            let failedPage = OfflineTranslatedPage(
                comicID: work.comic.id,
                setID: work.setID,
                pageIndex: work.page.index,
                sourceFingerprint: sourceFingerprint.isEmpty
                    ? sourceData.map { OfflineTranslationFingerprint.sha256(for: $0) } ?? ""
                    : sourceFingerprint,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                blocks: [],
                state: .failed,
                providerID: work.configuration.profileID,
                visionModel: work.configuration.visionModel,
                errorMessage: message
            )
            try? await storage.savePageAndUpdateManifest(failedPage)
            return OfflineTranslationPageWorkerResult(
                pageIndex: work.page.index,
                state: nil,
                retryCount: 0,
                resolvedSourceLanguage: nil,
                resolvedSourceLanguageConfidence: nil,
                errorMessage: message,
                isPolicyRefusal: OfflineTranslationPolicyCircuit.isProviderRefusal(error),
                needsConfiguration: false
            )
        }
    }

    nonisolated private static func sourceLanguageDecision(from blocks: [TextBlock]) -> TranslationSourceDecision? {
        TranslationSourceResolver.resolve(
            preference: .automatic,
            blocks: blocks,
            previousStableLanguage: nil
        )
    }

    nonisolated private static func translatePageWithRetry(
        pageURL: URL,
        image: UIImage,
        configuration: AIActiveConfiguration,
        sourceLanguage: TranslationSourceLanguage,
        targetLanguage: TranslationTargetLanguage,
        styleInstructions: String,
        previousContext: String,
        isRightToLeft: Bool,
        viewportAspect: CGFloat,
        processingMode: OfflineTranslationProcessingMode,
        ocrRecognitionMode: OCRRecognitionMode,
        usesVisualOCRVerification: Bool
    ) async throws -> (OfflineVisionPageResult, retryCount: Int) {
        var attempt = 0
        while true {
            do {
                let result: OfflineVisionPageResult
                switch processingMode {
                case .ocrText:
                    let request = AITranslationPageRequest(
                        pageURL: pageURL,
                        image: image,
                        mode: .ocr,
                        configuration: configuration,
                        target: targetLanguage,
                        translationPromptTemplate: styleInstructions,
                        visionPromptTemplate: AITranslator.defaultVisionTranslationPromptTemplate,
                        isRightToLeft: isRightToLeft,
                        minimumTextHeight: 0.008,
                        ocrRecognitionMode: ocrRecognitionMode,
                        safeAreaInset: 0,
                        usesVisualOCRVerification: usesVisualOCRVerification,
                        viewportAspect: viewportAspect,
                        sourceLanguagePreference: sourceLanguage,
                        previousContext: previousContext
                    )
                    let ocrResult = try await AITranslationPagePipeline.translateOCRPageWithStatus(request)
                    if ocrResult.blocks.isEmpty {
                        result = .noText
                    } else if ocrResult.missingBlockIDs.isEmpty {
                        result = .translated(ocrResult.blocks)
                    } else {
                        result = .partial(
                            ocrResult.blocks,
                            failedSlices: ocrResult.missingBlockIDs.count
                        )
                    }
                case .vision:
                    result = try await AITranslator.recognizeOfflineVisionPage(
                        image: image,
                        apiKey: configuration.apiKey,
                        baseURL: configuration.baseURL,
                        visionModel: configuration.visionModel,
                        sourceLanguage: sourceLanguage,
                        targetLanguage: targetLanguage,
                        styleInstructions: styleInstructions,
                        previousContext: previousContext,
                        isRightToLeft: isRightToLeft,
                        viewportAspect: viewportAspect,
                        modelDescriptor: configuration.visionModelDescriptor
                    )
                }
                return (result, retryCount: attempt)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                switch OfflineTranslationRetryPolicy.decision(for: error, attempt: attempt) {
                case .needsConfiguration:
                    throw OfflineTranslationRunError.needsConfiguration(error.localizedDescription)
                case .retry(let delay):
                    attempt += 1
                    try await Task.sleep(nanoseconds: delay * 1_000_000_000)
                case .fail:
                    throw OfflineTranslationRetryFailure(
                        message: error.localizedDescription,
                        retryCount: attempt,
                        isPolicyRefusal: OfflineTranslationPolicyCircuit.isProviderRefusal(error)
                    )
                }
            }
        }
    }

    nonisolated private static func translateLocalOCRFallbackWithRetry(
        _ bubbles: [TextBlock],
        work: OfflineTranslationPageWork,
        image: UIImage
    ) async throws -> (result: AITranslationOCRResult, retryCount: Int) {
        var attempt = 0
        let request = AITranslationPageRequest(
            pageURL: work.page.url,
            image: image,
            mode: .ocr,
            configuration: work.configuration,
            target: work.targetLanguage,
            translationPromptTemplate: work.styleInstructions,
            visionPromptTemplate: AITranslator.defaultVisionTranslationPromptTemplate,
            isRightToLeft: work.isRightToLeft,
            minimumTextHeight: 0.002,
            ocrRecognitionMode: work.ocrRecognitionMode,
            safeAreaInset: 0,
            usesVisualOCRVerification: false,
            viewportAspect: max(image.size.height / max(image.size.width, 1), 1.25),
            sourceLanguagePreference: work.sourceLanguage,
            previousContext: work.previousContext
        )
        while true {
            do {
                let result = try await AITranslationPagePipeline.translateExistingOCRBubbles(
                    bubbles,
                    request: request
                )
                return (result, attempt)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                switch OfflineTranslationRetryPolicy.decision(for: error, attempt: attempt) {
                case .needsConfiguration:
                    throw OfflineTranslationRunError.needsConfiguration(error.localizedDescription)
                case .retry(let delay):
                    attempt += 1
                    try await Task.sleep(nanoseconds: delay * 1_000_000_000)
                case .fail:
                    throw OfflineTranslationRetryFailure(
                        message: error.localizedDescription,
                        retryCount: attempt,
                        isPolicyRefusal: OfflineTranslationPolicyCircuit.isProviderRefusal(error)
                    )
                }
            }
        }
    }

    private func remainingPageIndexes(
        for record: OfflineTranslationJobRecord,
        states: [Int: OfflineTranslationPageState],
        excluding attemptedPageIndexes: Set<Int>
    ) -> [Int] {
        return OfflineTranslationPageFacts.remainingPageIndexes(
            plannedPageIndexes: record.pageIndexes,
            states: states,
            excluding: attemptedPageIndexes
        )
    }

    private func fixedBatchContexts(
        for pageIndexes: [Int],
        comicID: UUID,
        setID: UUID,
        minimumPageIndex: Int
    ) async -> [Int: String] {
        var contexts: [Int: String] = [:]
        for pageIndex in pageIndexes.sorted() {
            contexts[pageIndex] = await previousPageContext(
                comicID: comicID,
                setID: setID,
                pageIndex: pageIndex,
                minimumPageIndex: minimumPageIndex
            )
        }
        return contexts
    }

    private func synchronizeRecordWithPageFacts(
        _ record: inout OfflineTranslationJobRecord,
        states: [Int: OfflineTranslationPageState]
    ) {
        record.completedPageIndexes = record.pageIndexes.filter { states[$0] == .completed }
        record.noTextPageIndexes = record.pageIndexes.filter { states[$0] == .noText }
        record.partialPageIndexes = record.pageIndexes.filter { states[$0] == .partial }
        record.failedPageIndexes = record.pageIndexes.filter { states[$0] == .failed }
        record.nextPageOffset = OfflineTranslationPageFacts.processedPageCount(
            plannedPageIndexes: record.pageIndexes,
            states: states
        )
    }

    private func progressValue(for record: OfflineTranslationJobRecord) -> Double {
        guard !record.pageIndexes.isEmpty else { return 1 }
        return min(1, Double(record.nextPageOffset) / Double(record.pageIndexes.count))
    }

    private func previousPageContext(
        comicID: UUID,
        setID: UUID,
        pageIndex: Int,
        minimumPageIndex: Int
    ) async -> String {
        guard pageIndex > minimumPageIndex else { return "" }
        let start = max(minimumPageIndex, pageIndex - 2)
        var lines: [String] = []
        for index in start..<pageIndex {
            guard let page = await storage.page(comicID: comicID, setID: setID, pageIndex: index),
                  page.state.isUsableOverlay else { continue }
            for block in page.blocks {
                let translation = block.translation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !translation.isEmpty else { continue }
                lines.append("第\(index + 1)页：\(translation)")
            }
        }
        var context = lines.joined(separator: "\n")
        if context.count > 2200 {
            context = String(context.suffix(2200))
        }
        return context
    }

    private func checkpoint(_ record: OfflineTranslationJobRecord) async throws {
        if var currentManifest = await storage.manifest(comicID: record.comicID, setID: record.setID) {
            currentManifest.resolvedSourceLanguage = record.resolvedSourceLanguage
            try await storage.saveManifest(currentManifest)
            manifest = currentManifest
        } else {
            manifest = nil
        }
        try await jobStore.save(record)
        job = record
    }

    private func registerFailure(
        _ pageIndex: Int,
        in record: inout OfflineTranslationJobRecord
    ) {
        if !record.failedPageIndexes.contains(pageIndex) {
            record.failedPageIndexes.append(pageIndex)
        }
        record.completedPageIndexes.removeAll { $0 == pageIndex }
        record.noTextPageIndexes.removeAll { $0 == pageIndex }
        record.partialPageIndexes?.removeAll { $0 == pageIndex }
    }

    private func registerSuccess(
        _ state: OfflineTranslationPageState,
        pageIndex: Int,
        in record: inout OfflineTranslationJobRecord
    ) {
        switch state {
        case .noText:
            if !record.noTextPageIndexes.contains(pageIndex) { record.noTextPageIndexes.append(pageIndex) }
            record.completedPageIndexes.removeAll { $0 == pageIndex }
            record.partialPageIndexes?.removeAll { $0 == pageIndex }
        case .completed:
            if !record.completedPageIndexes.contains(pageIndex) { record.completedPageIndexes.append(pageIndex) }
            record.noTextPageIndexes.removeAll { $0 == pageIndex }
            record.partialPageIndexes?.removeAll { $0 == pageIndex }
        case .partial:
            if !(record.partialPageIndexes ?? []).contains(pageIndex) {
                record.partialPageIndexes = (record.partialPageIndexes ?? []) + [pageIndex]
            }
            record.completedPageIndexes.removeAll { $0 == pageIndex }
            record.noTextPageIndexes.removeAll { $0 == pageIndex }
        case .pending, .processing, .failed, .stale:
            break
        }
        record.failedPageIndexes.removeAll { $0 == pageIndex }
    }

    private func pageAt(_ index: Int, pages: [ComicPage]) throws -> ComicPage {
        guard pages.indices.contains(index) else {
            throw OfflineTranslationPageProviderError.pageUnavailable(index)
        }
        return pages[index]
    }

    private func loadPages(for comic: ComicBook) async throws -> [ComicPage] {
        guard let pages = await OfflineTranslationPageProvider.loadPages(for: comic), !pages.isEmpty else {
            throw OfflineTranslationPageProviderError.sourceUnavailable
        }
        return pages
    }

    private func frozenConfiguration(
        for providerID: UUID? = nil,
        expectedVisionModel: String? = nil,
        expectedTextModel: String? = nil,
        expectedBaseURL: String? = nil,
        requiresVision: Bool = true
    ) throws -> AIActiveConfiguration {
        let store = AIProviderStore.shared
        let profileID = providerID ?? store.activeProfileID() ?? store.profiles().first?.id
        guard let profileID,
              let profile = store.profiles().first(where: { $0.id == profileID }) else {
            throw OfflineTranslationConfigurationError.missingProvider
        }
        let apiKey = store.apiKey(for: profileID).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw OfflineTranslationConfigurationError.missingAPIKey }
        let baseURL = expectedBaseURL ?? profile.baseURL
        let requestedTextModel = (expectedTextModel ?? profile.selectedTextModel)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedVisionModel = (expectedVisionModel ?? profile.selectedVisionModel)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let textModel: String
        if !requestedTextModel.isEmpty {
            textModel = requestedTextModel
        } else if !requestedVisionModel.isEmpty {
            textModel = requestedVisionModel
        } else {
            throw OfflineTranslationConfigurationError.missingTextModel
        }
        guard !requiresVision || !requestedVisionModel.isEmpty else {
            throw OfflineTranslationConfigurationError.missingVisionModel
        }
        let visionModel = requestedVisionModel.isEmpty ? textModel : requestedVisionModel
        let textDescriptor = profile.descriptor(for: textModel)
        let visionDescriptor = profile.descriptor(for: visionModel)
        guard AIEndpointResolver.endpointURL(for: textDescriptor.apiProtocol, from: baseURL) != nil,
              (!requiresVision || AIEndpointResolver.endpointURL(for: visionDescriptor.apiProtocol, from: baseURL) != nil) else {
            throw OfflineTranslationConfigurationError.invalidBaseURL
        }
        guard !requiresVision || visionDescriptor.supportsVision != false else {
            throw OfflineTranslationConfigurationError.missingVisionModel
        }
        return AIActiveConfiguration(
            profileID: profile.id,
            profileName: profile.name,
            baseURL: baseURL,
            apiKey: apiKey,
            textModel: textModel,
            visionModel: visionModel,
            textModelDescriptor: textDescriptor,
            visionModelDescriptor: visionDescriptor
        )
    }

}
