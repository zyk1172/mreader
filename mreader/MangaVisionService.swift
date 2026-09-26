import CryptoKit
import Foundation
import ImageIO
import UIKit
import os

nonisolated struct MangaVisionPerformanceSnapshot: Sendable, Equatable {
    let modelIdentifier: String
    /// Number of uncached page analyses committed by the service.
    let inferenceCount: Int
    /// Number of actual provider model passes. Adaptive long pages may contribute
    /// more than one pass while still committing exactly one page analysis.
    let modelInferencePassCount: Int
    let memoryCacheHitCount: Int
    let diskCacheHitCount: Int
    let diskReconciliationCount: Int
    let lastInferenceMilliseconds: Double?
    let averageInferenceMilliseconds: Double?
    let lastAnalysisMilliseconds: Double?
}

/// Single analysis entry point shared by Guided Panel, OCR, translation and debug.
/// It owns page/model cache identity and in-flight coalescing so consumers never
/// run the Core ML model independently for the same page.
actor MangaVisionService {
    // MangaLayout4 V1 was trained and validated on complete pages. Keep the
    // production path full-page only: crop/tile refinement changes panel geometry
    // and creates duplicate/partial frame navigation targets.
    static let shared = MangaVisionService(
        provider: MangaLayout4V1Provider.shared
    )
    nonisolated static let analysisRevision = "manga-layout4-v1-full-page-v5"

    private struct CacheEnvelope: Codable {
        let manifestIdentity: String
        let analysis: MangaPageAnalysis
    }

    private struct InFlightRequest {
        let id: UUID
        let generation: MangaVisionRequestGeneration
        let startedAt: ContinuousClock.Instant
        let task: Task<MangaPageAnalysis, Error>
        var consumers: Set<UUID>
    }

    private struct DiskEntry {
        let url: URL
        let bytes: Int64
        let modifiedAt: Date
    }

    private let provider: any MangaVisionProvider
    private let fileManager: FileManager
    private let cacheDirectory: URL
    private var cachedManifest: MangaVisionModelManifest?
    private var memoryCache: [String: MangaPageAnalysis] = [:]
    private var memoryOrder: [String] = []
    private var inFlight: [String: InFlightRequest] = [:]
    private var requestGeneration = MangaVisionRequestGeneration(rawValue: 0)
    /// Reader close asks for runtime release, but only once shared/background consumers are idle.
    private var pendingRuntimeReleaseToken: UUID?
    private var activeReaderSessionID: UUID?
    private let memoryPageLimit = 48
    private let diskByteLimit: Int64 = 24 * 1024 * 1024
    private let diskHighWaterBytes: Int64 = 27 * 1024 * 1024

    private var estimatedDiskBytes: Int64
    private var writesSinceDiskReconciliation = 0
    private var lastDiskReconciliationDate = Date()
    private var diskReconciliationCount = 0

    private var inferenceCount = 0
    private var memoryCacheHitCount = 0
    private var diskCacheHitCount = 0
    private var totalInferenceMilliseconds: Double = 0
    private var lastInferenceMilliseconds: Double?
    private var lastAnalysisMilliseconds: Double?
    private var lastDiagnostic: MangaVisionDiagnosticRecord?

    init(
        provider: any MangaVisionProvider,
        cacheDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.provider = provider
        self.fileManager = fileManager
        if let cacheDirectory {
            self.cacheDirectory = cacheDirectory
        } else {
            let root = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            self.cacheDirectory = root.appendingPathComponent("MangaVision", isDirectory: true)
        }
        try? fileManager.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
        self.estimatedDiskBytes = Self.diskUsageBytes(
            in: self.cacheDirectory,
            fileManager: fileManager
        )
        self.diskReconciliationCount = 1
    }

    func analysis(
        comicID: UUID?,
        pageIndex: Int?,
        pageURL: URL,
        image: UIImage,
        contentIdentity: PageContentIdentity? = nil,
        requestClass: MangaVisionRequestClass = .currentTask
    ) async throws -> MangaPageAnalysis {
        let analysisStart = ContinuousClock.now
        let manifest = await modelManifest()
        let resolvedContentIdentity = contentIdentity ?? PageContentIdentityResolver.identity(for: pageURL)
        let sourceFingerprint = resolvedContentIdentity.fingerprint
        let identity = MangaPageIdentifier(
            scope: comicID?.uuidString.lowercased()
                ?? "legacy-\(Self.sha256(pageURL.deletingLastPathComponent().absoluteString))",
            pageIndex: max(pageIndex ?? 0, 0),
            sourceFingerprint: sourceFingerprint
        )
        let demand = analysisDemandIdentity(image: image, manifest: manifest, requestClass: requestClass)
        let modelKey = manifest.cacheIdentity + "|" + demand
        let key = "\(modelKey)|\(identity.scope)|\(identity.pageIndex)|\(sourceFingerprint)"

        if let cached = memoryCache[key] {
            memoryCacheHitCount += 1
            touchMemoryKey(key)
            lastAnalysisMilliseconds = Self.milliseconds(analysisStart.duration(to: .now))
            return cached
        }

        let diskURL = cacheURL(modelKey: modelKey, identity: identity)
        if let cached = readValidCache(
            from: diskURL,
            manifest: manifest,
            identity: identity
        ) {
            diskCacheHitCount += 1
            insertIntoMemory(cached, forKey: key)
            lastAnalysisMilliseconds = Self.milliseconds(analysisStart.duration(to: .now))
            return cached
        }

        let consumerID = UUID()
        if var existing = inFlight[key], existing.generation == requestGeneration {
            existing.consumers.insert(consumerID)
            inFlight[key] = existing
            return try await awaitInFlightRequest(
                existing,
                consumerID: consumerID,
                key: key,
                modelKey: modelKey,
                diskURL: diskURL,
                manifest: manifest,
                identity: identity,
                analysisStart: analysisStart
            )
        }

        let sourceSize = image.cgImage.map { CGSize(width: $0.width, height: $0.height) }
            ?? CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let provider = self.provider
        let sourceAnalyzer = provider as? any MangaVisionSourceImageAnalyzing
        let analysisImage: CGImage?
        if sourceAnalyzer != nil {
            // Adaptive providers need the largest already-decoded source image so tiles can
            // recover detail that would be destroyed by a single 640px full-page shrink.
            analysisImage = image.cgImage
        } else {
            analysisImage = Self.analysisCGImage(
                from: image,
                maximumDimension: Int(max(manifest.inputSize.width, manifest.inputSize.height))
            )
        }
        guard let analysisImage else {
            let error = MangaVisionProviderError.modelUnavailable
            recordFailure(
                error,
                manifest: manifest,
                identity: identity,
                analysisStart: analysisStart,
                outcome: .failure
            )
            throw error
        }

        let generation = requestGeneration
        let requestID = UUID()
        // The task inherits the caller's scheduling priority. The adaptive provider also
        // receives an explicit request class so prefetch work cannot outrank reader work.
        let task = Task {
            let result: MangaPageAnalysis
            if let sourceAnalyzer {
                result = try await sourceAnalyzer.analyzeSourceImage(
                    image: analysisImage,
                    sourceImageSize: sourceSize,
                    pageIdentifier: identity,
                    requestClass: requestClass
                )
            } else {
                result = try await provider.analyzePage(
                    image: analysisImage,
                    sourceImageSize: sourceSize,
                    pageIdentifier: identity
                )
            }
            // Core ML prediction itself is synchronous; if cancellation arrived while it
            // was running, discard the result immediately after the pass returns.
            try Task.checkCancellation()
            return result
        }
        let request = InFlightRequest(
            id: requestID,
            generation: generation,
            startedAt: .now,
            task: task,
            consumers: [consumerID]
        )
        inFlight[key] = request

        return try await awaitInFlightRequest(
            request,
            consumerID: consumerID,
            key: key,
            modelKey: modelKey,
            diskURL: diskURL,
            manifest: manifest,
            identity: identity,
            analysisStart: analysisStart
        )
    }

    private func awaitInFlightRequest(
        _ request: InFlightRequest,
        consumerID: UUID,
        key: String,
        modelKey: String,
        diskURL: URL,
        manifest: MangaVisionModelManifest,
        identity: MangaPageIdentifier,
        analysisStart: ContinuousClock.Instant
    ) async throws -> MangaPageAnalysis {
        try await withTaskCancellationHandler {
            do {
                var value = try await request.task.value
                try Task.checkCancellation()
                value.cacheRevision = value.cacheRevision ?? modelKey
                guard request.generation == requestGeneration else {
                    throw MangaVisionServiceError.staleResult
                }

                let output: MangaPageAnalysis
                if let committed = memoryCache[key] {
                    lastAnalysisMilliseconds = Self.milliseconds(analysisStart.duration(to: .now))
                    output = committed
                } else {
                    output = try finalize(
                        value,
                        request: request,
                        key: key,
                        diskURL: diskURL,
                        manifest: manifest,
                        identity: identity,
                        analysisStart: analysisStart
                    )
                }
                releaseConsumer(key: key, requestID: request.id, consumerID: consumerID)
                return output
            } catch {
                releaseConsumer(key: key, requestID: request.id, consumerID: consumerID)
                // Caller cancellation is consumer-local. Do not tear down a shared request
                // that still has offline/background consumers.
                if !Task.isCancelled {
                    handleFailure(
                        error,
                        request: request,
                        key: key,
                        manifest: manifest,
                        identity: identity,
                        analysisStart: analysisStart
                    )
                }
                throw error
            }
        } onCancel: {
            Task {
                await self.releaseConsumer(
                    key: key,
                    requestID: request.id,
                    consumerID: consumerID
                )
            }
        }
    }

    func cachedAnalysis(
        comicID: UUID?,
        pageIndex: Int?,
        pageURL: URL,
        image: UIImage,
        contentIdentity: PageContentIdentity? = nil,
        requestClass: MangaVisionRequestClass = .interactive
    ) async -> MangaPageAnalysis? {
        let manifest = await modelManifest()
        let resolvedContentIdentity = contentIdentity ?? PageContentIdentityResolver.identity(for: pageURL)
        let sourceFingerprint = resolvedContentIdentity.fingerprint
        let identity = MangaPageIdentifier(
            scope: comicID?.uuidString.lowercased()
                ?? "legacy-\(Self.sha256(pageURL.deletingLastPathComponent().absoluteString))",
            pageIndex: max(pageIndex ?? 0, 0),
            sourceFingerprint: sourceFingerprint
        )
        let modelKey = manifest.cacheIdentity + "|" + analysisDemandIdentity(
            image: image, manifest: manifest, requestClass: requestClass
        )
        let key = "\(modelKey)|\(identity.scope)|\(identity.pageIndex)|\(sourceFingerprint)"
        if let value = memoryCache[key] { return value }
        return readValidCache(
            from: cacheURL(modelKey: modelKey, identity: identity),
            manifest: manifest,
            identity: identity
        )
    }

    /// Uses the reader's already-selected bounded neighbour indices; this method
    /// does not invent a second prefetch horizon or analyze an entire book.
    func preanalyze(
        comicID: UUID,
        pages: [ComicPage],
        indices: [Int]
    ) async {
        let manifest = await modelManifest()
        let inputMaximum = Int(max(manifest.inputSize.width, manifest.inputSize.height))
        let resourceState = MangaVisionResourceState.current
        let usesAdaptiveSource = provider is any MangaVisionSourceImageAnalyzing
        let maximumDimension: Int
        let pageLimit: Int
        if usesAdaptiveSource {
            guard let adaptiveMaximum = MangaVisionInferencePlanner.prefetchMaximumSourceDimension(
                inputSize: manifest.inputSize,
                resourceState: resourceState
            ) else { return }
            maximumDimension = adaptiveMaximum
            pageLimit = MangaVisionInferencePlanner.prefetchPageLimit(resourceState: resourceState)
        } else {
            maximumDimension = inputMaximum
            pageLimit = 3
        }

        for index in indices.prefix(pageLimit) {
            guard pages.indices.contains(index), !Task.isCancelled else { return }
            let page = pages[index]
            let contentIdentity = PageContentIdentityResolver.identity(for: page.url)
            guard let image = await Self.loadAnalysisImage(
                from: page.url,
                maximumDimension: maximumDimension
            ) else { continue }
            _ = try? await analysis(
                comicID: comicID,
                pageIndex: index,
                pageURL: page.url,
                image: image,
                contentIdentity: contentIdentity,
                requestClass: .prefetch
            )
        }
    }

    func dependencyIdentity(for analysis: MangaPageAnalysis?) async -> String {
        let manifest = await modelManifest()
        return analysis?.cacheRevision ?? (manifest.cacheIdentity + "|unavailable")
    }

    /// Returns the cache dependency that an analysis started now would request,
    /// without loading or running the model. Downstream caches can therefore
    /// perform their own memory/disk lookup before paying for Manga Vision.
    func expectedDependencyIdentity(
        image: UIImage,
        requestClass: MangaVisionRequestClass = .currentTask
    ) async -> String {
        let manifest = await modelManifest()
        return manifest.cacheIdentity + "|" + analysisDemandIdentity(
            image: image,
            manifest: manifest,
            requestClass: requestClass
        )
    }

    private func analysisDemandIdentity(
        image: UIImage, manifest: MangaVisionModelManifest,
        requestClass: MangaVisionRequestClass
    ) -> String {
        guard provider is any MangaVisionSourceImageAnalyzing else { return "single-pass" }
        let size = image.cgImage.map { CGSize(width: $0.width, height: $0.height) }
            ?? CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        return MangaVisionInferencePlanner.cacheDemandIdentity(
            sourceSize: size, inputSize: manifest.inputSize,
            requestClass: requestClass, resourceState: .current
        )
    }

    func providerDescriptor() async -> MangaVisionProviderDescriptor {
        await modelManifest().compatibilityDescriptor
    }

    func modelManifestForDiagnostics() async -> MangaVisionModelManifest {
        await modelManifest()
    }

    func performanceSnapshot() async -> MangaVisionPerformanceSnapshot {
        let manifest = await modelManifest()
        let modelInferencePassCount: Int
        if let diagnostics = provider as? any MangaVisionInferencePassDiagnosticsProviding {
            modelInferencePassCount = await diagnostics.totalInferencePassCountForDiagnostics()
        } else {
            // Compatibility providers perform one provider call per uncached service analysis.
            modelInferencePassCount = inferenceCount
        }
        return MangaVisionPerformanceSnapshot(
            modelIdentifier: manifest.modelID,
            inferenceCount: inferenceCount,
            modelInferencePassCount: modelInferencePassCount,
            memoryCacheHitCount: memoryCacheHitCount,
            diskCacheHitCount: diskCacheHitCount,
            diskReconciliationCount: diskReconciliationCount,
            lastInferenceMilliseconds: lastInferenceMilliseconds,
            averageInferenceMilliseconds: inferenceCount > 0
                ? totalInferenceMilliseconds / Double(inferenceCount)
                : nil,
            lastAnalysisMilliseconds: lastAnalysisMilliseconds
        )
    }

    func lastDiagnosticSnapshot() -> MangaVisionDiagnosticRecord? {
        lastDiagnostic
    }

    func diskReconciliationCountForDiagnostics() -> Int {
        diskReconciliationCount
    }

    func currentGenerationForDiagnostics() -> MangaVisionRequestGeneration {
        requestGeneration
    }

    func inFlightConsumerCountForDiagnostics() -> Int {
        inFlight.values.reduce(0) { $0 + $1.consumers.count }
    }

    /// Invalidates outstanding requests without deleting valid cached results. This is used
    /// when a reader/session boundary makes old work irrelevant even if Core ML cannot stop.
    func invalidateInFlightAnalyses() {
        advanceGenerationAndCancelInFlight()
    }

    func beginReaderSession(
        sessionID: UUID,
        requiresActiveReader: Bool = false
    ) async {
        if requiresActiveReader {
            guard await ReaderSessionRegistry.shared.isActive(sessionID) else { return }
        }
        activeReaderSessionID = sessionID
        // A newly opened Reader owns the runtime again. Any deferred unload from the
        // previously closed Reader must not fire after this point.
        pendingRuntimeReleaseToken = nil
    }

    /// Reader 会话结束只清分析内存，并请求“空闲后”卸载 Core ML runtime。
    /// 当前 Reader 的 analysis consumer 会由其 Task cancellation 单独释放；离线翻译/
    /// 后台 OCR 若仍共享同一推理，不应被 Reader 关闭误杀。
    ///
    /// sessionID is supplied by ReaderView in production. Tests may omit it when using an
    /// isolated service instance.
    func releaseReaderSessionMemory(sessionID: UUID? = nil) async {
        if let sessionID {
            guard activeReaderSessionID == sessionID else { return }
            activeReaderSessionID = nil
        }
        memoryCache.removeAll()
        memoryOrder.removeAll()
        let token = UUID()
        pendingRuntimeReleaseToken = token
        await releaseRuntimeIfIdle(token: token)
        MReaderLog.reader.notice("Manga Vision reader-session memory released")
    }

    func clearCache() {
        advanceGenerationAndCancelInFlight()
        memoryCache.removeAll()
        memoryOrder.removeAll()
        try? fileManager.removeItem(at: cacheDirectory)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        estimatedDiskBytes = 0
        writesSinceDiskReconciliation = 0
        lastDiskReconciliationDate = Date()
    }

    private func modelManifest() async -> MangaVisionModelManifest {
        if let cachedManifest { return cachedManifest }

        let manifest: MangaVisionModelManifest
        if let manifestProvider = provider as? any MangaVisionManifestProviding {
            manifest = await manifestProvider.mangaVisionManifest()
        } else {
            // Compatibility providers (primarily tests/alternate adapters) still work.
            // Their descriptor is consulted only when they do not implement the static
            // manifest contract; the MangaLayout4 V1 provider never takes this path.
            let descriptor = await provider.descriptor
            let compatibilityIdentity = "descriptor:\(descriptor.modelIdentifier):\(descriptor.modelVersion)"
            manifest = MangaVisionModelManifest(
                modelID: descriptor.modelIdentifier,
                modelBuildID: compatibilityIdentity,
                modelFileHash: Self.sha256(compatibilityIdentity),
                inputSize: descriptor.inputSize,
                semanticClasses: descriptor.supportedRegionTypes,
                outputContractRevision: "compatibility-output-v1",
                analysisSchemaRevision: "manga-page-analysis-v\(MangaPageAnalysis.schemaVersion)",
                postProcessRevision: "compatibility-postprocess-v1",
                calibrationRevision: "compatibility-calibration-v1"
            )
        }
        cachedManifest = manifest
        return manifest
    }

    private func finalize(
        _ result: MangaPageAnalysis,
        request: InFlightRequest,
        key: String,
        diskURL: URL,
        manifest: MangaVisionModelManifest,
        identity: MangaPageIdentifier,
        analysisStart: ContinuousClock.Instant
    ) throws -> MangaPageAnalysis {
        guard request.generation == requestGeneration else {
            let totalMS = Self.milliseconds(analysisStart.duration(to: .now))
            lastAnalysisMilliseconds = totalMS
            lastDiagnostic = MangaVisionDiagnosticRecord(
                timestamp: Date(),
                outcome: .staleDiscarded,
                modelID: manifest.modelID,
                modelBuildID: manifest.modelBuildID,
                pageIndex: identity.pageIndex,
                reason: "request generation changed before commit",
                inferenceMilliseconds: nil,
                analysisTotalMilliseconds: totalMS,
                panelCount: result.panels.count,
                textCount: result.texts.count,
                balloonCount: result.balloons.count,
            onomatopoeiaCount: result.onomatopoeias.count
            )
            throw MangaVisionServiceError.staleResult
        }

        if let cached = memoryCache[key] {
            lastAnalysisMilliseconds = Self.milliseconds(analysisStart.duration(to: .now))
            return cached
        }

        guard let current = inFlight[key], current.id == request.id else {
            // A sibling waiter may already have finalized the same successful
            // inference. When the provider reports a different demand revision,
            // that result is intentionally not cached under this key; every
            // coalesced waiter should still receive the valid result.
            if let revision = result.cacheRevision,
               !key.hasPrefix(revision + "|") {
                return result
            }
            throw MangaVisionServiceError.staleResult
        }

        inFlight[key] = nil
        schedulePendingRuntimeReleaseIfIdle()
        let inferenceMS = Self.milliseconds(request.startedAt.duration(to: .now))
        inferenceCount += 1
        totalInferenceMilliseconds += inferenceMS
        lastInferenceMilliseconds = inferenceMS
        // The resource state can change while awaiting the provider. Never store
        // a reduced plan under the stronger demand requested before that await.
        if let revision = result.cacheRevision, key.hasPrefix(revision + "|") {
            insertIntoMemory(result, forKey: key)
            write(result, manifest: manifest, to: diskURL)
        }
        let totalMS = Self.milliseconds(analysisStart.duration(to: .now))
        lastAnalysisMilliseconds = totalMS
        lastDiagnostic = MangaVisionDiagnosticRecord(
            timestamp: Date(),
            outcome: .success,
            modelID: manifest.modelID,
            modelBuildID: manifest.modelBuildID,
            pageIndex: identity.pageIndex,
            reason: nil,
            inferenceMilliseconds: inferenceMS,
            analysisTotalMilliseconds: totalMS,
            panelCount: result.panels.count,
            textCount: result.texts.count,
            balloonCount: result.balloons.count,
        onomatopoeiaCount: result.onomatopoeias.count
        )
        let inferenceLabel = String(format: "%.1f", inferenceMS)
        MReaderLog.aiVision.debug(
            "MangaVision analyze model=\(manifest.modelID, privacy: .public) build=\(manifest.modelBuildID, privacy: .public) page=\(identity.pageIndex + 1, privacy: .public) panel=\(result.panels.count, privacy: .public) text=\(result.texts.count, privacy: .public) balloon=\(result.balloons.count, privacy: .public) sfx=\(result.onomatopoeias.count, privacy: .public) inferenceMs=\(inferenceLabel, privacy: .public)"
        )
        return result
    }

    private func handleFailure(
        _ error: Error,
        request: InFlightRequest,
        key: String,
        manifest: MangaVisionModelManifest,
        identity: MangaPageIdentifier,
        analysisStart: ContinuousClock.Instant
    ) {
        if inFlight[key]?.id == request.id {
            inFlight[key] = nil
            schedulePendingRuntimeReleaseIfIdle()
        }
        let outcome: MangaVisionDiagnosticOutcome = request.generation == requestGeneration
            ? .failure
            : .staleDiscarded
        recordFailure(
            error,
            manifest: manifest,
            identity: identity,
            analysisStart: analysisStart,
            outcome: outcome
        )
    }

    private func recordFailure(
        _ error: Error,
        manifest: MangaVisionModelManifest,
        identity: MangaPageIdentifier,
        analysisStart: ContinuousClock.Instant,
        outcome: MangaVisionDiagnosticOutcome
    ) {
        let totalMS = Self.milliseconds(analysisStart.duration(to: .now))
        lastAnalysisMilliseconds = totalMS
        let reason = MReaderLog.describe(error)
        lastDiagnostic = MangaVisionDiagnosticRecord(
            timestamp: Date(),
            outcome: outcome,
            modelID: manifest.modelID,
            modelBuildID: manifest.modelBuildID,
            pageIndex: identity.pageIndex,
            reason: reason,
            inferenceMilliseconds: nil,
            analysisTotalMilliseconds: totalMS,
            panelCount: 0,
            textCount: 0,
            balloonCount: 0,
        onomatopoeiaCount: 0
        )
        MReaderLog.aiVision.error(
            "MangaVision primary inference failed model=\(manifest.modelID, privacy: .public) build=\(manifest.modelBuildID, privacy: .public) page=\(identity.pageIndex + 1, privacy: .public) outcome=\(outcome.rawValue, privacy: .public) reason=\(reason, privacy: .public)"
        )
    }

    private func releaseConsumer(
        key: String,
        requestID: UUID,
        consumerID: UUID
    ) {
        guard var request = inFlight[key], request.id == requestID else { return }
        request.consumers.remove(consumerID)
        if request.consumers.isEmpty {
            request.task.cancel()
            inFlight[key] = nil
            schedulePendingRuntimeReleaseIfIdle()
        } else {
            inFlight[key] = request
        }
    }

    private func schedulePendingRuntimeReleaseIfIdle() {
        guard inFlight.isEmpty, let token = pendingRuntimeReleaseToken else { return }
        Task {
            await self.releaseRuntimeIfIdle(token: token)
        }
    }

    private func releaseRuntimeIfIdle(token: UUID) async {
        guard pendingRuntimeReleaseToken == token,
              activeReaderSessionID == nil,
              inFlight.isEmpty else { return }
        pendingRuntimeReleaseToken = nil
        if let releasable = provider as? any MangaVisionRuntimeReleasable {
            await releasable.releaseRuntimeMemory()
        }
    }

    private func advanceGenerationAndCancelInFlight() {
        pendingRuntimeReleaseToken = nil
        requestGeneration = requestGeneration.advanced()
        for request in inFlight.values {
            request.task.cancel()
        }
        inFlight.removeAll()
    }

    private func readValidCache(
        from url: URL,
        manifest: MangaVisionModelManifest,
        identity: MangaPageIdentifier
    ) -> MangaPageAnalysis? {
        guard let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(CacheEnvelope.self, from: data),
              envelope.manifestIdentity == manifest.cacheIdentity,
              envelope.analysis.schemaVersion == MangaPageAnalysis.schemaVersion,
              envelope.analysis.pageIdentifier == identity else {
            return nil
        }
        return envelope.analysis
    }

    private func write(
        _ analysis: MangaPageAnalysis,
        manifest: MangaVisionModelManifest,
        to url: URL
    ) {
        let envelope = CacheEnvelope(
            manifestIdentity: manifest.cacheIdentity,
            analysis: analysis
        )
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let oldBytes = Int64(
            (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        )
        do {
            try data.write(to: url, options: .atomic)
            estimatedDiskBytes = max(0, estimatedDiskBytes - oldBytes + Int64(data.count))
            writesSinceDiskReconciliation += 1
            reconcileDiskCacheIfNeeded()
        } catch {
            MReaderLog.aiVision.error(
                "MangaVision cache write failed path=\(url.lastPathComponent, privacy: .public) reason=\(MReaderLog.describe(error), privacy: .public)"
            )
        }
    }

    private func insertIntoMemory(_ analysis: MangaPageAnalysis, forKey key: String) {
        memoryCache[key] = analysis
        touchMemoryKey(key)
        while memoryOrder.count > memoryPageLimit {
            let removed = memoryOrder.removeFirst()
            memoryCache[removed] = nil
        }
    }

    private func touchMemoryKey(_ key: String) {
        memoryOrder.removeAll { $0 == key }
        memoryOrder.append(key)
    }

    private func cacheURL(modelKey: String, identity: MangaPageIdentifier) -> URL {
        cacheDirectory
            .appendingPathComponent(modelKey, isDirectory: true)
            .appendingPathComponent(identity.scope, isDirectory: true)
            .appendingPathComponent(String(format: "%04d", identity.pageIndex + 1))
            .appendingPathExtension("json")
    }

    private func reconcileDiskCacheIfNeeded() {
        let now = Date()
        let periodicReconciliationDue = writesSinceDiskReconciliation >= 32
            && now.timeIntervalSince(lastDiskReconciliationDate) >= 15 * 60
        guard estimatedDiskBytes > diskHighWaterBytes || periodicReconciliationDue else {
            return
        }
        reconcileAndPruneDiskCache()
    }

    private func reconcileAndPruneDiskCache() {
        let scan = Self.scanDiskCache(in: cacheDirectory, fileManager: fileManager)
        diskReconciliationCount += 1
        writesSinceDiskReconciliation = 0
        lastDiskReconciliationDate = Date()
        var totalBytes = scan.totalBytes
        if totalBytes > diskByteLimit {
            for entry in scan.entries.sorted(by: { $0.modifiedAt < $1.modifiedAt })
            where totalBytes > diskByteLimit {
                try? fileManager.removeItem(at: entry.url)
                totalBytes -= entry.bytes
            }
        }
        estimatedDiskBytes = max(totalBytes, 0)
    }

    nonisolated private static func diskUsageBytes(
        in directory: URL,
        fileManager: FileManager
    ) -> Int64 {
        scanDiskCache(in: directory, fileManager: fileManager).totalBytes
    }

    nonisolated private static func scanDiskCache(
        in directory: URL,
        fileManager: FileManager
    ) -> (totalBytes: Int64, entries: [DiskEntry]) {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return (0, []) }
        var entries: [DiskEntry] = []
        var totalBytes: Int64 = 0
        for case let url as URL in enumerator {
            guard url.pathExtension == "json",
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
                continue
            }
            let bytes = Int64(values.fileSize ?? 0)
            totalBytes += bytes
            entries.append(DiskEntry(
                url: url,
                bytes: bytes,
                modifiedAt: values.contentModificationDate ?? .distantPast
            ))
        }
        return (totalBytes, entries)
    }

    nonisolated private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    nonisolated private static func analysisCGImage(
        from image: UIImage,
        maximumDimension: Int
    ) -> CGImage? {
        guard let source = image.cgImage else { return nil }
        let maximum = max(source.width, source.height)
        guard maximum > maximumDimension else { return source }
        let scale = CGFloat(maximumDimension) / CGFloat(max(maximum, 1))
        let width = max(Int((CGFloat(source.width) * scale).rounded()), 1)
        let height = max(Int((CGFloat(source.height) * scale).rounded()), 1)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return source }
        context.interpolationQuality = .medium
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? source
    }

    private static func loadAnalysisImage(
        from url: URL,
        maximumDimension: Int
    ) async -> UIImage? {
        if RemotePageLoader.isRemotePageURL(url) {
            guard let data = await RemotePageLoader.imageData(forRemotePageURL: url) else { return nil }
            return thumbnail(data: data, maximumDimension: maximumDimension)
        }
        if ComicManager.isArchivePageURL(url) {
            guard let data = ComicManager.imageData(forArchivePageURL: url) else { return nil }
            return thumbnail(data: data, maximumDimension: maximumDimension)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return thumbnail(source: source, maximumDimension: maximumDimension)
    }

    nonisolated private static func thumbnail(data: Data, maximumDimension: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return UIImage(data: data) }
        return thumbnail(source: source, maximumDimension: maximumDimension)
    }

    nonisolated private static func thumbnail(source: CGImageSource, maximumDimension: Int) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    nonisolated private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}

