import CoreGraphics
import Foundation

nonisolated struct MangaVisionProviderDescriptor: Sendable, Equatable {
    let modelIdentifier: String
    let modelVersion: Int
    let inputSize: CGSize
    let supportedRegionTypes: Set<MangaRegionType>
    let supportsBalloonMask: Bool

    init(
        modelIdentifier: String,
        modelVersion: Int,
        inputSize: CGSize,
        supportedRegionTypes: Set<MangaRegionType>,
        supportsBalloonMask: Bool = false
    ) {
        self.modelIdentifier = modelIdentifier
        self.modelVersion = modelVersion
        self.inputSize = inputSize
        self.supportedRegionTypes = supportedRegionTypes
        self.supportsBalloonMask = supportsBalloonMask
    }
}

/// Runtime capabilities for the four-class MangaLayout4 V1 contract.
nonisolated struct MangaVisionProviderCapabilities: Sendable, Equatable {
    let supportsFrame: Bool
    let supportsText: Bool
    let supportsBalloon: Bool
    let supportsOnomatopoeia: Bool
    let supportsBalloonMask: Bool

    init(
        supportedRegionTypes: Set<MangaRegionType>,
        supportsBalloonMask: Bool
    ) {
        supportsFrame = supportedRegionTypes.contains(.panel)
        supportsText = supportedRegionTypes.contains(.text)
        supportsBalloon = supportedRegionTypes.contains(.balloon)
        supportsOnomatopoeia = supportedRegionTypes.contains(.onomatopoeia)
        self.supportsBalloonMask = supportsBalloonMask
    }
}

extension MangaVisionProviderDescriptor {
    var capabilities: MangaVisionProviderCapabilities {
        MangaVisionProviderCapabilities(
            supportedRegionTypes: supportedRegionTypes,
            supportsBalloonMask: supportsBalloonMask
        )
    }
}

nonisolated protocol MangaVisionProvider: Sendable {
    var descriptor: MangaVisionProviderDescriptor { get async }
    func analyzePage(
        image: CGImage,
        sourceImageSize: CGSize,
        pageIdentifier: MangaPageIdentifier
    ) async throws -> MangaPageAnalysis
}

/// Optional capability for providers that hold heavyweight runtime state (for example MLModel).
/// Reader close may release that runtime without changing the provider's semantic contract.
nonisolated protocol MangaVisionRuntimeReleasable: Sendable {
    func releaseRuntimeMemory() async
}

nonisolated enum MangaVisionProviderError: Error, Sendable {
    case modelUnavailable
    case unsupportedOutput
}

/// Stage timings are diagnostic evidence only. They do not change the provider
/// contract or production routing.
nonisolated struct MangaVisionProviderTiming: Sendable, Equatable {
    let preprocessMilliseconds: Double
    let modelMilliseconds: Double
    let postprocessMilliseconds: Double
    let totalMilliseconds: Double
}

nonisolated struct MangaVisionTimedAnalysis: Sendable {
    let analysis: MangaPageAnalysis
    let timing: MangaVisionProviderTiming
}

nonisolated enum MangaVisionRegionPostProcessor {
    static func deduplicated(
        _ regions: [MangaVisionRegion],
        iouThreshold: CGFloat = 0.62,
        containmentThreshold: CGFloat = 0.92
    ) -> [MangaVisionRegion] {
        var kept: [MangaVisionRegion] = []
        for candidate in regions.sorted(by: { $0.confidence > $1.confidence }) {
            let duplicate = kept.contains { existing in
                guard existing.type == candidate.type else { return false }
                return MangaPageCoordinateSpace.intersectionOverUnion(
                    existing.normalizedRect,
                    candidate.normalizedRect
                ) >= iouThreshold
                    || MangaPageCoordinateSpace.containment(
                        of: candidate.normalizedRect,
                        in: existing.normalizedRect
                    ) >= containmentThreshold
                    || MangaPageCoordinateSpace.containment(
                        of: existing.normalizedRect,
                        in: candidate.normalizedRect
                    ) >= containmentThreshold
            }
            if !duplicate { kept.append(candidate) }
        }
        return kept
    }
}
