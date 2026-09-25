import CoreGraphics
import Foundation

/// Production remains pinned to the frozen V2B5 provider. MangaLayout4 V1 is
/// available only through explicit dependency injection/development routing until
/// its Python/Swift parity and device-quality gates are complete.
nonisolated enum MangaVisionProviderMode: String, CaseIterable, Sendable {
    case v2b5 = "V2B5"
    case mangaLayout4V1 = "MangaLayout4V1"

    static let productionDefault: Self = .v2b5

    static var currentForDiagnostics: Self {
        .productionDefault
    }
}

actor MangaVisionProviderRouter: MangaVisionProvider, MangaVisionManifestProviding, MangaVisionRuntimeReleasable {
    static let shared = MangaVisionProviderRouter(
        v2b5: MangaVisionV2B5Provider.shared,
        mangaLayout4V1: MangaLayout4V1Provider.shared,
        mode: .productionDefault
    )

    private let v2b5: any MangaVisionProvider
    private let mangaLayout4V1: any MangaVisionProvider
    private let mode: MangaVisionProviderMode

    init(
        v2b5: any MangaVisionProvider,
        mangaLayout4V1: any MangaVisionProvider = MangaLayout4V1Provider.shared,
        mode: MangaVisionProviderMode = .productionDefault
    ) {
        self.v2b5 = v2b5
        self.mangaLayout4V1 = mangaLayout4V1
        self.mode = mode
    }

    static func development(mode: MangaVisionProviderMode) -> MangaVisionProviderRouter {
        MangaVisionProviderRouter(
            v2b5: MangaVisionV2B5Provider.shared,
            mangaLayout4V1: MangaLayout4V1Provider.shared,
            mode: mode
        )
    }

    private var activeProvider: any MangaVisionProvider {
        switch mode {
        case .v2b5: v2b5
        case .mangaLayout4V1: mangaLayout4V1
        }
    }

    var descriptor: MangaVisionProviderDescriptor {
        get async {
            await activeProvider.descriptor
        }
    }

    func mangaVisionManifest() async -> MangaVisionModelManifest {
        let provider = activeProvider
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
        try await activeProvider.analyzePage(
            image: image,
            sourceImageSize: sourceImageSize,
            pageIdentifier: pageIdentifier
        )
    }

    func releaseRuntimeMemory() async {
        let provider = activeProvider
        if let releasable = provider as? any MangaVisionRuntimeReleasable {
            await releasable.releaseRuntimeMemory()
        }
    }
}
