import CoreGraphics
import Foundation

nonisolated struct MangaVisionClassCalibration: Sendable, Equatable {
    let confidenceThreshold: Float
    let nmsIOUThreshold: CGFloat
    let containmentThreshold: CGFloat
}

/// Revisioned cross-pass merge calibration. V2B5's raw decoder owns its own
/// confidence/NMS thresholds; the confidence fields here are legacy metadata.
/// Any production threshold change must bump `revision`; the manifest includes this
/// value in cache identity so cached analyses cannot outlive their calibration.
nonisolated struct MangaVisionCalibrationProfile: Sendable, Equatable {
    let revision: String
    let byRegionType: [MangaRegionType: MangaVisionClassCalibration]

    static let bundled = MangaVisionCalibrationProfile(
        revision: "v2b5-cross-pass-merge-2026-10-02-v2",
        byRegionType: [
            .panel: MangaVisionClassCalibration(
                confidenceThreshold: 0.24,
                nmsIOUThreshold: 0.50,
                containmentThreshold: 0.92
            ),
            .text: MangaVisionClassCalibration(
                confidenceThreshold: 0.18,
                nmsIOUThreshold: 0.55,
                containmentThreshold: 0.88
            ),
            .balloon: MangaVisionClassCalibration(
                confidenceThreshold: 0.20,
                nmsIOUThreshold: 0.58,
                containmentThreshold: 0.90
            ),
            // The bundled V2B5 checkpoint exports all five classes.
            .face: MangaVisionClassCalibration(
                confidenceThreshold: 0.20,
                nmsIOUThreshold: 0.45,
                containmentThreshold: 0.90
            ),
            .body: MangaVisionClassCalibration(
                confidenceThreshold: 0.20,
                nmsIOUThreshold: 0.55,
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
        byRegionType[type] ?? MangaVisionClassCalibration(
            confidenceThreshold: 0.20,
            nmsIOUThreshold: 0.62,
            containmentThreshold: 0.92
        )
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
