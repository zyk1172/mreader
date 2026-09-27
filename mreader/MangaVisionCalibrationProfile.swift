import CoreGraphics
import Foundation

nonisolated struct MangaVisionClassCalibration: Sendable, Equatable {
    /// App-level operating point for this class. This is a hard filter read by
    /// `PanelDetectionService` and by semantic consumers, not a reporting artefact, so it
    /// must stay at or above `MangaVisionKoharuDecoder.scoreThreshold` to mean anything.
    let confidenceThreshold: Float
    let iouThreshold: CGFloat
    let containmentThreshold: CGFloat
    /// Containment-based de-duplication only applies when the two boxes are at least this
    /// comparable in size. `nil` keeps the ungated legacy behaviour.
    let minimumSizeRatio: CGFloat?
}

/// One revisioned source of truth for detector filtering and same-class de-duplication.
///
/// Two different jobs live here, and conflating them is what previously deleted real panels:
///
/// - `deduplicated(_:type:)` is the **detector's** de-duplication. Its only job is to
///   collapse rows describing one instance. It must stay permissive: it runs inside the
///   provider, so anything it removes is gone for every consumer, including the ones that
///   have their own, better-informed policy.
/// - `confidenceThreshold` is the **app's** per-class operating point. Guided Panel's
///   navigation filtering (`PanelPostProcessor.navigationFloor`) is built on top of it, so
///   raising it above the intended relative floor silently disables that mechanism.
///
/// Navigation-level panel merging belongs to `PanelDetectionService.isNavigationDuplicate`,
/// which uses a wider IoU and a size floor to preserve inset panels. The profile must not
/// pre-empt it.
///
/// The bundled checkpoint has an end-to-end, NMS-free head, so `iouThreshold` is **not** a
/// detector NMS parameter: no NMS runs. It only governs collapsing duplicate rows and
/// merging a full-page pass with overlapping refinement tiles.
///
/// Any production threshold change must bump `revision`; the manifest includes this value in
/// cache identity so cached analyses cannot outlive their calibration.
nonisolated struct MangaVisionCalibrationProfile: Sendable, Equatable {
    let revision: String
    let byRegionType: [MangaRegionType: MangaVisionClassCalibration]

    static let bundled = MangaVisionCalibrationProfile(
        revision: MangaVisionKoharuProductionIdentity.calibrationRevision,
        byRegionType: [
            .panel: MangaVisionClassCalibration(
                // Equal to the decoder's admission floor on purpose: panels are admitted
                // permissively and the per-page relative floor in PanelDetectionService
                // does the real filtering. Keeping this at or below that relative floor
                // (0.14) is what makes the floor reachable at all.
                confidenceThreshold: MangaVisionKoharuDecoder.scoreThreshold,
                // Near-identity only. Adjacent or nested panels must survive long enough
                // for PanelDetectionService to apply its own merge policy.
                iouThreshold: 0.90,
                containmentThreshold: 0.97,
                minimumSizeRatio: 0.82
            ),
            .text: MangaVisionClassCalibration(
                confidenceThreshold: 0.18,
                iouThreshold: 0.58,
                containmentThreshold: 0.88,
                minimumSizeRatio: nil
            ),
            .balloon: MangaVisionClassCalibration(
                confidenceThreshold: 0.20,
                iouThreshold: 0.62,
                containmentThreshold: 0.90,
                minimumSizeRatio: nil
            ),
            .onomatopoeia: MangaVisionClassCalibration(
                confidenceThreshold: 0.20,
                iouThreshold: 0.58,
                containmentThreshold: 0.88,
                minimumSizeRatio: nil
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
            iouThreshold: 0.90,
            containmentThreshold: 0.97,
            minimumSizeRatio: 0.82
        )
    }

    func deduplicated(_ regions: [MangaVisionRegion], type: MangaRegionType) -> [MangaVisionRegion] {
        let calibration = calibration(for: type)
        return MangaVisionRegionPostProcessor.deduplicated(
            regions,
            iouThreshold: calibration.iouThreshold,
            containmentThreshold: calibration.containmentThreshold,
            minimumSizeRatio: calibration.minimumSizeRatio
        )
    }
}
