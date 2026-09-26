import CoreGraphics
import CoreML
import Foundation

nonisolated enum MangaLayout4V1ProductionIdentity {
    static let modelResourceName = "MangaLayout4V1"
    static let modelIdentifier = "manga-layout4-v1-coreml-fp32-640"
    static let modelVersion = 1
    static let trainingEpoch = 40
    static let validationComposite = 0.7520361892
    // This revision also invalidates cached page geometry when the model-input
    // coordinate contract changes. V4 fixes the duplicated vertical flip in the
    // CGImage -> CHW preprocessing path.
    static let postProcessRevision = "manga-layout4-v1-region-refinement-2026-09-26-v5"
    static let calibrationRevision = "manga-layout4-v1-qfl-score-contract-2026-09-26-v5"
}

nonisolated struct MangaLayout4V1ProviderDiagnostics: Sendable, Equatable {
    let decode: MangaLayout4V1DecodeDiagnostics
    let balloonInstanceCount: Int
    let balloonComponentCounts: [Int]
}

actor MangaLayout4V1Provider: MangaVisionProvider, MangaVisionSourceImageAnalyzing, MangaVisionRuntimeReleasable, MangaVisionManifestProviding {
    static let shared = MangaLayout4V1Provider()
    static let modelResourceName = MangaLayout4V1ProductionIdentity.modelResourceName
    static let modelIdentifier = MangaLayout4V1ProductionIdentity.modelIdentifier

    private struct Runtime {
        let model: MLModel
        let descriptor: MangaVisionProviderDescriptor
    }

    private let configuration: MangaLayout4V1Configuration
    private var runtime: Runtime?
    private var lastDiagnostics: MangaLayout4V1ProviderDiagnostics?

    init(configuration: MangaLayout4V1Configuration = MangaLayout4V1Configuration()) {
        self.configuration = configuration
    }

    var descriptor: MangaVisionProviderDescriptor {
        get async {
            if let runtime { return runtime.descriptor }
            if let loaded = try? loadRuntime() { return loaded.descriptor }
            // Descriptor metadata is static and does not imply a successful model load.
            // analyzePage still fails hard with modelUnavailable; no legacy model is tried.
            return Self.declaredDescriptor
        }
    }

    func mangaVisionManifest() async -> MangaVisionModelManifest {
        MangaVisionModelManifest.bundledMangaLayout4V1()
    }

    func analyzePage(
        image: CGImage,
        sourceImageSize: CGSize,
        pageIdentifier: MangaPageIdentifier
    ) async throws -> MangaPageAnalysis {
        try await analyzePageWithTiming(
            image: image,
            sourceImageSize: sourceImageSize,
            pageIdentifier: pageIdentifier
        ).analysis
    }

    /// MangaLayout4 V1 is a full-page model. Accept the reader's largest decoded
    /// source image so preprocessing performs exactly one letterbox resize, matching
    /// the training/export contract. Request class affects scheduling only, never
    /// page geometry.
    func analyzeSourceImage(
        image: CGImage,
        sourceImageSize: CGSize,
        pageIdentifier: MangaPageIdentifier,
        requestClass: MangaVisionRequestClass
    ) async throws -> MangaPageAnalysis {
        _ = requestClass
        return try await analyzePage(
            image: image,
            sourceImageSize: sourceImageSize,
            pageIdentifier: pageIdentifier
        )
    }

    func analyzePageWithTiming(
        image: CGImage,
        sourceImageSize: CGSize,
        pageIdentifier: MangaPageIdentifier
    ) async throws -> MangaVisionTimedAnalysis {
        let totalStart = ContinuousClock.now
        let runtime = try loadRuntime()

        let preprocessStart = ContinuousClock.now
        let prepared = try MangaLayout4V1Preprocessor.makeInput(from: image)
        let preprocessMilliseconds = Self.milliseconds(
            preprocessStart.duration(to: .now)
        )

        let input = try MLDictionaryFeatureProvider(dictionary: [
            MangaLayout4V1OutputContract.inputFeatureName: MLFeatureValue(
                multiArray: prepared.array
            )
        ])
        let modelStart = ContinuousClock.now
        let batch = try runtime.model.predictions(
            fromBatch: MLArrayBatchProvider(array: [input])
        )
        guard batch.count == 1 else {
            throw MangaLayout4V1Error.invalidInput(
                "unexpected Core ML batch output count=\(batch.count)"
            )
        }
        let prediction = batch.features(at: 0)
        let modelMilliseconds = Self.milliseconds(modelStart.duration(to: .now))

        let postprocessStart = ContinuousClock.now
        let rawOutputs = try MangaLayout4V1OutputContract.rawOutputs(from: prediction)
        let decoded = try MangaLayout4V1Decoder.decode(
            rawOutputs: rawOutputs,
            letterbox: prepared.letterbox,
            configuration: configuration
        )
        let balloons = try MangaLayout4V1MaskDecoder.decodeBalloonInstances(
            detections: decoded.detections,
            rawOutputs: rawOutputs,
            letterbox: prepared.letterbox,
            configuration: configuration
        )
        lastDiagnostics = MangaLayout4V1ProviderDiagnostics(
            decode: decoded.diagnostics,
            balloonInstanceCount: balloons.count,
            balloonComponentCounts: balloons.map(\.componentSummaries.count)
        )

        var balloonIndex = 0
        var panels: [MangaVisionRegion] = []
        var texts: [MangaVisionRegion] = []
        var balloonRegions: [MangaVisionRegion] = []
        var onomatopoeias: [MangaVisionRegion] = []

        for detection in decoded.detections {
            guard detection.normalizedRect.width > 0,
                  detection.normalizedRect.height > 0 else {
                if detection.layoutClass == .balloon { balloonIndex += 1 }
                continue
            }

            if detection.layoutClass == .balloon {
                guard balloonIndex < balloons.count else {
                    throw MangaLayout4V1Error.invalidInput(
                        "balloon detection/mask instance count drift"
                    )
                }
                let instance = balloons[balloonIndex]
                balloonIndex += 1
                balloonRegions.append(
                    MangaVisionRegion(
                        type: .balloon,
                        normalizedRect: MangaLayout4V1RegionRefiner.refinedBalloonRect(
                            rawRect: detection.normalizedRect,
                            primaryContour: instance.primaryContour,
                            secondaryContours: instance.secondaryContours
                        ),
                        confidence: detection.confidence,
                        contour: instance.primaryContour,
                        secondaryContours: instance.secondaryContours
                    )
                )
                continue
            }

            let regionType = detection.layoutClass.regionType
            let region = MangaVisionRegion(
                type: regionType,
                normalizedRect: MangaLayout4V1RegionRefiner.refinedSemanticRect(
                    detection.normalizedRect,
                    type: regionType
                ),
                confidence: detection.confidence
            )
            switch detection.layoutClass {
            case .frame:
                panels.append(region)
            case .text:
                texts.append(region)
            case .balloon:
                break
            case .onomatopoeia:
                onomatopoeias.append(region)
            }
        }

        let analysis = MangaPageAnalysis(
            pageIdentifier: pageIdentifier,
            imageSize: sourceImageSize,
            panels: panels,
            texts: texts,
            balloons: balloonRegions,
            onomatopoeias: onomatopoeias,
            modelIdentifier: runtime.descriptor.modelIdentifier,
            modelVersion: runtime.descriptor.modelVersion
        )
        return MangaVisionTimedAnalysis(
            analysis: analysis,
            timing: MangaVisionProviderTiming(
                preprocessMilliseconds: preprocessMilliseconds,
                modelMilliseconds: modelMilliseconds,
                postprocessMilliseconds: Self.milliseconds(
                    postprocessStart.duration(to: .now)
                ),
                totalMilliseconds: Self.milliseconds(totalStart.duration(to: .now))
            )
        )
    }

    func diagnosticsSnapshot() -> MangaLayout4V1ProviderDiagnostics? {
        lastDiagnostics
    }

    func releaseRuntimeMemory() async {
        runtime = nil
    }

    private func loadRuntime() throws -> Runtime {
        if let runtime { return runtime }
        guard let modelURL = Bundle.main.url(
            forResource: Self.modelResourceName,
            withExtension: "mlmodelc"
        ) else {
            throw MangaLayout4V1Error.modelUnavailable
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let model = try MLModel(contentsOf: modelURL, configuration: configuration)
        let violations = MangaLayout4V1OutputContract.validate(
            modelDescription: model.modelDescription
        )
        guard violations.isEmpty else {
            throw MangaLayout4V1Error.invalidContract(violations)
        }
        let descriptor = MangaVisionProviderDescriptor(
            modelIdentifier: Self.modelIdentifier,
            modelVersion: MangaLayout4V1ProductionIdentity.modelVersion,
            inputSize: MangaLayout4V1Preprocessor.inputSize,
            supportedRegionTypes: [.panel, .text, .balloon, .onomatopoeia],
            supportsBalloonMask: true
        )
        let loaded = Runtime(model: model, descriptor: descriptor)
        runtime = loaded
        return loaded
    }

    private static let declaredDescriptor = MangaVisionProviderDescriptor(
        modelIdentifier: modelIdentifier,
        modelVersion: MangaLayout4V1ProductionIdentity.modelVersion,
        inputSize: MangaLayout4V1Preprocessor.inputSize,
        supportedRegionTypes: [.panel, .text, .balloon, .onomatopoeia],
        supportsBalloonMask: true
    )

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}

nonisolated enum MangaLayout4V1RegionRefiner {
    private static let unit = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// Product-level geometry refinement only. Raw decoder diagnostics remain untouched.
    /// Text/SFX boxes receive a very small safety margin so OCR does not crop glyph strokes.
    static func refinedSemanticRect(
        _ rect: CGRect,
        type: MangaRegionType
    ) -> CGRect {
        let source = rect.standardized.intersection(unit)
        guard !source.isNull, source.width > 0, source.height > 0 else { return rect }
        let fraction: CGFloat
        let absoluteFloor: CGFloat
        switch type {
        case .text:
            fraction = 0.04
            absoluteFloor = 0.0015
        case .onomatopoeia:
            fraction = 0.06
            absoluteFloor = 0.002
        case .panel, .balloon:
            return source
        }
        let dx = max(source.width * fraction, absoluteFloor)
        let dy = max(source.height * fraction, absoluteFloor)
        return source.insetBy(dx: -dx, dy: -dy).intersection(unit)
    }

    /// The mask is usually a better description of the visible balloon than the raw
    /// regression box. Use it only when it agrees geometrically with the detection,
    /// then add a tiny margin so the tail/outline is not clipped.
    static func refinedBalloonRect(
        rawRect: CGRect,
        primaryContour: MangaVisionContour?,
        secondaryContours: [MangaVisionContour]
    ) -> CGRect {
        let raw = rawRect.standardized.intersection(unit)
        guard !raw.isNull, raw.width > 0, raw.height > 0 else { return rawRect }

        let contours = ([primaryContour].compactMap { $0 } + secondaryContours)
            .filter { !$0.points.isEmpty }
        guard let first = contours.first else { return raw }
        let envelope = contours.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
            .standardized
            .intersection(unit)
        guard !envelope.isNull, envelope.width > 0, envelope.height > 0 else { return raw }

        let rawArea = area(raw)
        let maskArea = area(envelope)
        guard rawArea > 0,
              maskArea >= rawArea * 0.08,
              maskArea <= rawArea * 1.35 else {
            return raw
        }

        let intersection = raw.intersection(envelope)
        guard !intersection.isNull else { return raw }
        let maskContainment = area(intersection) / max(maskArea, 0.000_001)
        guard maskContainment >= 0.60 else { return raw }

        let dx = max(envelope.width * 0.06, 0.003)
        let dy = max(envelope.height * 0.06, 0.003)
        let paddedMask = envelope.insetBy(dx: -dx, dy: -dy).intersection(unit)
        let allowed = raw.insetBy(
            dx: -max(raw.width * 0.08, 0.004),
            dy: -max(raw.height * 0.08, 0.004)
        ).intersection(unit)
        let refined = paddedMask.intersection(allowed)
        guard !refined.isNull,
              refined.width > 0,
              refined.height > 0,
              area(refined) >= rawArea * 0.10 else {
            return raw
        }
        return refined
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        max(rect.width, 0) * max(rect.height, 0)
    }
}

extension MangaVisionModelManifest {
    nonisolated static func bundledMangaLayout4V1(
        bundle: Bundle = .main
    ) -> MangaVisionModelManifest {
        let resourceName = MangaLayout4V1ProductionIdentity.modelResourceName
        let compiledURL = bundle.url(
            forResource: resourceName,
            withExtension: "mlmodelc"
        )
        let fileHash = compiledURL.flatMap(Self.hashModelDirectoryForDiagnostics)
            ?? "missing:\(resourceName)"
        let buildID = fileHash == "missing:\(resourceName)"
            ? fileHash
            : "sha256:\(fileHash.prefix(20))"
        return MangaVisionModelManifest(
            modelID: MangaLayout4V1ProductionIdentity.modelIdentifier,
            modelVersion: MangaLayout4V1ProductionIdentity.modelVersion,
            modelBuildID: buildID,
            modelFileHash: fileHash,
            inputSize: MangaLayout4V1Preprocessor.inputSize,
            semanticClasses: [.panel, .text, .balloon, .onomatopoeia],
            outputContractRevision: MangaLayout4V1OutputContract.revision,
            analysisSchemaRevision: "manga-page-analysis-v\(MangaPageAnalysis.schemaVersion)",
            postProcessRevision: MangaLayout4V1ProductionIdentity.postProcessRevision,
            calibrationRevision: MangaLayout4V1ProductionIdentity.calibrationRevision
        )
    }
}
