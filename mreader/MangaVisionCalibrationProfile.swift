import CoreGraphics
import Foundation

nonisolated struct MangaVisionClassCalibration: Sendable, Equatable {
    let confidenceThreshold: Float
    let nmsIOUThreshold: CGFloat
    let containmentThreshold: CGFloat
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
                nmsIOUThreshold: 0.50,
                containmentThreshold: 0.92
            ),
            .text: MangaVisionClassCalibration(
                confidenceThreshold: 0.05,
                nmsIOUThreshold: 0.50,
                containmentThreshold: 0.88
            ),
            .balloon: MangaVisionClassCalibration(
                confidenceThreshold: 0.05,
                nmsIOUThreshold: 0.45,
                containmentThreshold: 0.90
            ),
            .onomatopoeia: MangaVisionClassCalibration(
                confidenceThreshold: 0.05,
                nmsIOUThreshold: 0.45,
                containmentThreshold: 0.90
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
        let calibration = calibration(for: type)
        return MangaVisionRegionPostProcessor.deduplicated(
            regions,
            iouThreshold: calibration.nmsIOUThreshold,
            containmentThreshold: calibration.containmentThreshold
        )
    }
}
