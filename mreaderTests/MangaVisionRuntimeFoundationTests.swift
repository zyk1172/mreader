import Foundation
import Testing
import UIKit
@testable import mreader

@Suite(.serialized)
@MainActor
struct MangaVisionRuntimeFoundationTests {
    @Test func diskCacheHitDoesNotTouchRuntimeDescriptorOrInference() async throws {
        let directory = temporaryCacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = makeManifest(build: "build-a")
        let pageURL = URL(fileURLWithPath: "/tmp/mreader-runtime-disk-hit.png")
        let identity = PageContentIdentity.remote(
            provider: "fixture",
            resource: "book/page-1",
            revision: "r1"
        )

        let writerProvider = RuntimeFoundationFakeProvider(manifest: manifest)
        let writer = MangaVisionService(provider: writerProvider, cacheDirectory: directory)
        _ = try await writer.analysis(
            comicID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            pageIndex: 0,
            pageURL: pageURL,
            image: makeImage(),
            contentIdentity: identity
        )
        #expect(await writerProvider.inferenceCalls() == 1)

        let cacheHitProvider = RuntimeFoundationFakeProvider(manifest: manifest)
        let reader = MangaVisionService(provider: cacheHitProvider, cacheDirectory: directory)
        _ = try await reader.analysis(
            comicID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            pageIndex: 0,
            pageURL: pageURL,
            image: makeImage(),
            contentIdentity: identity
        )

        #expect(await cacheHitProvider.descriptorCalls() == 0)
        #expect(await cacheHitProvider.inferenceCalls() == 0)
        #expect((await reader.performanceSnapshot()).diskCacheHitCount == 1)
    }

    @Test func expectedDependencyIdentityDoesNotStartInference() async {
        let directory = temporaryCacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = makeManifest(build: "dependency-identity")
        let provider = RuntimeFoundationFakeProvider(manifest: manifest)
        let service = MangaVisionService(provider: provider, cacheDirectory: directory)

        let identity = await service.expectedDependencyIdentity(image: makeImage())

        #expect(identity == manifest.cacheIdentity + "|single-pass")
        #expect(await provider.descriptorCalls() == 0)
        #expect(await provider.inferenceCalls() == 0)
    }

    @Test func cacheMissPerformsExactlyOneInferenceWithoutDescriptorColdLoad() async throws {
        let directory = temporaryCacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = RuntimeFoundationFakeProvider(manifest: makeManifest(build: "miss"))
        let service = MangaVisionService(provider: provider, cacheDirectory: directory)

        _ = try await service.analysis(
            comicID: UUID(),
            pageIndex: 0,
            pageURL: URL(fileURLWithPath: "/tmp/mreader-runtime-miss.png"),
            image: makeImage(),
            contentIdentity: .remote(provider: "fixture", resource: "miss", revision: "1")
        )

        #expect(await provider.descriptorCalls() == 0)
        #expect(await provider.inferenceCalls() == 1)
    }

    @Test func concurrentSamePageRequestsCoalesceIntoSingleInference() async throws {
        let directory = temporaryCacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = RuntimeFoundationFakeProvider(
            manifest: makeManifest(build: "coalesce"),
            delayMilliseconds: 80
        )
        let service = MangaVisionService(provider: provider, cacheDirectory: directory)
        let comicID = UUID()
        let url = URL(fileURLWithPath: "/tmp/mreader-runtime-coalesce.png")
        let identity = PageContentIdentity.remote(
            provider: "fixture",
            resource: "coalesce",
            revision: "1"
        )
        let image = makeImage()

        async let first = service.analysis(
            comicID: comicID,
            pageIndex: 0,
            pageURL: url,
            image: image,
            contentIdentity: identity
        )
        async let second = service.analysis(
            comicID: comicID,
            pageIndex: 0,
            pageURL: url,
            image: image,
            contentIdentity: identity
        )
        _ = try await (first, second)

        #expect(await provider.inferenceCalls() == 1)
    }

