import CoreGraphics
import Foundation

/// The active development and production router exposes only the bundled Koharu
/// YOLO26s-seg provider. The retired V2B5 five-class detector and the older
/// Vision-based `PanelDetector` are recoverable through the archive tag, not through
/// active runtime state.
nonisolated enum MangaVisionProviderMode: String, CaseIterable, Sendable {
    case koharuYOLO26S = "KoharuYOLO26S"

    static let productionDefault: Self = .koharuYOLO26S

    static var currentForDiagnostics: Self {
        .koharuYOLO26S
    }
}

actor MangaVisionProviderRouter: MangaVisionProvider, MangaVisionManifestProviding, MangaVisionRuntimeReleasable {
    static let shared = MangaVisionProviderRouter(base: MangaVisionKoharuProvider.shared)

    private let base: any MangaVisionProvider

    init(base: any MangaVisionProvider) {
        self.base = base
    }

    var descriptor: MangaVisionProviderDescriptor {
        get async {
            await base.descriptor
        }
    }

    func mangaVisionManifest() async -> MangaVisionModelManifest {
        if let manifestProvider = base as? any MangaVisionManifestProviding {
            return await manifestProvider.mangaVisionManifest()
        }
        let descriptor = await base.descriptor
        return MangaVisionModelManifest(
            modelID: descriptor.modelIdentifier,
            modelVersion: descriptor.modelVersion,
            modelBuildID: "router-descriptor:\(descriptor.modelIdentifier)",
            modelFileHash: descriptor.modelIdentifier,
            inputSize: descriptor.inputSize,
            semanticClasses: descriptor.supportedRegionTypes,
            outputContractRevision: "router-output-v1",
            analysisSchemaRevision: "manga-page-analysis-v\(MangaPageAnalysis.schemaVersion)",
            postProcessRevision: "router-postprocess-v1",
            calibrationRevision: "router-calibration-v1"
        )
    }

    func analyzePage(
        image: CGImage,
        sourceImageSize: CGSize,
        pageIdentifier: MangaPageIdentifier
    ) async throws -> MangaPageAnalysis {
        try await base.analyzePage(
            image: image,
            sourceImageSize: sourceImageSize,
            pageIdentifier: pageIdentifier
        )
    }

    func releaseRuntimeMemory() async {
        if let releasable = base as? any MangaVisionRuntimeReleasable {
            await releasable.releaseRuntimeMemory()
        }
    }
}
