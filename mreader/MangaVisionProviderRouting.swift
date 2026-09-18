import CoreGraphics
import Foundation

nonisolated enum MangaVisionProviderMode: String, CaseIterable, Sendable {
    case oldProduction = "OLD"
    case v2b5 = "V2B5"
    case compare = "COMPARE"

    static let userDefaultsKey = "mreader.mangaVision.providerMode"

    static var currentForDiagnostics: Self {
#if DEBUG
        // UI tests use an argument instead of mutating shared simulator
        // defaults. This is DEBUG-only and cannot change the Release default.
        if ProcessInfo.processInfo.arguments.contains("-mreader-v2b5-provider") {
            return .v2b5
        }
        guard let raw = UserDefaults.standard.string(forKey: userDefaultsKey),
              let mode = Self(rawValue: raw) else {
            return .oldProduction
        }
        return mode
#else
        // The production build is intentionally hard-wired to the existing
        // provider until a separately reviewed switch is approved.
        return .oldProduction
#endif
    }

    static func setForDiagnostics(_ mode: Self) {
#if DEBUG
        UserDefaults.standard.set(mode.rawValue, forKey: userDefaultsKey)
#else
        _ = mode
#endif
    }
}

nonisolated struct MangaVisionABClassMetrics: Sendable, Equatable {
    let oldCount: Int
    let v2b5Count: Int
    let matched: Int
    let oldOnly: Int
    let v2b5Only: Int
    let meanIoU: Double?
    let p5IoU: Double?
    let minIoU: Double?
}

nonisolated struct MangaVisionABComparison: Sendable, Equatable {
    let oldCount: Int
    let v2b5Count: Int
    let matched: Int
    let oldOnly: Int
    let v2b5Only: Int
    let classFlips: Int
    let classAgreement: Double
    let meanIoU: Double?
    let p5IoU: Double?
    let minIoU: Double?
    let perClass: [MangaRegionType: MangaVisionABClassMetrics]
}

nonisolated enum MangaVisionABComparator {
    static let matchIoUThreshold: CGFloat = 0.50

    static func compare(
        old: MangaPageAnalysis,
        v2b5: MangaPageAnalysis
    ) -> MangaVisionABComparison {
        var allPairs: [(old: MangaVisionRegion, v2b5: MangaVisionRegion, iou: CGFloat)] = []
        var matchedOldIDs = Set<UUID>()
        var matchedV2B5IDs = Set<UUID>()
        var perClass: [MangaRegionType: MangaVisionABClassMetrics] = [:]

        for type in MangaRegionType.allCases {
            let oldRegions = old.regions(of: type)
            let v2b5Regions = v2b5.regions(of: type)
            let pairs = maximumIoUPairs(oldRegions, v2b5Regions)
            for pair in pairs {
                matchedOldIDs.insert(pair.old.id)
                matchedV2B5IDs.insert(pair.v2b5.id)
                allPairs.append(pair)
            }
            let ious = pairs.map { Double($0.iou) }.sorted()
            perClass[type] = MangaVisionABClassMetrics(
                oldCount: oldRegions.count,
                v2b5Count: v2b5Regions.count,
                matched: pairs.count,
                oldOnly: oldRegions.count - pairs.count,
                v2b5Only: v2b5Regions.count - pairs.count,
                meanIoU: ious.isEmpty ? nil : ious.reduce(0, +) / Double(ious.count),
                p5IoU: ious.isEmpty ? nil : ious[max(Int(Double(ious.count - 1) * 0.05), 0)],
                minIoU: ious.min()
            )
        }

        // A second pass identifies a same-location class flip without treating
        // it as a same-class match. This is diagnostic only; no output is changed.
        let unmatchedOld = old.allRegions.filter { !matchedOldIDs.contains($0.id) }
        let unmatchedV2B5 = v2b5.allRegions.filter { !matchedV2B5IDs.contains($0.id) }
        let crossClassPairs = maximumIoUPairs(
            unmatchedOld,
            unmatchedV2B5,
            requireDifferentTypes: true
        )
        let matched = allPairs.count
        let oldOnly = old.allRegions.count - matched
        let v2b5Only = v2b5.allRegions.count - matched
        let ious = allPairs.map { Double($0.iou) }.sorted()
        let denominator = max(old.allRegions.count, v2b5.allRegions.count)
        return MangaVisionABComparison(
            oldCount: old.allRegions.count,
            v2b5Count: v2b5.allRegions.count,
            matched: matched,
            oldOnly: oldOnly,
            v2b5Only: v2b5Only,
            classFlips: crossClassPairs.count,
            classAgreement: denominator == 0 ? 1 : Double(matched) / Double(denominator),
            meanIoU: ious.isEmpty ? nil : ious.reduce(0, +) / Double(ious.count),
            p5IoU: ious.isEmpty ? nil : ious[max(Int(Double(ious.count - 1) * 0.05), 0)],
            minIoU: ious.min(),
            perClass: perClass
        )
    }

    private static func maximumIoUPairs(
        _ old: [MangaVisionRegion],
        _ v2b5: [MangaVisionRegion],
        requireDifferentTypes: Bool = false
    ) -> [(old: MangaVisionRegion, v2b5: MangaVisionRegion, iou: CGFloat)] {
        var remainingOld = Set(old.indices)
        var remainingV2B5 = Set(v2b5.indices)
        var result: [(old: MangaVisionRegion, v2b5: MangaVisionRegion, iou: CGFloat)] = []
        while true {
            let eligible: [(Int, Int, CGFloat)] = remainingOld.flatMap { oldIndex in
                remainingV2B5.compactMap { v2b5Index in
                    let lhs = old[oldIndex]
                    let rhs = v2b5[v2b5Index]
                    guard !requireDifferentTypes || lhs.type != rhs.type else { return nil }
                    let iou = MangaPageCoordinateSpace.intersectionOverUnion(
                        lhs.normalizedRect,
                        rhs.normalizedRect
                    )
                    guard iou >= matchIoUThreshold else { return nil }
                    return (oldIndex, v2b5Index, iou)
                }
            }
            guard let best = eligible.max(by: { lhs, rhs in lhs.2 < rhs.2 }) else { break }
            remainingOld.remove(best.0)
            remainingV2B5.remove(best.1)
            result.append((old[best.0], v2b5[best.1], best.2))
        }
        return result
    }
}

