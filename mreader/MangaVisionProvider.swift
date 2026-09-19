import CoreGraphics
import Foundation

nonisolated struct MangaVisionProviderDescriptor: Sendable, Equatable {
    let modelIdentifier: String
    let modelVersion: Int
    let inputSize: CGSize
    let supportedRegionTypes: Set<MangaRegionType>
}

/// Capabilities are intentionally separate from semantic class support. V2B5
/// exposes all five semantic classes as bounding boxes, while contour output is
/// not part of the active model contract.
nonisolated struct MangaVisionProviderCapabilities: Sendable, Equatable {
    let supportsFrame: Bool
    let supportsText: Bool
    let supportsFace: Bool
    let supportsBody: Bool
    let supportsBalloon: Bool
    let supportsBalloonMask: Bool

    init(
        supportedRegionTypes: Set<MangaRegionType>,
        supportsBalloonMask: Bool
    ) {
        supportsFrame = supportedRegionTypes.contains(.panel)
        supportsText = supportedRegionTypes.contains(.text)
        supportsFace = supportedRegionTypes.contains(.face)
        supportsBody = supportedRegionTypes.contains(.body)
        supportsBalloon = supportedRegionTypes.contains(.balloon)
        self.supportsBalloonMask = supportsBalloonMask
    }
}

extension MangaVisionProviderDescriptor {
    var capabilities: MangaVisionProviderCapabilities {
        MangaVisionProviderCapabilities(
            supportedRegionTypes: supportedRegionTypes,
            supportsBalloonMask: false
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