    @Test func cancellingOneCoalescedConsumerDoesNotCancelSibling() async throws {
        let directory = temporaryCacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = RuntimeFoundationFakeProvider(
            manifest: makeManifest(build: "consumer-cancel"),
            delayMilliseconds: 120
        )
        let service = MangaVisionService(provider: provider, cacheDirectory: directory)
        let comicID = UUID()
        let url = URL(fileURLWithPath: "/tmp/mreader-runtime-consumer-cancel.png")
        let identity = PageContentIdentity.remote(
            provider: "fixture",
            resource: "consumer-cancel",
            revision: "1"
        )
        let image = makeImage()

        let first = Task {
            try await service.analysis(
                comicID: comicID,
                pageIndex: 0,
                pageURL: url,
                image: image,
                contentIdentity: identity
            )
        }
        try await Task.sleep(nanoseconds: 15_000_000)
        let second = Task {
            try await service.analysis(
                comicID: comicID,
                pageIndex: 0,
                pageURL: url,
                image: image,
                contentIdentity: identity
            )
        }
        try await Task.sleep(nanoseconds: 15_000_000)

        first.cancel()
        do {
            _ = try await first.value
            Issue.record("cancelled consumer unexpectedly returned a result")
        } catch {
            #expect(error is CancellationError)
        }

        let siblingResult = try await second.value
        #expect(!siblingResult.panels.isEmpty)
        #expect(await provider.inferenceCalls() == 1)
    }

    @Test func readerSessionReleaseWaitsForSharedInferenceThenUnloadsRuntime() async throws {
        let directory = temporaryCacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = RuntimeFoundationFakeProvider(
            manifest: makeManifest(build: "deferred-runtime-release"),
            delayMilliseconds: 80
        )
        let service = MangaVisionService(provider: provider, cacheDirectory: directory)
        let request = Task {
            try await service.analysis(
                comicID: UUID(),
                pageIndex: 0,
                pageURL: URL(fileURLWithPath: "/tmp/mreader-runtime-deferred-release.png"),
                image: makeImage(),
                contentIdentity: .remote(
                    provider: "fixture",
                    resource: "deferred-release",
                    revision: "1"
                )
            )
        }

        try await Task.sleep(nanoseconds: 15_000_000)
        await service.releaseReaderSessionMemory()
        #expect(await provider.runtimeReleaseCalls() == 0)

        _ = try await request.value
        for _ in 0..<20 where await provider.runtimeReleaseCalls() == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(await provider.runtimeReleaseCalls() == 1)
    }

    @Test func modelBuildChangeInvalidatesCacheWithoutManualVersionBump() async throws {
        let directory = temporaryCacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let comicID = UUID()
        let url = URL(fileURLWithPath: "/tmp/mreader-runtime-build-change.png")
        let identity = PageContentIdentity.remote(
            provider: "fixture",
            resource: "build-change",
            revision: "1"
        )

        let firstProvider = RuntimeFoundationFakeProvider(manifest: makeManifest(build: "weights-a"))
        let first = MangaVisionService(provider: firstProvider, cacheDirectory: directory)
        _ = try await first.analysis(
            comicID: comicID,
            pageIndex: 2,
            pageURL: url,
            image: makeImage(),
            contentIdentity: identity
        )

        let secondProvider = RuntimeFoundationFakeProvider(manifest: makeManifest(build: "weights-b"))
        let second = MangaVisionService(provider: secondProvider, cacheDirectory: directory)
        _ = try await second.analysis(
            comicID: comicID,
            pageIndex: 2,
            pageURL: url,
            image: makeImage(),
            contentIdentity: identity
        )

        #expect(await secondProvider.inferenceCalls() == 1)
    }

    @Test func analysisRevisionChangeInvalidatesCache() async throws {
        let directory = temporaryCacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let comicID = UUID()
        let url = URL(fileURLWithPath: "/tmp/mreader-runtime-analysis-change.png")
        let identity = PageContentIdentity.remote(
            provider: "fixture",
            resource: "analysis-change",
            revision: "1"
        )

        let firstProvider = RuntimeFoundationFakeProvider(
            manifest: makeManifest(build: "same", analysisRevision: "analysis-a")
        )
        let first = MangaVisionService(provider: firstProvider, cacheDirectory: directory)
        _ = try await first.analysis(
            comicID: comicID,
            pageIndex: 1,
            pageURL: url,
            image: makeImage(),
            contentIdentity: identity
        )

        let secondProvider = RuntimeFoundationFakeProvider(
            manifest: makeManifest(build: "same", analysisRevision: "analysis-b")
        )
        let second = MangaVisionService(provider: secondProvider, cacheDirectory: directory)
        _ = try await second.analysis(
            comicID: comicID,
            pageIndex: 1,
            pageURL: url,
            image: makeImage(),
            contentIdentity: identity
        )

        #expect(await secondProvider.inferenceCalls() == 1)
    }

