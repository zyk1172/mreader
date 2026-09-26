import CoreGraphics
import Foundation

nonisolated struct MangaVisionClassCalibration: Sendable, Equatable {
    let confidenceThreshold: Float
    let iouThreshold: CGFloat
    let containmentThreshold: CGFloat
}

/// One revisioned source of truth for detector filtering and same-class deduplication.
///
/// The bundled Koharu YOLO26s-seg checkpoint has an end-to-end, NMS-free head: it
/// ranks and de-duplicates its own output, so `iouThreshold` is **not** a detector NMS
/// parameter. It is the merge threshold applied when a long page is analysed as a
/// full-page pass plus overlapping refinement tiles, and when semantic consumers
/// collapse near-identical regions. `confidenceThreshold` records the checkpoint's
/// recommended operating point.
///
/// Any production threshold change must bump `revision`; the manifest includes this
/// value in cache identity so cached analyses cannot outlive their calibration.
nonisolated struct MangaVisionCalibrationProfile: Sendable, Equatable {
    let revision: String
    let byRegionType: [MangaRegionType: MangaVisionClassCalibration]

    static let bundled = MangaVisionCalibrationProfile(
        revision: MangaVisionKoharuProductionIdentity.calibrationRevision,
        byRegionType: [
            .panel: MangaVisionClassCalibration(
                confidenceThreshold: MangaVisionKoharuDecoder.scoreThreshold,
                iouThreshold: 0.68,
                containmentThreshold: 0.96
            ),
            .text: MangaVisionClassCalibration(
                confidenceThreshold: MangaVisionKoharuDecoder.scoreThreshold,
                iouThreshold: 0.58,
                containmentThreshold: 0.88
            ),
            .balloon: MangaVisionClassCalibration(
                confidenceThreshold: MangaVisionKoharuDecoder.scoreThreshold,
                iouThreshold: 0.62,
                containmentThreshold: 0.90
            ),
            .onomatopoeia: MangaVisionClassCalibration(
                confidenceThreshold: MangaVisionKoharuDecoder.scoreThreshold,
                iouThreshold: 0.58,
                containmentThreshold: 0.88
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
            confidenceThreshold: MangaVisionKoharuDecoder.scoreThreshold,
            iouThreshold: 0.62,
            containmentThreshold: 0.92
        )
    }

    func deduplicated(_ regions: [MangaVisionRegion], type: MangaRegionType) -> [MangaVisionRegion] {
        let calibration = calibration(for: type)
        return MangaVisionRegionPostProcessor.deduplicated(
            regions,
            iouThreshold: calibration.iouThreshold,
            containmentThreshold: calibration.containmentThreshold
        )
    }
}
