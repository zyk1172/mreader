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

/// 整本任务的唯一执行协调器：全局单任务、单页串行，checkpoint 顺序为 page -> manifest -> job。
@MainActor
final class OfflineTranslationCoordinator: ObservableObject {
    static let shared = OfflineTranslationCoordinator()

    @Published private(set) var job: OfflineTranslationJobRecord?
    @Published private(set) var manifest: OfflineTranslationSetManifest?
    @Published private(set) var progress: Double = 0
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?

    private let storage = OfflineTranslationStorageManager.shared
    private let jobStore = OfflineTranslationJobStore.shared
    private var task: Task<Void, Never>?
    private var stopMode: StopMode?

    private enum StopMode {
        case pause
        case cancel
    }

    private init() {}

    var canStart: Bool { task == nil }

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
        sourceSetID: UUID? = nil
    ) {
        guard task == nil else { return }
        lastError = nil
        task = Task { [weak self] in
            guard let self else { return }
            await self.startNewJob(
                comic: comic,
                selection: selection,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                styleInstructions: styleInstructions,
                readingDirectionRaw: readingDirectionRaw,
                activateWhenComplete: activateWhenComplete,
                providerID: providerID,
                visionModel: visionModel,
                sourceSetID: sourceSetID
            )
        }
    }

    func resume(_ savedJob: OfflineTranslationJobRecord, comic: ComicBook) {
        guard task == nil else { return }
        lastError = nil
        task = Task { [weak self] in
            guard let self else { return }
            await self.resumeJob(
                savedJob,
                comic: comic,
                styleInstructions: savedJob.styleInstructions
                    ?? AITranslator.defaultTranslationStyleInstructions
            )
        }
    }

    /// 重新绑定已暂停任务的 Provider/Vision 模型。旧任务保留为历史记录，
    /// 新任务从旧 Set 继承仍有效页面，并只处理失败页和未处理页。
    func rebind(
        _ savedJob: OfflineTranslationJobRecord,
        comic: ComicBook,
        providerID: UUID,
        visionModel: String
    ) {
        guard task == nil else { return }
        let remaining = savedJob.pageIndexes.enumerated().compactMap { offset, pageIndex in
            offset >= savedJob.nextPageOffset || savedJob.failedPageIndexes.contains(pageIndex)
                ? pageIndex
                : nil
        }
        guard !remaining.isEmpty else { return }
        start(
            comic: comic,
            selection: .explicitPages(remaining),
            sourceLanguage: savedJob.sourceLanguage,
            targetLanguage: savedJob.targetLanguage,
            styleInstructions: savedJob.styleInstructions ?? AITranslator.defaultTranslationStyleInstructions,
            readingDirectionRaw: savedJob.readingDirectionRaw,
            activateWhenComplete: savedJob.activateWhenComplete ?? true,
            providerID: providerID,
            visionModel: visionModel,
            sourceSetID: savedJob.setID
        )
    }

    func pause() {
        guard task != nil else { return }
        stopMode = .pause
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
        comic: ComicBook,
        selection: OfflineTranslationSelection,
        sourceLanguage: TranslationSourceLanguage,
        targetLanguage: TranslationTargetLanguage,
        styleInstructions: String,
        readingDirectionRaw: String,
        activateWhenComplete: Bool,
        providerID: UUID?,
        visionModel: String?,
        sourceSetID: UUID?
    ) async {
        do {
            let configuration = try frozenConfiguration(
                for: providerID,
                expectedVisionModel: visionModel
            )
            let sourceSession = OfflineTranslationPageProvider.sourceSession(for: comic)
            let pages = try await loadPages(for: comic)
            let totalPages = pages.count
            let promptSnapshot = OfflineTranslationPromptBuilder.make(
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                isRightToLeft: readingDirectionRaw == "rightToLeft",
                styleInstructions: styleInstructions,
                previousContext: ""
            )
            let active = await storage.activeManifest(for: comic.id, targetLanguage: targetLanguage)
            let sourceSet: OfflineTranslationSetManifest?
            if let sourceSetID {
                // A retry/missing-pages request must inherit from the explicitly selected set,
                // even when that set is not currently active.
                sourceSet = await storage.manifest(comicID: comic.id, setID: sourceSetID)
            } else {
                sourceSet = active
            }
            let existingStates: [Int: OfflineTranslationPageState]
            if let sourceSet,
               sourceSet.targetLanguage == targetLanguage,
               sourceSet.sourceLanguage == sourceLanguage {
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
                derivedFromSetID: sourceSet?.id
            )
            let shouldActivateImmediately = sourceSet == nil
            try await storage.saveManifest(manifestValue, activate: shouldActivateImmediately)
            if let sourceSet,
               sourceSet.targetLanguage == targetLanguage,
               sourceSet.sourceLanguage == sourceLanguage {
                var sourceFingerprints: [Int: String] = [:]
                let excluded = Set(pageIndexes)
                for index in 0..<min(sourceSet.totalPages, pages.count) where !excluded.contains(index) {
                    guard let data = try? await OfflineTranslationPageProvider.data(for: comic, page: pages[index], session: sourceSession) else { continue }
                    sourceFingerprints[index] = OfflineTranslationPageProvider.fingerprint(for: data, pageURL: pages[index].url)
                }
                _ = try await storage.copyValidPages(
                    from: sourceSet.id,
                    to: manifestValue,
                    excludingPageIndexes: excluded,
                    sourceFingerprints: sourceFingerprints
                )
            }

            var record = OfflineTranslationJobRecord(
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
                totalPages: totalPages
            )
            record.state = .running
            try await jobStore.save(record)
            OfflineTranslationBackgroundScheduler.shared.submit(job: record, comic: comic)
            job = record
            manifest = await storage.manifest(comicID: comic.id, setID: manifestValue.id)
            progress = record.pageIndexes.isEmpty
                ? 1
                : Double(record.nextPageOffset) / Double(record.pageIndexes.count)
            isRunning = true
            await execute(
                record,
                comic: comic,
                pages: pages,
                configuration: configuration,
                styleInstructions: styleInstructions,
                sourceSession: sourceSession
            )
        } catch {
            isRunning = false
            lastError = error.localizedDescription
            task = nil
        }
    }

    private func resumeJob(
        _ savedJob: OfflineTranslationJobRecord,
        comic: ComicBook,
        styleInstructions: String
    ) async {
        do {
            let configuration = try frozenConfiguration(
                for: savedJob.providerID,
                expectedVisionModel: savedJob.visionModel,
                expectedBaseURL: savedJob.baseURL
            )
            let sourceSession = OfflineTranslationPageProvider.sourceSession(for: comic)
            let pages = try await loadPages(for: comic)
            guard pages.count == savedJob.totalPages else {
                throw OfflineTranslationRunError.failed("漫画页数已变化，无法安全续传")
            }
            var record = savedJob
            record.state = .running
            record.lastError = nil
            record.updatedAt = Date()
            try await jobStore.save(record)
            OfflineTranslationBackgroundScheduler.shared.submit(job: record, comic: comic)
            job = record
            manifest = await storage.manifest(comicID: record.comicID, setID: record.setID)
            progress = record.pageIndexes.isEmpty
                ? 1
                : Double(min(record.nextPageOffset, record.pageIndexes.count)) / Double(record.pageIndexes.count)
            isRunning = true
            await execute(
                record,
                comic: comic,
                pages: pages,
                configuration: configuration,
                styleInstructions: styleInstructions,
                sourceSession: sourceSession
            )
        } catch {
            isRunning = false
            lastError = error.localizedDescription
            var recoveryJob = savedJob
            recoveryJob.state = error is OfflineTranslationConfigurationError
                ? .needsConfiguration
                : .interrupted
            recoveryJob.lastError = error.localizedDescription
            recoveryJob.updatedAt = Date()
            try? await jobStore.save(recoveryJob)
            job = recoveryJob
            OfflineTranslationBackgroundScheduler.shared.clearPending(jobID: savedJob.id)
            task = nil
        }
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
            progress: progress
        )
        defer {
            BackgroundTaskCenter.shared.finish(taskID)
            isRunning = false
            task = nil
            stopMode = nil
        }

        do {
            while record.nextPageOffset < record.pageIndexes.count {
                try Task.checkCancellation()
                try await storage.ensureSufficientDiskSpace()
                let pageIndex = record.pageIndexes[record.nextPageOffset]
                record.currentPageIndex = pageIndex
                record.state = .running
                record.updatedAt = Date()
                try await checkpoint(record)
                BackgroundTaskCenter.shared.update(
                    taskID,
                    detail: "\(comic.title) · \(pageIndex + 1)/\(record.totalPages)",
                    progress: progress
                )

                var sourceData: Data?
                var sourceFingerprint = ""
                var pixelWidth = 0
                var pixelHeight = 0
                do {
                    let page = try pageAt(pageIndex, pages: pages)
                    sourceData = try await OfflineTranslationPageProvider.data(for: comic, page: page, session: sourceSession)
                    guard let sourceData else { throw OfflineTranslationPageProviderError.pageUnavailable(pageIndex) }
                    sourceFingerprint = OfflineTranslationPageProvider.fingerprint(for: sourceData, pageURL: page.url)
                    let image = try OfflineTranslationPageProvider.image(for: sourceData, pageIndex: pageIndex)
                    pixelWidth = image.cgImage?.width ?? Int(image.size.width * image.scale)
                    pixelHeight = image.cgImage?.height ?? Int(image.size.height * image.scale)

                    if let existing = await storage.page(comicID: record.comicID, setID: record.setID, pageIndex: pageIndex),
                       existing.state.isUsableOverlay,
                       existing.sourceFingerprint == sourceFingerprint {
                        registerSuccess(existing.state, pageIndex: pageIndex, in: &record)
                    } else {
                        var processingPage = OfflineTranslatedPage(
                            comicID: record.comicID,
                            setID: record.setID,
                            pageIndex: pageIndex,
                            sourceFingerprint: sourceFingerprint,
                            pixelWidth: pixelWidth,
                            pixelHeight: pixelHeight,
                            blocks: [],
                            state: .processing,
                            providerID: configuration.profileID,
                            visionModel: configuration.visionModel,
                            resolvedSourceLanguage: record.resolvedSourceLanguage
                        )
                        try await storage.savePageAndUpdateManifest(processingPage)

                        let previousContext = await previousPageContext(
                            comicID: record.comicID,
                            setID: record.setID,
                            pageIndex: pageIndex,
                            minimumPageIndex: record.pageIndexes.min() ?? 0
                        )
                        let sourcePreference = TranslationSourceLanguage(rawValue: record.resolvedSourceLanguage ?? "")
                            ?? record.sourceLanguage
                        let result = try await translatePageWithRetry(
                            image: image,
                            configuration: configuration,
                            sourceLanguage: sourcePreference,
                            targetLanguage: record.targetLanguage,
                            styleInstructions: styleInstructions,
                            previousContext: previousContext,
                            isRightToLeft: record.readingDirectionRaw == "rightToLeft",
                            viewportAspect: max(image.size.height / max(image.size.width, 1), 1.25),
                            pageIndex: pageIndex,
                            record: &record
                        )

                        let pageState: OfflineTranslationPageState
                        let blocks: [OfflineTranslatedBlock]
                        switch result {
                        case .noText:
                            pageState = .noText
                            blocks = []
                        case .translated(let translatedBlocks):
                            pageState = translatedBlocks.isEmpty ? .noText : .completed
                            blocks = translatedBlocks.enumerated().map { index, block in
                                block.offlineTranslatedBlock(id: "b\(index)")
                            }
                            if record.sourceLanguage == .automatic,
                               record.resolvedSourceLanguage == nil,
                               let decision = TranslationSourceResolver.resolve(
                                preference: .automatic,
                                blocks: translatedBlocks,
                                previousStableLanguage: nil
                               ) {
                                record.resolvedSourceLanguage = decision.languageCode
                            }
                        case .partial(let translatedBlocks, _):
                            pageState = translatedBlocks.isEmpty ? .noText : .partial
                            blocks = translatedBlocks.enumerated().map { index, block in
                                block.offlineTranslatedBlock(id: "b\(index)")
                            }
                        }
                        processingPage.state = pageState
                        processingPage.resolvedSourceLanguage = record.resolvedSourceLanguage
                        processingPage = OfflineTranslatedPage(
                            comicID: processingPage.comicID,
                            setID: processingPage.setID,
                            pageIndex: processingPage.pageIndex,
                            sourceFingerprint: processingPage.sourceFingerprint,
                            pixelWidth: processingPage.pixelWidth,
                            pixelHeight: processingPage.pixelHeight,
                            blocks: blocks,
                            state: pageState,
                            providerID: processingPage.providerID,
                            visionModel: processingPage.visionModel,
                            resolvedSourceLanguage: record.resolvedSourceLanguage
                        )
                        try await storage.savePageAndUpdateManifest(processingPage)
                        registerSuccess(pageState, pageIndex: pageIndex, in: &record)
                        record.consecutiveProviderPolicyFailures = 0
                    }
                    record.nextPageOffset += 1
                    record.currentPageIndex = nil
                    record.lastError = nil
                    record.updatedAt = Date()
                    try await checkpoint(record)
                } catch is CancellationError {
                    throw CancellationError()
                } catch OfflineTranslationRunError.needsConfiguration(let message) {
                    record.state = .needsConfiguration
                    record.lastError = message
                    record.updatedAt = Date()
                    try? await jobStore.save(record)
                    job = record
                    lastError = message
                    OfflineTranslationBackgroundScheduler.shared.clearPending(jobID: record.id)
                    return
                } catch {
                    let message = error.localizedDescription
                    let loadedSourceData = sourceData
                    if let loadedSourceData {
                        let failedPage = OfflineTranslatedPage(
                            comicID: record.comicID,
                            setID: record.setID,
                            pageIndex: pageIndex,
                            sourceFingerprint: sourceFingerprint.isEmpty
                                ? OfflineTranslationFingerprint.sha256(for: loadedSourceData)
                                : sourceFingerprint,
                            pixelWidth: pixelWidth,
                            pixelHeight: pixelHeight,
                            blocks: [],
                            state: .failed,
                            providerID: configuration.profileID,
                            visionModel: configuration.visionModel,
                            resolvedSourceLanguage: record.resolvedSourceLanguage,
                            errorMessage: message
                        )
                        try? await storage.savePageAndUpdateManifest(failedPage)
                    }
                    if !record.failedPageIndexes.contains(pageIndex) {
                        record.failedPageIndexes.append(pageIndex)
                    }
                    record.lastError = message
                    record.nextPageOffset += 1
                    record.currentPageIndex = nil
                    record.updatedAt = Date()
                    if OfflineTranslationPolicyCircuit.isProviderRefusal(error) {
                        let failures = (record.consecutiveProviderPolicyFailures ?? 0) + 1
                        record.consecutiveProviderPolicyFailures = failures
                        if failures >= OfflineTranslationPolicyCircuit.refusalThreshold {
                            record.state = .paused
                            record.pauseReason = OfflineTranslationPauseReason.providerPolicyBlocked.rawValue
                            record.lastError = "当前模型连续多页触发内容策略限制，任务已暂停。请更换 Vision 模型后继续。"
                            try await checkpoint(record)
                            lastError = record.lastError
                            OfflineTranslationBackgroundScheduler.shared.clearPending(jobID: record.id)
                            manifest = await storage.manifest(comicID: record.comicID, setID: record.setID)
                            return
                        }
                    } else {
                        record.consecutiveProviderPolicyFailures = 0
                    }
                    try await checkpoint(record)
                }
                progress = record.pageIndexes.isEmpty
                    ? 1
                    : Double(record.nextPageOffset) / Double(record.pageIndexes.count)
            }

            record.state = record.failedPageIndexes.isEmpty ? .completed : .completedWithFailures
            record.currentPageIndex = nil
            record.updatedAt = Date()
            try await checkpoint(record)
            if record.state == .completed,
               record.activateWhenComplete ?? true,
               let currentIndex = await storage.index(for: record.comicID),
               currentIndex.activeSetID != record.setID {
                try? await storage.setActive(comicID: record.comicID, setID: record.setID)
            }
            OfflineTranslationBackgroundScheduler.shared.clearPending(jobID: record.id)
            manifest = await storage.manifest(comicID: record.comicID, setID: record.setID)
        } catch OfflineTranslationStorageError.lowDiskSpace {
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
            record.state = stopMode == .cancel ? .cancelled : .paused
            record.pauseReason = stopMode == .cancel
                ? nil
                : OfflineTranslationPauseReason.userRequested.rawValue
            record.lastError = stopMode == .cancel ? "用户取消了任务" : "任务已暂停，可继续处理"
            record.updatedAt = Date()
            try? await jobStore.save(record)
            job = record
            OfflineTranslationBackgroundScheduler.shared.clearPending(jobID: record.id)
            manifest = await storage.manifest(comicID: record.comicID, setID: record.setID)
        } catch {
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

    private func translatePageWithRetry(
        image: UIImage,
        configuration: AIActiveConfiguration,
        sourceLanguage: TranslationSourceLanguage,
        targetLanguage: TranslationTargetLanguage,
        styleInstructions: String,
        previousContext: String,
        isRightToLeft: Bool,
        viewportAspect: CGFloat,
        pageIndex: Int,
        record: inout OfflineTranslationJobRecord
    ) async throws -> OfflineVisionPageResult {
        var attempt = 0
        while true {
            do {
                return try await AITranslator.recognizeOfflineVisionPage(
                    image: image,
                    apiKey: configuration.apiKey,
                    baseURL: configuration.baseURL,
                    visionModel: configuration.visionModel,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage,
                    styleInstructions: styleInstructions,
                    previousContext: previousContext,
                    isRightToLeft: isRightToLeft,
                    viewportAspect: viewportAspect
                )
            } catch {
                switch OfflineTranslationRetryPolicy.decision(for: error, attempt: attempt) {
                case .needsConfiguration:
                    throw OfflineTranslationRunError.needsConfiguration(error.localizedDescription)
                case .retry(let delay):
                    attempt += 1
                    record.retryCounts[String(pageIndex), default: 0] += 1
                    record.updatedAt = Date()
                    try await jobStore.save(record)
                    try await Task.sleep(nanoseconds: delay * 1_000_000_000)
                case .fail:
                    throw error
                }
            }
        }
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

    private func registerSuccess(
        _ state: OfflineTranslationPageState,
        pageIndex: Int,
        in record: inout OfflineTranslationJobRecord
    ) {
        switch state {
        case .noText:
            if !record.noTextPageIndexes.contains(pageIndex) { record.noTextPageIndexes.append(pageIndex) }
        case .completed, .partial:
            if !record.completedPageIndexes.contains(pageIndex) { record.completedPageIndexes.append(pageIndex) }
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
        expectedBaseURL: String? = nil
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
        guard AIEndpointResolver.chatCompletionsURL(from: baseURL) != nil else {
            throw OfflineTranslationConfigurationError.invalidBaseURL
        }
        let visionModel = (expectedVisionModel ?? profile.selectedVisionModel).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !visionModel.isEmpty else { throw OfflineTranslationConfigurationError.missingVisionModel }
        // 恢复任务时只要求 Provider 仍存在并能从 Keychain 取到当前 Key；
        // 文本模型不是本管线输入，视觉模型和 Base URL 使用 Job 中的冻结快照。
        let textModel = profile.selectedTextModel.isEmpty
            ? visionModel
            : profile.selectedTextModel
        return AIActiveConfiguration(
            profileID: profile.id,
            profileName: profile.name,
            baseURL: baseURL,
            apiKey: apiKey,
            textModel: textModel,
            visionModel: visionModel
        )
    }

}