    @Test func sourceRevisionChangeInvalidatesPageAnalysis() async throws {
        let directory = temporaryCacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = RuntimeFoundationFakeProvider(manifest: makeManifest(build: "source"))
        let service = MangaVisionService(provider: provider, cacheDirectory: directory)
        let comicID = UUID()
        let url = URL(string: "https://example.invalid/book/page")!

        _ = try await service.analysis(
            comicID: comicID,
            pageIndex: 0,
            pageURL: url,
            image: makeImage(),
            contentIdentity: .remote(provider: "opds", resource: "book/page", revision: "etag-a")
        )
        _ = try await service.analysis(
            comicID: comicID,
            pageIndex: 0,
            pageURL: url,
            image: makeImage(),
            contentIdentity: .remote(provider: "opds", resource: "book/page", revision: "etag-b")
        )

        #expect(await provider.inferenceCalls() == 2)
    }

    @Test func generationChangeDuringInferenceDiscardsNaturalCompletion() async throws {
        let directory = temporaryCacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = RuntimeFoundationFakeProvider(
            manifest: makeManifest(build: "generation"),
            delayMilliseconds: 120,
            ignoresCancellation: true
        )
        let service = MangaVisionService(provider: provider, cacheDirectory: directory)
        let url = URL(fileURLWithPath: "/tmp/mreader-runtime-generation.png")
        let identity = PageContentIdentity.remote(
            provider: "fixture",
            resource: "generation",
            revision: "1"
        )
        let comicID = UUID()

        let oldRequest = Task {
            try await service.analysis(
                comicID: comicID,
                pageIndex: 0,
                pageURL: url,
                image: makeImage(),
                contentIdentity: identity
            )
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        let oldGeneration = await service.currentGenerationForDiagnostics()
        await service.invalidateInFlightAnalyses()
        let newGeneration = await service.currentGenerationForDiagnostics()
        #expect(newGeneration.rawValue == oldGeneration.rawValue + 1)

        do {
            _ = try await oldRequest.value
            Issue.record("stale request unexpectedly returned a result")
        } catch {
            #expect(error is MangaVisionServiceError || error is CancellationError)
        }
        #expect((await service.lastDiagnosticSnapshot())?.outcome == .staleDiscarded)
    }

    @Test func clearCacheDuringInferenceCannotBeRepopulatedByOldTask() async throws {
        let directory = temporaryCacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = RuntimeFoundationFakeProvider(
            manifest: makeManifest(build: "clear"),
            delayMilliseconds: 120,
            ignoresCancellation: true
        )
        let service = MangaVisionService(provider: provider, cacheDirectory: directory)
        let url = URL(fileURLWithPath: "/tmp/mreader-runtime-clear.png")
        let identity = PageContentIdentity.remote(
            provider: "fixture",
            resource: "clear",
            revision: "1"
        )
        let comicID = UUID()

        let oldRequest = Task {
            try await service.analysis(
                comicID: comicID,
                pageIndex: 0,
                pageURL: url,
                image: makeImage(),
                contentIdentity: identity
            )
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        await service.clearCache()
        _ = try? await oldRequest.value

        let cached = await service.cachedAnalysis(
            comicID: comicID,
            pageIndex: 0,
            pageURL: url,
            image: makeImage(),
            contentIdentity: identity
        )
        #expect(cached == nil)

        _ = try await service.analysis(
            comicID: comicID,
            pageIndex: 0,
            pageURL: url,
            image: makeImage(),
            contentIdentity: identity
        )
        #expect(await provider.inferenceCalls() == 2)
    }

    @Test func smallWritesDoNotRescanWholeDiskCacheEveryTime() async throws {
        let directory = temporaryCacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = RuntimeFoundationFakeProvider(manifest: makeManifest(build: "prune"))
        let service = MangaVisionService(provider: provider, cacheDirectory: directory)
        let initialScans = await service.diskReconciliationCountForDiagnostics()
        let comicID = UUID()

        for page in 0..<6 {
            _ = try await service.analysis(
                comicID: comicID,
                pageIndex: page,
                pageURL: URL(fileURLWithPath: "/tmp/mreader-runtime-prune-\(page).png"),
                image: makeImage(),
                contentIdentity: .remote(
                    provider: "fixture",
                    resource: "prune/\(page)",
                    revision: "1"
                )
            )
        }

        #expect(await service.diskReconciliationCountForDiagnostics() == initialScans)
    }

    @Test func modelFailureProducesStructuredDiagnostic() async throws {
        let directory = temporaryCacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = RuntimeFoundationFakeProvider(
            manifest: makeManifest(build: "failure"),
            error: RuntimeFoundationFakeError.inferenceFailed
        )
        let service = MangaVisionService(provider: provider, cacheDirectory: directory)

        do {
            _ = try await service.analysis(
                comicID: UUID(),
                pageIndex: 4,
                pageURL: URL(fileURLWithPath: "/tmp/mreader-runtime-failure.png"),
                image: makeImage(),
                contentIdentity: .remote(provider: "fixture", resource: "failure", revision: "1")
            )
            Issue.record("expected provider failure")
        } catch {
            #expect(error is RuntimeFoundationFakeError)
        }

        let diagnostic = await service.lastDiagnosticSnapshot()
        #expect(diagnostic?.outcome == .failure)
        #expect(diagnostic?.pageIndex == 4)
        #expect(diagnostic?.reason?.contains("inferenceFailed") == true)
    }

    @Test func modelArtifactHashChangesWhenModelBytesChange() throws {
        let directory = temporaryCacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let modelDirectory = directory.appendingPathComponent("SyntheticModel.mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        let weights = modelDirectory.appendingPathComponent("weights.bin")
        try Data([1, 2, 3, 4]).write(to: weights)
        let first = MangaVisionModelManifest.hashModelDirectoryForDiagnostics(modelDirectory)
        try Data([1, 2, 3, 5]).write(to: weights)
        let second = MangaVisionModelManifest.hashModelDirectoryForDiagnostics(modelDirectory)

        #expect(first != nil)
        #expect(second != nil)
        #expect(first != second)
    }

    private func makeManifest(
        build: String,
        analysisRevision: String = "analysis-v1"
    ) -> MangaVisionModelManifest {
        MangaVisionModelManifest(
            modelID: "fake-manga-vision",
            modelBuildID: build,
            modelFileHash: "hash-\(build)",
            inputSize: CGSize(width: 64, height: 64),
            semanticClasses: [.panel, .text, .balloon],
            outputContractRevision: "contract-v1",
            analysisSchemaRevision: analysisRevision,
            postProcessRevision: "post-v1",
            calibrationRevision: "calibration-v1"
        )
    }

    private func makeImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 64, height: 96)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 96))
        }
    }

    private func temporaryCacheDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MangaVisionRuntimeTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private enum RuntimeFoundationFakeError: Error {
    case inferenceFailed
}

