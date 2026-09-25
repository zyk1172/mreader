import CoreGraphics
import Foundation

nonisolated struct MangaVisionClassCalibration: Sendable, Equatable {
    let confidenceThreshold: Float
    let nmsIOUThreshold: CGFloat
    let containmentThreshold: CGFloat
}

/// One revisioned source of truth for detector filtering and same-class deduplication.
/// Any production threshold change must bump `revision`; the manifest includes this
/// value in cache identity so cached analyses cannot outlive their calibration.
nonisolated struct MangaVisionCalibrationProfile: Sendable, Equatable {
    let revision: String
    let byRegionType: [MangaRegionType: MangaVisionClassCalibration]

    static let bundled = MangaVisionCalibrationProfile(
        revision: "manga109-yolo26s-seg-calibration-2026-09-17-v1",
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
            .onomatopoeia: MangaVisionClassCalibration(
                confidenceThreshold: 0.30,
                nmsIOUThreshold: 0.35,
                containmentThreshold: 0.90
            ),
            // Kept explicit for forward-compatible checkpoints even though the
            // currently bundled checkpoint exports only frame/text/balloon.
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
