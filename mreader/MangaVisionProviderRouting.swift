import CoreGraphics
import Foundation

/// The active development and production router expose only the frozen V2B5
/// provider. The previous OLD and COMPARE selectors remain recoverable through
/// the archive tag, not through active runtime state.
nonisolated enum MangaVisionProviderMode: String, CaseIterable, Sendable {
    case v2b5 = "V2B5"

    static let productionDefault: Self = .v2b5

    static var currentForDiagnostics: Self {
        .v2b5
    }
}

actor MangaVisionProviderRouter: MangaVisionProvider, MangaVisionManifestProviding {
    static let shared = MangaVisionProviderRouter(
        v2b5: MangaVisionV2B5Provider.shared
    )

    private let v2b5: any MangaVisionProvider

    init(v2b5: any MangaVisionProvider) {
        self.v2b5 = v2b5
    }

    var descriptor: MangaVisionProviderDescriptor {
        get async {
            await v2b5.descriptor
        }
    }

    func mangaVisionManifest() async -> MangaVisionModelManifest {
        if let manifestProvider = v2b5 as? any MangaVisionManifestProviding {
            return await manifestProvider.mangaVisionManifest()
        }
        let descriptor = await v2b5.descriptor
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
        try await v2b5.analyzePage(
            image: image,
            sourceImageSize: sourceImageSize,
            pageIdentifier: pageIdentifier
        )
    }
}