nonisolated struct MangaVisionABDiagnosticRecord: Sendable, Equatable {
    let pageIndex: Int
    let oldModelIdentifier: String?
    let v2b5ModelIdentifier: String?
    let comparison: MangaVisionABComparison
}

actor MangaVisionProviderRouter: MangaVisionProvider, MangaVisionManifestProviding {
    static let shared = MangaVisionProviderRouter(
        old: YOLOMangaVisionProvider.shared,
        v2b5: MangaVisionV2B5Provider.shared
    )

    private let old: any MangaVisionProvider
    private let v2b5: any MangaVisionProvider
    private var records: [MangaVisionABDiagnosticRecord] = []

    init(
        old: any MangaVisionProvider,
        v2b5: any MangaVisionProvider
    ) {
        self.old = old
        self.v2b5 = v2b5
    }

    var descriptor: MangaVisionProviderDescriptor {
        get async {
            switch MangaVisionProviderMode.currentForDiagnostics {
            case .v2b5:
                return await v2b5.descriptor
            case .oldProduction, .compare:
                return await old.descriptor
            }
        }
    }

    func mangaVisionManifest() async -> MangaVisionModelManifest {
        switch MangaVisionProviderMode.currentForDiagnostics {
        case .v2b5:
            return await manifest(for: v2b5)
        case .oldProduction, .compare:
            return await manifest(for: old)
        }
    }

    func analyzePage(
        image: CGImage,
        sourceImageSize: CGSize,
        pageIdentifier: MangaPageIdentifier
    ) async throws -> MangaPageAnalysis {
        switch MangaVisionProviderMode.currentForDiagnostics {
        case .oldProduction:
            return try await old.analyzePage(
                image: image,
                sourceImageSize: sourceImageSize,
                pageIdentifier: pageIdentifier
            )
        case .v2b5:
            return try await v2b5.analyzePage(
                image: image,
                sourceImageSize: sourceImageSize,
                pageIdentifier: pageIdentifier
            )
        case .compare:
            async let oldResult = old.analyzePage(
                image: image,
                sourceImageSize: sourceImageSize,
                pageIdentifier: pageIdentifier
            )
            async let v2b5Result = v2b5.analyzePage(
                image: image,
                sourceImageSize: sourceImageSize,
                pageIdentifier: pageIdentifier
            )
            let (oldAnalysis, v2b5Analysis) = try await (oldResult, v2b5Result)
            let comparison = MangaVisionABComparator.compare(old: oldAnalysis, v2b5: v2b5Analysis)
            records.append(
                MangaVisionABDiagnosticRecord(
                    pageIndex: pageIdentifier.pageIndex,
                    oldModelIdentifier: oldAnalysis.modelIdentifier,
                    v2b5ModelIdentifier: v2b5Analysis.modelIdentifier,
                    comparison: comparison
                )
            )
            return oldAnalysis
        }
    }

    func diagnosticRecords() -> [MangaVisionABDiagnosticRecord] {
        records
    }

    func resetDiagnostics() {
        records.removeAll()
    }

    private func manifest(for provider: any MangaVisionProvider) async -> MangaVisionModelManifest {
        if let manifestProvider = provider as? any MangaVisionManifestProviding {
            return await manifestProvider.mangaVisionManifest()
        }
        let descriptor = await provider.descriptor
        return MangaVisionModelManifest(
            modelID: descriptor.modelIdentifier,
            modelVersion: descriptor.modelVersion,
            modelBuildID: "router-descriptor:\(descriptor.modelIdentifier)",
            modelFileHash: descriptor.modelIdentifier,
            inputSize: descriptor.inputSize,
            semanticClasses: descriptor.supportedRegionTypes,
            outputContractRevision: "router-output-v1",
            analysisSchemaRevision: "manga-page-analysis-v\(MangaPageAnalysis.schemaVersion)",
            postProcessRevision: "router-postprocess-v1",
            calibrationRevision: "router-calibration-v1"
        )
    }
}
