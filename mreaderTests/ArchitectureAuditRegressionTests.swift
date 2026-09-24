import Foundation
import Testing
import UIKit
@testable import mreader

@MainActor
struct ArchitectureAuditRegressionTests {
    @Test func geometryOrderIsIndependentOfInputPermutation() {
        let values = [CGRect(x: 0.75, y: 0.23, width: 0.1, height: 0.1),
                      CGRect(x: 0.45, y: 0.19, width: 0.1, height: 0.1),
                      CGRect(x: 0.15, y: 0.15, width: 0.1, height: 0.1)]
        func ordered(_ rects: [CGRect]) -> [CGRect] {
            MangaReadingGeometry.ordered(rects, isRightToLeft: true,
                rect: { $0 }, identity: { String(describing: $0) })
        }
        let expected = ordered(values)
        for permutation in [[values[2], values[1], values[0]], [values[1], values[0], values[2]],
                            [values[0], values[2], values[1]], [values[1], values[2], values[0]],
                            [values[2], values[0], values[1]]] {
            #expect(ordered(permutation) == expected)
        }
    }

    @Test func coldOCRSnapshotPreservesResolvedDecisions() throws {
        let block = TextBlock(text: "テスト", boundingBox: CGRect(x: 0.2, y: 0.1, width: 0.1, height: 0.3),
            confidence: 0.93, ocrSource: "visionkit:ja", isFiltered: true, filterReason: "fixture",
            bubbleBox: CGRect(x: 0.1, y: 0.05, width: 0.4, height: 0.5),
            polygon: [CGPoint(x: 0.2, y: 0.1)], bubblePolygon: [CGPoint(x: 0.1, y: 0.05)],
            textOrientation: .vertical, sourceLineCount: 3)
        let result = OCRPipelineResult(rawBlocks: [block], resolvedBlocks: [block], lineBlocks: [block],
            bubbleBlocks: [block], rejectedBlocks: [block], detectedLanguage: "ja")
        let original = CachedOCRPage(createdAt: Date(timeIntervalSince1970: 1), result: result)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let bytes = try encoder.encode(original)
        let restored = try JSONDecoder().decode(CachedOCRPage.self, from: bytes)
        #expect(try encoder.encode(restored) == bytes)
        #expect(restored.result.bubbleBlocks.first?.sourceLineCount == 3)
        #expect(restored.result.detectedLanguage == "ja")
    }

    @Test func singleConfidentModelPanelIsUsable() {
        let panel = DetectedPanel(rect: CGRect(x: 0, y: 0, width: 1, height: 1), confidence: 0.9, source: .coreML)
        #expect(PanelLayoutQuality.isUsable(PanelPostProcessor.process([panel])))
        #expect(!PanelLayoutQuality.isUsable([DetectedPanel(rect: panel.rect, confidence: 0.2, source: .coreML)]))
        #expect(!PanelLayoutQuality.isUsable([DetectedPanel(rect: panel.rect, confidence: 0.9, source: .visionRectangle)]))
    }

    @Test func reducedPrefetchDemandCannotAliasForeground() {
        let size = CGSize(width: 1200, height: 3600), input = CGSize(width: 640, height: 640)
        let reduced = MangaVisionInferencePlanner.cacheDemandIdentity(sourceSize: size, inputSize: input,
            requestClass: .prefetch, resourceState: MangaVisionResourceState(lowPowerModeEnabled: true, thermalLevel: .nominal))
        let full = MangaVisionInferencePlanner.cacheDemandIdentity(sourceSize: size, inputSize: input,
            requestClass: .interactive, resourceState: MangaVisionResourceState(lowPowerModeEnabled: false, thermalLevel: .nominal))
        #expect(reduced != full)
    }

    @Test func impossibleTranslationLayoutReportsOverflow() {
        for orientation in [TextOrientation.horizontal, .vertical] {
            let layout = OCRBubbleLayoutEngine.anchoredTranslationLayout(
                text: String(repeating: "長い翻訳です", count: 500), sourceFontSize: 20,
                sourceRect: CGRect(x: 0, y: 0, width: 1, height: 1),
                allowedBounds: CGRect(x: 0, y: 0, width: 1, height: 1), lineSpacing: 2,
                textOrientation: orientation, geometryStrategy: .measuredText, minimumReadableFontSize: 12)
            #expect(layout.status == .needsExpansion)
        }
    }

    @Test func clearingWorkPoolDiscardsUncooperativeOldCompletion() async throws {
        let pool = SharedPageTaskPool<Int>()
        let gate = AuditGate()
        let old = Task { try await pool.value(forKey: "page") { await gate.wait(); return 1 } }
        await gate.waitUntilStarted()
        await pool.cancelAll()
        let replacement = try await pool.value(forKey: "page") { 2 }
        await gate.open()
        #expect(replacement == 2)
        do { _ = try await old.value; Issue.record("Old generation was accepted") }
        catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
        #expect(try await pool.value(forKey: "page") { 3 } == 3)
    }

    @Test func cancelledReaderPermitWaiterDoesNotConsumeCapacity() async {
        let pool = ReaderAsyncPermitPool(maximumConcurrentPermits: 1)
        let firstPermit = await pool.acquire()
        #expect(firstPermit)

        let blocked = Task { await pool.acquire() }
        await Task.yield()
        blocked.cancel()
        let cancelledResult = await blocked.value
        #expect(cancelledResult == false)

        await pool.release()
        let replacementPermit = await pool.acquire()
        #expect(replacementPermit)
        await pool.release()
    }

    @Test func staleReaderSessionCannotClearNewAppleTranslationCache() async {
        let cache = AppleTranslationPageCache()
        let oldSession = UUID()
        let newSession = UUID()
        let block = TextBlock(
            text: "原文",
            boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.2),
            translation: "translation"
        )

        ReaderSessionRegistry.shared.activate(oldSession)
        await cache.beginReaderSession(sessionID: oldSession)
        await cache.store([block], key: "page")
        ReaderSessionRegistry.shared.activate(newSession)
        await cache.beginReaderSession(sessionID: newSession)
        await cache.releaseReaderSessionMemory(sessionID: oldSession)
        let survivesStaleRelease = await cache.cachedBlocks(key: "page")
        #expect(survivesStaleRelease?.count == 1)

        await cache.releaseReaderSessionMemory(sessionID: newSession)
        let clearedByOwner = await cache.cachedBlocks(key: "page")
        #expect(clearedByOwner == nil)
        ReaderSessionRegistry.shared.deactivate(newSession)
    }
}

private actor AuditGate {
    var continuation: CheckedContinuation<Void, Never>?
    var started: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            for waiter in started { waiter.resume() }
            started.removeAll()
        }
    }
    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { started.append($0) }
    }
    func open() { continuation?.resume(); continuation = nil }
}
