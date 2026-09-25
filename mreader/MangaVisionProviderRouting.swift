import CoreGraphics
import Foundation

/// Branch-local integration route. This branch is intentionally MangaLayout4 V1-only:
/// there is no V2B5/legacy fallback path. If the new model cannot load or infer, the
/// error must propagate so device testing can never be mistaken for legacy output.
nonisolated enum MangaVisionProviderMode: String, CaseIterable, Sendable {
    case mangaLayout4V1 = "MangaLayout4V1"

    static let productionDefault: Self = .mangaLayout4V1

    static var currentForDiagnostics: Self {
        .productionDefault
    }
}

actor MangaVisionProviderRouter: MangaVisionProvider, MangaVisionManifestProviding, MangaVisionRuntimeReleasable {
    static let shared = MangaVisionProviderRouter(
        provider: MangaLayout4V1Provider.shared
    )

    private let provider: any MangaVisionProvider

    init(provider: any MangaVisionProvider = MangaLayout4V1Provider.shared) {
        self.provider = provider
    }

    /// Kept only for existing development call sites. The sole selectable mode on
    /// this integration branch is MangaLayout4 V1.
    static func development(mode: MangaVisionProviderMode) -> MangaVisionProviderRouter {
        precondition(mode == .mangaLayout4V1)
        return MangaVisionProviderRouter(provider: MangaLayout4V1Provider.shared)
    }

    var descriptor: MangaVisionProviderDescriptor {
        get async {
            await provider.descriptor
        }
    }

    func mangaVisionManifest() async -> MangaVisionModelManifest {
        if let manifestProvider = provider as? any MangaVisionManifestProviding {
            return await manifestProvider.mangaVisionManifest()
        }
        let descriptor = await provider.descriptor
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
        try await provider.analyzePage(
            image: image,
            sourceImageSize: sourceImageSize,
            pageIdentifier: pageIdentifier
        )
    }

    func releaseRuntimeMemory() async {
        if let releasable = provider as? any MangaVisionRuntimeReleasable {
            await releasable.releaseRuntimeMemory()
        }
    }
}
