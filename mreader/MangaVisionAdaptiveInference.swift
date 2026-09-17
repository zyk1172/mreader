import CoreGraphics
import Foundation

nonisolated enum MangaVisionRequestClass: String, Sendable, Equatable {
    case interactive
    case prefetch

    static var currentTask: MangaVisionRequestClass {
        let priority = Task.currentPriority
        if priority == .background || priority == .utility || priority == .low {
            return .prefetch
        }
        return .interactive
    }
}

nonisolated enum MangaVisionThermalLevel: Int, Sendable, Comparable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    static func < (lhs: MangaVisionThermalLevel, rhs: MangaVisionThermalLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

nonisolated struct MangaVisionResourceState: Sendable, Equatable {
    let lowPowerModeEnabled: Bool
    let thermalLevel: MangaVisionThermalLevel

    static var current: MangaVisionResourceState {
        let processInfo = ProcessInfo.processInfo
        let thermalLevel: MangaVisionThermalLevel
        switch processInfo.thermalState {
        case .nominal:
            thermalLevel = .nominal
        case .fair:
            thermalLevel = .fair
        case .serious:
            thermalLevel = .serious
        case .critical:
            thermalLevel = .critical
        @unknown default:
            thermalLevel = .serious
        }
        return MangaVisionResourceState(
            lowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
            thermalLevel: thermalLevel
        )
    }
}

nonisolated struct MangaVisionInferenceTile: Sendable, Equatable {
    let sourceRect: CGRect
    let ownershipRect: CGRect
}

nonisolated struct MangaVisionInferencePlan: Sendable, Equatable {
    let allowsInference: Bool
    let requestClass: MangaVisionRequestClass
    let sourceAspectRatio: CGFloat
    let refinementTiles: [MangaVisionInferenceTile]
    let reason: String
}

nonisolated enum MangaVisionInferencePlanner {
    static let revision = "adaptive-full-plus-overlap-tiles-v1"
    private static let refinementAspectThreshold: CGFloat = 1.65
    private static let forcedRefinementAspectThreshold: CGFloat = 1.90
    private static let tileOverlapFraction: CGFloat = 0.18
    private static let nominalMaximumTileCount = 6

    /// One full-page baseline plus the bounded refinement tiles.
    /// Regression/performance gates must use this contract instead of duplicating a limit.
    static var maximumInferencePassCount: Int {
        1 + nominalMaximumTileCount
    }

    static func plan(
        sourceSize: CGSize,
        inputSize: CGSize,
        requestClass: MangaVisionRequestClass,
        resourceState: MangaVisionResourceState
    ) -> MangaVisionInferencePlan {
        guard sourceSize.width > 0,
              sourceSize.height > 0,
              inputSize.width > 0,
              inputSize.height > 0 else {
            return MangaVisionInferencePlan(
                allowsInference: true,
                requestClass: requestClass,
                sourceAspectRatio: 1,
                refinementTiles: [],
                reason: "invalid-geometry-full-pass-only"
            )
        }

        let longSide = max(sourceSize.width, sourceSize.height)
        let shortSide = max(min(sourceSize.width, sourceSize.height), 1)
        let aspectRatio = longSide / shortSide

        if requestClass == .prefetch, resourceState.thermalLevel >= .serious {
            return MangaVisionInferencePlan(
                allowsInference: false,
                requestClass: requestClass,
                sourceAspectRatio: aspectRatio,
                refinementTiles: [],
                reason: "background-deferred-thermal"
            )
        }

        var maximumTileCount = nominalMaximumTileCount
        if resourceState.thermalLevel >= .serious {
            maximumTileCount = 0
        } else if resourceState.thermalLevel == .fair {
            maximumTileCount = 4
        }
        if requestClass == .prefetch, resourceState.lowPowerModeEnabled {
            maximumTileCount = 0
        }

        let tiles: [MangaVisionInferenceTile]
        if maximumTileCount >= 2, aspectRatio >= refinementAspectThreshold {
            tiles = makeLongAxisTiles(
                sourceSize: sourceSize,
                aspectRatio: aspectRatio,
                maximumTileCount: maximumTileCount,
                overlapFraction: tileOverlapFraction
            )
        } else {
            tiles = []
        }

        let reason: String
        if tiles.isEmpty {
            if resourceState.thermalLevel >= .serious {
                reason = "thermal-full-pass-only"
            } else if requestClass == .prefetch, resourceState.lowPowerModeEnabled {
                reason = "low-power-background-full-pass-only"
            } else {
                reason = "standard-page-full-pass-only"
            }
        } else {
            reason = "long-page-full-pass-plus-tiles"
        }

        return MangaVisionInferencePlan(
            allowsInference: true,
            requestClass: requestClass,
            sourceAspectRatio: aspectRatio,
            refinementTiles: tiles,
            reason: reason
        )
    }

    static func shouldRefine(
        baseline: MangaPageAnalysis,
        plan: MangaVisionInferencePlan
    ) -> Bool {
        guard plan.allowsInference, !plan.refinementTiles.isEmpty else { return false }
        if plan.sourceAspectRatio >= forcedRefinementAspectThreshold { return true }
        if baseline.panels.count <= 2 { return true }
        guard !baseline.panels.isEmpty else { return true }
        let averagePanelConfidence = baseline.panels.reduce(0.0) {
            $0 + Double($1.confidence)
        } / Double(baseline.panels.count)
        return averagePanelConfidence < 0.55
    }

    static func prefetchMaximumSourceDimension(
        inputSize: CGSize,
        resourceState: MangaVisionResourceState
    ) -> Int? {
        if resourceState.thermalLevel >= .serious { return nil }
        let inputMaximum = max(Int(max(inputSize.width, inputSize.height).rounded()), 1)
        if resourceState.lowPowerModeEnabled { return inputMaximum }
        if resourceState.thermalLevel == .fair {
            return min(inputMaximum * 3, 2_048)
        }
        return min(inputMaximum * 4, 2_560)
    }

    static func prefetchPageLimit(resourceState: MangaVisionResourceState) -> Int {
        if resourceState.thermalLevel >= .serious { return 0 }
        if resourceState.lowPowerModeEnabled { return 1 }
        if resourceState.thermalLevel == .fair { return 2 }
        return 3
    }

    private static func makeLongAxisTiles(
        sourceSize: CGSize,
        aspectRatio: CGFloat,
        maximumTileCount: Int,
        overlapFraction: CGFloat
    ) -> [MangaVisionInferenceTile] {
        let requestedCount = max(2, Int(ceil(aspectRatio / 1.25)))
        let count = min(maximumTileCount, requestedCount)
        guard count >= 2 else { return [] }

        let overlap = min(max(overlapFraction, 0), 0.45)
        let tileLength = 1 / (1 + CGFloat(count - 1) * (1 - overlap))
        let step = tileLength * (1 - overlap)
        let isVertical = sourceSize.height >= sourceSize.width

        let sourceRects: [CGRect] = (0..<count).map { index in
            let origin = min(CGFloat(index) * step, 1 - tileLength)
            if isVertical {
                return CGRect(x: 0, y: origin, width: 1, height: tileLength)
            }
            return CGRect(x: origin, y: 0, width: tileLength, height: 1)
        }

        return sourceRects.enumerated().map { index, rect in
            if isVertical {
                let lower = index == 0
                    ? 0
                    : (sourceRects[index - 1].maxY + rect.minY) / 2
                let upper = index == sourceRects.count - 1
                    ? 1
                    : (rect.maxY + sourceRects[index + 1].minY) / 2
                return MangaVisionInferenceTile(
                    sourceRect: rect,
                    ownershipRect: CGRect(x: 0, y: lower, width: 1, height: max(upper - lower, 0))
                )
            }
            let lower = index == 0
                ? 0
                : (sourceRects[index - 1].maxX + rect.minX) / 2
            let upper = index == sourceRects.count - 1
                ? 1
                : (rect.maxX + sourceRects[index + 1].minX) / 2
            return MangaVisionInferenceTile(
                sourceRect: rect,
                ownershipRect: CGRect(x: lower, y: 0, width: max(upper - lower, 0), height: 1)
            )
        }
    }
}

nonisolated protocol MangaVisionSourceImageAnalyzing: Sendable {
    func analyzeSourceImage(
        image: CGImage,
        sourceImageSize: CGSize,
        pageIdentifier: MangaPageIdentifier,
        requestClass: MangaVisionRequestClass
    ) async throws -> MangaPageAnalysis
}

nonisolated protocol MangaVisionInferencePassDiagnosticsProviding: Sendable {
    func totalInferencePassCountForDiagnostics() async -> Int
}

nonisolated enum MangaVisionAdaptiveInferenceError: Error, Sendable, Equatable {
    case backgroundDeferred
}

actor MangaVisionInferenceScheduler {
    nonisolated struct Snapshot: Sendable, Equatable {
        let isRunning: Bool
        let interactiveWaiterCount: Int
        let prefetchWaiterCount: Int
    }

    private var isRunning = false
    private var interactiveWaiters: [CheckedContinuation<Void, Never>] = []
    private var prefetchWaiters: [CheckedContinuation<Void, Never>] = []

    func acquire(for requestClass: MangaVisionRequestClass) async {
        if !isRunning {
            isRunning = true
            return
        }
        await withCheckedContinuation { continuation in
            switch requestClass {
            case .interactive:
                interactiveWaiters.append(continuation)
            case .prefetch:
                prefetchWaiters.append(continuation)
            }
        }
    }

    func release() {
        if !interactiveWaiters.isEmpty {
            interactiveWaiters.removeFirst().resume()
            return
        }
        if !prefetchWaiters.isEmpty {
            prefetchWaiters.removeFirst().resume()
            return
        }
        isRunning = false
    }

    func snapshotForDiagnostics() -> Snapshot {
        Snapshot(
            isRunning: isRunning,
            interactiveWaiterCount: interactiveWaiters.count,
            prefetchWaiterCount: prefetchWaiters.count
        )
    }
}

actor AdaptiveMangaVisionProvider: MangaVisionProvider, MangaVisionManifestProviding, MangaVisionSourceImageAnalyzing, MangaVisionInferencePassDiagnosticsProviding {
    private let base: any MangaVisionProvider
    private let scheduler: MangaVisionInferenceScheduler
    private let resourceStateOverride: MangaVisionResourceState?
    private var totalInferencePassCount = 0

    init(
        base: any MangaVisionProvider,
        scheduler: MangaVisionInferenceScheduler = MangaVisionInferenceScheduler(),
        resourceStateOverride: MangaVisionResourceState? = nil
    ) {
        self.base = base
        self.scheduler = scheduler
        self.resourceStateOverride = resourceStateOverride
    }

    var descriptor: MangaVisionProviderDescriptor {
        get async {
            await mangaVisionManifest().compatibilityDescriptor
        }
    }

    func mangaVisionManifest() async -> MangaVisionModelManifest {
        let manifest: MangaVisionModelManifest
        if let manifestProvider = base as? any MangaVisionManifestProviding {
            manifest = await manifestProvider.mangaVisionManifest()
        } else {
            let descriptor = await base.descriptor
            let compatibilityBuild = "adaptive-descriptor:\(descriptor.modelIdentifier):\(descriptor.modelVersion)"
            manifest = MangaVisionModelManifest(
                modelID: descriptor.modelIdentifier,
                modelBuildID: compatibilityBuild,
                modelFileHash: compatibilityBuild,
                inputSize: descriptor.inputSize,
                semanticClasses: descriptor.supportedRegionTypes,
                outputContractRevision: "compatibility-output-v1",
                analysisSchemaRevision: "manga-page-analysis-v\(MangaPageAnalysis.schemaVersion)",
                postProcessRevision: "compatibility-postprocess-v1",
                calibrationRevision: "compatibility-calibration-v1"
            )
        }
        return MangaVisionModelManifest(
            modelID: manifest.modelID,
            modelBuildID: manifest.modelBuildID,
            modelFileHash: manifest.modelFileHash,
            inputSize: manifest.inputSize,
            semanticClasses: manifest.semanticClasses,
            outputContractRevision: manifest.outputContractRevision,
            analysisSchemaRevision: manifest.analysisSchemaRevision,
            postProcessRevision: "\(manifest.postProcessRevision)|\(MangaVisionInferencePlanner.revision)",
            calibrationRevision: manifest.calibrationRevision
        )
    }

    func analyzePage(
        image: CGImage,
        sourceImageSize: CGSize,
        pageIdentifier: MangaPageIdentifier
    ) async throws -> MangaPageAnalysis {
        try await analyzeSourceImage(
            image: image,
            sourceImageSize: sourceImageSize,
            pageIdentifier: pageIdentifier,
            requestClass: .currentTask
        )
    }

    func analyzeSourceImage(
        image: CGImage,
        sourceImageSize: CGSize,
        pageIdentifier: MangaPageIdentifier,
        requestClass: MangaVisionRequestClass
    ) async throws -> MangaPageAnalysis {
        let manifest = await mangaVisionManifest()
        let resourceState = resourceStateOverride ?? .current
        let imageSize = CGSize(width: image.width, height: image.height)
        let plan = MangaVisionInferencePlanner.plan(
            sourceSize: imageSize,
            inputSize: manifest.inputSize,
            requestClass: requestClass,
            resourceState: resourceState
        )
        guard plan.allowsInference else {
            throw MangaVisionAdaptiveInferenceError.backgroundDeferred
        }

        let maximumDimension = max(Int(max(manifest.inputSize.width, manifest.inputSize.height).rounded()), 1)
        guard let baselineImage = Self.scaledImage(image, maximumDimension: maximumDimension) else {
            throw MangaVisionProviderError.modelUnavailable
        }
        let baseline = try await performPass(
            image: baselineImage,
            sourceImageSize: sourceImageSize,
            pageIdentifier: pageIdentifier,
            requestClass: requestClass
        )

        guard MangaVisionInferencePlanner.shouldRefine(baseline: baseline, plan: plan) else {
            return baseline
        }

        var refinements: [MangaPageAnalysis] = []
        refinements.reserveCapacity(plan.refinementTiles.count)
        for tile in plan.refinementTiles {
            try Task.checkCancellation()
            guard let crop = Self.croppedImage(image, normalizedRect: tile.sourceRect),
                  let tileImage = Self.scaledImage(crop, maximumDimension: maximumDimension) else {
                continue
            }
            let local = try await performPass(
                image: tileImage,
                sourceImageSize: sourceImageSize,
                pageIdentifier: pageIdentifier,
                requestClass: requestClass
            )
            refinements.append(
                MangaVisionAnalysisComposer.remap(
                    local,
                    from: tile.sourceRect,
                    acceptingCentersIn: tile.ownershipRect
                )
            )
        }
        return MangaVisionAnalysisComposer.merge(
            baseline: baseline,
            refinements: refinements
        )
    }

    func schedulerSnapshotForDiagnostics() async -> MangaVisionInferenceScheduler.Snapshot {
        await scheduler.snapshotForDiagnostics()
    }

    func totalInferencePassCountForDiagnostics() async -> Int {
        totalInferencePassCount
    }

    private func performPass(
        image: CGImage,
        sourceImageSize: CGSize,
        pageIdentifier: MangaPageIdentifier,
        requestClass: MangaVisionRequestClass
    ) async throws -> MangaPageAnalysis {
        await scheduler.acquire(for: requestClass)
        do {
            try Task.checkCancellation()
            totalInferencePassCount += 1
            let result = try await base.analyzePage(
                image: image,
                sourceImageSize: sourceImageSize,
                pageIdentifier: pageIdentifier
            )
            await scheduler.release()
            return result
        } catch {
            await scheduler.release()
            throw error
        }
    }

    nonisolated private static func croppedImage(
        _ source: CGImage,
        normalizedRect: CGRect
    ) -> CGImage? {
        let clamped = MangaPageCoordinateSpace.clampedNormalizedRect(normalizedRect)
        guard clamped.width > 0, clamped.height > 0 else { return nil }
        let width = CGFloat(source.width)
        let height = CGFloat(source.height)
        var pixelRect = CGRect(
            x: clamped.minX * width,
            y: clamped.minY * height,
            width: clamped.width * width,
            height: clamped.height * height
        ).integral
        pixelRect = pixelRect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard pixelRect.width >= 2, pixelRect.height >= 2 else { return nil }
        return source.cropping(to: pixelRect)
    }

    nonisolated private static func scaledImage(
        _ source: CGImage,
        maximumDimension: Int
    ) -> CGImage? {
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
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

nonisolated enum MangaVisionAnalysisComposer {
    static func remap(
        _ analysis: MangaPageAnalysis,
        from sourceRect: CGRect,
        acceptingCentersIn ownershipRect: CGRect
    ) -> MangaPageAnalysis {
        func remapRegion(_ region: MangaVisionRegion) -> MangaVisionRegion? {
            let local = region.normalizedRect
            let mappedRect = MangaPageCoordinateSpace.clampedNormalizedRect(CGRect(
                x: sourceRect.minX + local.minX * sourceRect.width,
                y: sourceRect.minY + local.minY * sourceRect.height,
                width: local.width * sourceRect.width,
                height: local.height * sourceRect.height
            ))
            let center = CGPoint(x: mappedRect.midX, y: mappedRect.midY)
            guard ownershipRect.insetBy(dx: -0.000_001, dy: -0.000_001).contains(center) else {
                return nil
            }
            let contour = region.contour.map { contour in
                MangaVisionContour(points: contour.cgPoints.map { point in
                    CGPoint(
                        x: sourceRect.minX + point.x * sourceRect.width,
                        y: sourceRect.minY + point.y * sourceRect.height
                    )
                })
            }
            return MangaVisionRegion(
                id: region.id,
                type: region.type,
                normalizedRect: mappedRect,
                confidence: region.confidence,
                contour: contour
            )
        }

        return MangaPageAnalysis(
            pageIdentifier: analysis.pageIdentifier,
            imageSize: analysis.imageSize,
            panels: analysis.panels.compactMap(remapRegion),
            texts: analysis.texts.compactMap(remapRegion),
            balloons: analysis.balloons.compactMap(remapRegion),
            faces: analysis.faces.compactMap(remapRegion),
            bodies: analysis.bodies.compactMap(remapRegion),
            modelIdentifier: analysis.modelIdentifier,
            modelVersion: analysis.modelVersion,
            schemaVersion: analysis.schemaVersion
        )
    }

    static func merge(
        baseline: MangaPageAnalysis,
        refinements: [MangaPageAnalysis]
    ) -> MangaPageAnalysis {
        let profile = MangaVisionCalibrationProfile.bundled
        let panels = profile.deduplicated(
            baseline.panels + refinements.flatMap(\.panels),
            type: .panel
        )
        let texts = profile.deduplicated(
            baseline.texts + refinements.flatMap(\.texts),
            type: .text
        )
        let balloons = profile.deduplicated(
            baseline.balloons + refinements.flatMap(\.balloons),
            type: .balloon
        )
        let faces = profile.deduplicated(
            baseline.faces + refinements.flatMap(\.faces),
            type: .face
        )
        let bodies = profile.deduplicated(
            baseline.bodies + refinements.flatMap(\.bodies),
            type: .body
        )
        return MangaPageAnalysis(
            pageIdentifier: baseline.pageIdentifier,
            imageSize: baseline.imageSize,
            panels: panels,
            texts: texts,
            balloons: balloons,
            faces: faces,
            bodies: bodies,
            modelIdentifier: baseline.modelIdentifier,
            modelVersion: baseline.modelVersion,
            schemaVersion: baseline.schemaVersion
        )
    }
}
