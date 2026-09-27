import CoreGraphics
import Foundation

nonisolated struct MangaVisionProviderDescriptor: Sendable, Equatable {
    let modelIdentifier: String
    let modelVersion: Int
    let inputSize: CGSize
    let supportedRegionTypes: Set<MangaRegionType>
}

/// Capabilities are separate from semantic class support. The bundled Koharu
/// YOLO26s-seg detector exposes four semantic classes and a real instance mask for
/// every detection it keeps, so `supportsRegionMask` is true for all four.
nonisolated struct MangaVisionProviderCapabilities: Sendable, Equatable {
    let supportsFrame: Bool
    let supportsText: Bool
    let supportsBalloon: Bool
    let supportsOnomatopoeia: Bool
    /// True when the provider derives `MangaVisionRegion.contour` from a model mask
    /// rather than leaving it nil.
    let supportsRegionMask: Bool

    init(
        supportedRegionTypes: Set<MangaRegionType>,
        supportsRegionMask: Bool
    ) {
        supportsFrame = supportedRegionTypes.contains(.panel)
        supportsText = supportedRegionTypes.contains(.text)
        supportsBalloon = supportedRegionTypes.contains(.balloon)
        supportsOnomatopoeia = supportedRegionTypes.contains(.onomatopoeia)
        self.supportsRegionMask = supportsRegionMask
    }
}

extension MangaVisionProviderDescriptor {
    var capabilities: MangaVisionProviderCapabilities {
        MangaVisionProviderCapabilities(
            supportedRegionTypes: supportedRegionTypes,
            supportsRegionMask: true
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
    /// Collapses same-class regions that describe one instance.
    ///
    /// `minimumSizeRatio` gates the containment tests. Two boxes only describe the same
    /// instance when they are comparable in size; a small region fully inside a much
    /// larger one is a real nested region (an inset panel, a balloon inside a panel),
    /// not a duplicate. Callers that can produce nesting — panels — pass a floor, and
    /// callers that cannot leave it `nil` and keep the legacy containment behaviour.
    static func deduplicated(
        _ regions: [MangaVisionRegion],
        iouThreshold: CGFloat = 0.62,
        containmentThreshold: CGFloat = 0.92,
        minimumSizeRatio: CGFloat? = nil
    ) -> [MangaVisionRegion] {
        var kept: [MangaVisionRegion] = []
        for candidate in regions.sorted(by: { $0.confidence > $1.confidence }) {
            let candidateArea = MangaPageCoordinateSpace.area(candidate.normalizedRect)
            let duplicate = kept.contains { existing in
                guard existing.type == candidate.type else { return false }
                if MangaPageCoordinateSpace.intersectionOverUnion(
                    existing.normalizedRect,
                    candidate.normalizedRect
                ) >= iouThreshold {
                    return true
                }
                if let minimumSizeRatio {
                    let existingArea = MangaPageCoordinateSpace.area(existing.normalizedRect)
                    let smaller = min(existingArea, candidateArea)
                    let larger = max(existingArea, candidateArea)
                    guard larger > 0, smaller / larger >= minimumSizeRatio else { return false }
                }
                return MangaPageCoordinateSpace.containment(
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
