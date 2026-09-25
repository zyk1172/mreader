import CoreGraphics
import Foundation

nonisolated struct MangaVisionClassCalibration: Sendable, Equatable {
    let confidenceThreshold: Float
    let nmsIOUThreshold: CGFloat
}

/// MangaLayout4 V1-only adaptive merge calibration. These defaults mirror the
/// frozen training/export postprocess contract. Quality-Focal confidence is not
/// comparable to the previous detector's probability scale, so downstream
/// consumers must not re-introduce the old high confidence gates.
nonisolated struct MangaVisionCalibrationProfile: Sendable, Equatable {
    let revision: String
    let byRegionType: [MangaRegionType: MangaVisionClassCalibration]

    static let bundled = MangaVisionCalibrationProfile(
        revision: "manga-layout4-v1-training-postprocess-2026-09-26-v2",
        byRegionType: [
            .panel: MangaVisionClassCalibration(
                confidenceThreshold: 0.05,
                nmsIOUThreshold: 0.50
            ),
            .text: MangaVisionClassCalibration(
                confidenceThreshold: 0.05,
                nmsIOUThreshold: 0.50
            ),
            .balloon: MangaVisionClassCalibration(
                confidenceThreshold: 0.05,
                nmsIOUThreshold: 0.45
            ),
            .onomatopoeia: MangaVisionClassCalibration(
                confidenceThreshold: 0.05,
                nmsIOUThreshold: 0.45
            )
        ]
    )

    var confidenceThresholds: [MangaRegionType: Float] {
        Dictionary(uniqueKeysWithValues: byRegionType.map { type, calibration in
            (type, calibration.confidenceThreshold)
        })
    }

    func calibration(for type: MangaRegionType) -> MangaVisionClassCalibration {
        byRegionType[type]!
    }

    func deduplicated(_ regions: [MangaVisionRegion], type: MangaRegionType) -> [MangaVisionRegion] {
        let threshold = calibration(for: type).nmsIOUThreshold
        var kept: [MangaVisionRegion] = []
        for candidate in regions
            .filter({ $0.type == type })
            .sorted(by: { $0.confidence > $1.confidence }) {
            let suppressed = kept.contains { existing in
                MangaPageCoordinateSpace.intersectionOverUnion(
                    existing.normalizedRect,
                    candidate.normalizedRect
                ) > threshold
            }
            if !suppressed {
                kept.append(candidate)
            }
        }
        return kept
    }
}
