import CoreGraphics
import CryptoKit
import Foundation

/// Immutable identity for everything that can change the meaning of a Manga Vision result.
/// Cache validity is derived from this manifest instead of a manually incremented integer.
nonisolated struct MangaVisionModelManifest: Sendable, Equatable {
    let modelID: String
    let modelVersion: Int
    let modelBuildID: String
    let modelFileHash: String
    let inputSize: CGSize
    let semanticClasses: Set<MangaRegionType>
    let outputContractRevision: String
    let analysisSchemaRevision: String
    let postProcessRevision: String
    let calibrationRevision: String

    init(
        modelID: String,
        modelVersion: Int = 4,
        modelBuildID: String,
        modelFileHash: String,
        inputSize: CGSize,
        semanticClasses: Set<MangaRegionType>,
        outputContractRevision: String,
        analysisSchemaRevision: String,
        postProcessRevision: String,
        calibrationRevision: String
    ) {
        self.modelID = modelID
        self.modelVersion = modelVersion
        self.modelBuildID = modelBuildID
        self.modelFileHash = modelFileHash
        self.inputSize = inputSize
        self.semanticClasses = semanticClasses
        self.outputContractRevision = outputContractRevision
        self.analysisSchemaRevision = analysisSchemaRevision
        self.postProcessRevision = postProcessRevision
        self.calibrationRevision = calibrationRevision
    }

    var cacheIdentity: String {
        let classes = semanticClasses.map(\.rawValue).sorted().joined(separator: ",")
        return Self.sha256([
            modelID,
            modelBuildID,
            modelFileHash,
            "\(Int(inputSize.width))x\(Int(inputSize.height))",
            classes,
            outputContractRevision,
            analysisSchemaRevision,
            postProcessRevision,
            calibrationRevision
        ].joined(separator: "|"))
    }

    /// Compatibility descriptor for existing consumers. `modelVersion` is deliberately
    /// not part of Manga Vision cache identity; it is only retained for the older API.
    var compatibilityDescriptor: MangaVisionProviderDescriptor {
        MangaVisionProviderDescriptor(
            modelIdentifier: modelID,
            modelVersion: modelVersion,
            inputSize: inputSize,
            supportedRegionTypes: semanticClasses
        )
    }

    /// Public to the test target so replacing any byte in a model artifact can be
    /// proven to change the build identity without loading Core ML.
    static func hashModelDirectoryForDiagnostics(_ url: URL) -> String? {
        hashModelDirectory(url)
    }

    private static func hashModelDirectory(_ root: URL) -> String? {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var files: [(relativePath: String, url: URL)] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
            let relative = url.path.hasPrefix(prefix)
                ? String(url.path.dropFirst(prefix.count))
                : url.lastPathComponent
            files.append((relative, url))
        }
        guard !files.isEmpty else { return nil }

        var hasher = SHA256()
        for file in files.sorted(by: { $0.relativePath < $1.relativePath }) {
            hasher.update(data: Data(file.relativePath.utf8))
            hasher.update(data: Data([0]))
            guard let data = try? Data(contentsOf: file.url, options: [.mappedIfSafe]) else {
                return nil
            }
            hasher.update(data: data)
            hasher.update(data: Data([0xff]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// Providers that can describe their cache/model contract without constructing MLModel.
nonisolated protocol MangaVisionManifestProviding: Sendable {
    func mangaVisionManifest() async -> MangaVisionModelManifest
}

/// Content identity belongs to the source layer. Manga Vision consumes this opaque
/// identity and does not need to understand Komga, archives, OPDS or file URL formats.
nonisolated struct PageContentIdentity: Sendable, Equatable, Hashable {
    let sourceKind: String
    let resourceIdentity: String
    let revision: String

    var fingerprint: String {
        Self.sha256("\(sourceKind)|\(resourceIdentity)|\(revision)")
    }

    static func local(path: String, size: Int64, modificationTime: TimeInterval) -> Self {
        Self(
            sourceKind: "local",
            resourceIdentity: path,
            revision: "size:\(size)|mtime:\(modificationTime)"
        )
    }

    static func remote(provider: String, resource: String, revision: String) -> Self {
        Self(sourceKind: provider, resourceIdentity: resource, revision: revision)
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// Source-layer compatibility resolver. New source implementations can pass a stronger
/// identity directly; existing callers still get content-aware local/Komga identities.
nonisolated enum PageContentIdentityResolver {
    static func identity(for pageURL: URL) -> PageContentIdentity {
        if let request = RemotePageLoader.RemotePageRequest(url: pageURL) {
            let resource = "\(request.sourceID.uuidString.lowercased())/\(request.bookID)/\(request.pageIndex)"
            return .remote(
                provider: "komga",
                resource: resource,
                revision: remoteCachedRevision(for: request) ?? "origin-unversioned"
            )
        }

        if pageURL.isFileURL {
            let values = try? pageURL.resourceValues(forKeys: [
                .fileSizeKey,
                .contentModificationDateKey
            ])
            return .local(
                path: pageURL.standardizedFileURL.path,
                size: Int64(values?.fileSize ?? 0),
                modificationTime: values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            )
        }

        // Archive/OPDS/custom source layers can replace this compatibility identity by
        // passing PageContentIdentity explicitly to MangaVisionService.analysis().
        return .remote(
            provider: pageURL.scheme ?? "remote",
            resource: pageURL.absoluteString,
            revision: "origin-unversioned"
        )
    }

    private static func remoteCachedRevision(
        for request: RemotePageLoader.RemotePageRequest
    ) -> String? {
        for url in [
            RemotePageLoader.pageCacheURL(
                sourceID: request.sourceID,
                bookID: request.bookID,
                pageIndex: request.pageIndex
            ),
            RemotePageLoader.legacyPageCacheURL(
                sourceID: request.sourceID,
                bookID: request.bookID,
                pageIndex: request.pageIndex
            )
        ] {
            guard FileManager.default.fileExists(atPath: url.path),
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey]) else {
                continue
            }
            // RemotePageCache intentionally touches modificationDate on a read. Creation
            // date + size identifies an atomic cache replacement without churning on hits.
            return "cache-size:\(values.fileSize ?? 0)|created:\(values.creationDate?.timeIntervalSince1970 ?? 0)"
        }
        return nil
    }
}

nonisolated struct MangaVisionRequestGeneration: Sendable, Equatable, Hashable {
    let rawValue: UInt64

    func advanced() -> MangaVisionRequestGeneration {
        MangaVisionRequestGeneration(rawValue: rawValue &+ 1)
    }
}

nonisolated enum MangaVisionDiagnosticOutcome: String, Sendable, Equatable {
    case success
    case failure
    case staleDiscarded
}

nonisolated struct MangaVisionDiagnosticRecord: Sendable, Equatable {
    let timestamp: Date
    let outcome: MangaVisionDiagnosticOutcome
    let modelID: String
    let modelBuildID: String
    let pageIndex: Int
    let reason: String?
    let inferenceMilliseconds: Double?
    let analysisTotalMilliseconds: Double
    let panelCount: Int
    let textCount: Int
    let balloonCount: Int
}

nonisolated enum MangaVisionServiceError: Error, Sendable, Equatable {
    case staleResult
}