private actor RuntimeFoundationFakeProvider: MangaVisionProvider, MangaVisionManifestProviding, MangaVisionRuntimeReleasable {
    private let manifest: MangaVisionModelManifest
    private let delayMilliseconds: UInt64
    private let ignoresCancellation: Bool
    private let error: Error?
    private var descriptorCallCount = 0
    private var inferenceCallCount = 0
    private var runtimeReleaseCallCount = 0

    init(
        manifest: MangaVisionModelManifest,
        delayMilliseconds: UInt64 = 0,
        ignoresCancellation: Bool = false,
        error: Error? = nil
    ) {
        self.manifest = manifest
        self.delayMilliseconds = delayMilliseconds
        self.ignoresCancellation = ignoresCancellation
        self.error = error
    }

    var descriptor: MangaVisionProviderDescriptor {
        get async {
            descriptorCallCount += 1
            return manifest.compatibilityDescriptor
        }
    }

    func mangaVisionManifest() async -> MangaVisionModelManifest {
        manifest
    }

    func releaseRuntimeMemory() async {
        runtimeReleaseCallCount += 1
    }

    func runtimeReleaseCalls() -> Int {
        runtimeReleaseCallCount
    }

    func analyzePage(
        image: CGImage,
        sourceImageSize: CGSize,
        pageIdentifier: MangaPageIdentifier
    ) async throws -> MangaPageAnalysis {
        _ = image
        inferenceCallCount += 1
        if delayMilliseconds > 0 {
            if ignoresCancellation {
                try? await Task.sleep(nanoseconds: delayMilliseconds * 1_000_000)
            } else {
                try await Task.sleep(nanoseconds: delayMilliseconds * 1_000_000)
            }
        }
        if let error { throw error }
        return MangaPageAnalysis(
            pageIdentifier: pageIdentifier,
            imageSize: sourceImageSize,
            panels: [
                MangaVisionRegion(
                    type: .panel,
                    normalizedRect: CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9),
                    confidence: 0.9
                )
            ],
            texts: [],
            balloons: [],
            faces: [],
            bodies: [],
            modelIdentifier: manifest.modelID,
            modelVersion: 4
        )
    }

    func descriptorCalls() -> Int { descriptorCallCount }
    func inferenceCalls() -> Int { inferenceCallCount }
}
