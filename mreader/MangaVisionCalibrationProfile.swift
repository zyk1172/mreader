import CoreGraphics
import Foundation

nonisolated struct MangaVisionClassCalibration: Sendable, Equatable {
    let confidenceThreshold: Float
    let nmsIOUThreshold: CGFloat
}

/// MangaLayout4 V1 reader-evaluation calibration.
/// These values intentionally differ from the training/export reference decoder:
/// the test branch uses stricter product thresholds while preserving raw diagnostics.
nonisolated struct MangaVisionCalibrationProfile: Sendable, Equatable {
    let revision: String
    let byRegionType: [MangaRegionType: MangaVisionClassCalibration]

    static let bundled = MangaVisionCalibrationProfile(
        revision: "manga-layout4-v1-reader-eval-2026-09-26-v5",
        byRegionType: [
            .panel: MangaVisionClassCalibration(
                confidenceThreshold: 0.40,
                nmsIOUThreshold: 0.35
            ),
            .text: MangaVisionClassCalibration(
                confidenceThreshold: 0.45,
                nmsIOUThreshold: 0.35
            ),
            .balloon: MangaVisionClassCalibration(
                confidenceThreshold: 0.30,
                nmsIOUThreshold: 0.35
            ),
            .onomatopoeia: MangaVisionClassCalibration(
                confidenceThreshold: 0.30,
                nmsIOUThreshold: 0.35
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
