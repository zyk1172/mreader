import CryptoKit
import Foundation
import ImageIO
import UIKit
import os

nonisolated struct MangaVisionPerformanceSnapshot: Sendable, Equatable {
    let modelIdentifier: String
    let inferenceCount: Int
    let memoryCacheHitCount: Int
    let diskCacheHitCount: Int
    let lastInferenceMilliseconds: Double?
    let averageInferenceMilliseconds: Double?
    let lastAnalysisMilliseconds: Double?
}

/// Single analysis entry point shared by Guided Panel, OCR, translation and debug.
/// It owns page/model cache identity and in-flight coalescing so consumers never
/// run the Core ML model independently for the same page.
actor MangaVisionService {
    static let shared = MangaVisionService(provider: YOLOMangaVisionProvider.shared)
    static let analysisRevision = "manga-vision-page-v1"

    private let provider: any MangaVisionProvider
    private let fileManager: FileManager
    private let cacheDirectory: URL
    private var memoryCache: [String: MangaPageAnalysis] = [:]
    private var memoryOrder: [String] = []
    private var inFlight: [String: Task<MangaPageAnalysis, Error>] = [:]
    private let memoryPageLimit = 48
    private let diskByteLimit: Int64 = 24 * 1024 * 1024

    private var inferenceCount = 0
    private var memoryCacheHitCount = 0
    private var diskCacheHitCount = 0
    private var totalInferenceMilliseconds: Double = 0
    private var lastInferenceMilliseconds: Double?
    private var lastAnalysisMilliseconds: Double?

    init(
        provider: any MangaVisionProvider,
        cacheDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.provider = provider
        self.fileManager = fileManager
        if let cacheDirectory {
            self.cacheDirectory = cacheDirectory
        } else {
            let root = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            self.cacheDirectory = root.appendingPathComponent("MangaVision", isDirectory: true)
        }
        try? fileManager.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
    }

    func analysis(
        comicID: UUID?,
        pageIndex: Int?,
        pageURL: URL,
        image: UIImage
    ) async throws -> MangaPageAnalysis {
        let analysisStart = ContinuousClock.now
        let descriptor = await provider.descriptor
        let sourceFingerprint = Self.sourceFingerprint(pageURL: pageURL, image: image)
        let identity = MangaPageIdentifier(
            scope: comicID?.uuidString.lowercased()
                ?? "legacy-\(Self.sha256(pageURL.deletingLastPathComponent().absoluteString))",
            pageIndex: max(pageIndex ?? 0, 0),
            sourceFingerprint: sourceFingerprint
        )
        let modelKey = Self.modelCacheKey(descriptor)
        let key = "\(modelKey)|\(identity.scope)|\(identity.pageIndex)|\(sourceFingerprint)"

        if let cached = memoryCache[key] {
            memoryCacheHitCount += 1
            touchMemoryKey(key)
            lastAnalysisMilliseconds = Self.milliseconds(analysisStart.duration(to: .now))
            return cached
        }
        let diskURL = cacheURL(modelKey: modelKey, identity: identity)
        if let cached = readValidCache(
            from: diskURL,
            descriptor: descriptor,
            identity: identity
        ) {
            diskCacheHitCount += 1
            insertIntoMemory(cached, forKey: key)
            lastAnalysisMilliseconds = Self.milliseconds(analysisStart.duration(to: .now))
            return cached
        }
        if let existing = inFlight[key] {
            let value = try await existing.value
            lastAnalysisMilliseconds = Self.milliseconds(analysisStart.duration(to: .now))
            return value
        }

        guard let analysisImage = Self.analysisCGImage(
            from: image,
            maximumDimension: Int(max(descriptor.inputSize.width, descriptor.inputSize.height))
        ) else {
            throw MangaVisionProviderError.modelUnavailable
        }
        let sourceSize = image.cgImage.map { CGSize(width: $0.width, height: $0.height) }
            ?? CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let provider = self.provider
        let task = Task(priority: .userInitiated) {
            try await provider.analyzePage(
                image: analysisImage,
                sourceImageSize: sourceSize,
                pageIdentifier: identity
            )
        }
        inFlight[key] = task
        do {
            let inferenceStart = ContinuousClock.now
            let result = try await task.value
            let inferenceMS = Self.milliseconds(inferenceStart.duration(to: .now))
            inFlight[key] = nil
            inferenceCount += 1
            totalInferenceMilliseconds += inferenceMS
            lastInferenceMilliseconds = inferenceMS
            insertIntoMemory(result, forKey: key)
            write(result, to: diskURL)
            lastAnalysisMilliseconds = Self.milliseconds(analysisStart.duration(to: .now))
            MReaderLog.aiVision.debug(
                "MangaVision analyze model=\(descriptor.modelIdentifier, privacy: .public) page=\(identity.pageIndex + 1, privacy: .public) panel=\(result.panels.count, privacy: .public) text=\(result.texts.count, privacy: .public) face=\(result.faces.count, privacy: .public) body=\(result.bodies.count, privacy: .public) inferenceMs=\(String(format: \"%.1f\", inferenceMS), privacy: .public)"
            )
            return result
        } catch {
            inFlight[key] = nil
            lastAnalysisMilliseconds = Self.milliseconds(analysisStart.duration(to: .now))
            throw error
        }
    }

    func cachedAnalysis(
        comicID: UUID?,
        pageIndex: Int?,
        pageURL: URL,
        image: UIImage
    ) async -> MangaPageAnalysis? {
        let descriptor = await provider.descriptor
        let sourceFingerprint = Self.sourceFingerprint(pageURL: pageURL, image: image)
        let identity = MangaPageIdentifier(
            scope: comicID?.uuidString.lowercased()
                ?? "legacy-\(Self.sha256(pageURL.deletingLastPathComponent().absoluteString))",
            pageIndex: max(pageIndex ?? 0, 0),
            sourceFingerprint: sourceFingerprint
        )
        let modelKey = Self.modelCacheKey(descriptor)
        let key = "\(modelKey)|\(identity.scope)|\(identity.pageIndex)|\(sourceFingerprint)"
        if let value = memoryCache[key] { return value }
        return readValidCache(
            from: cacheURL(modelKey: modelKey, identity: identity),
            descriptor: descriptor,
            identity: identity
        )
    }

    /// Uses the reader's already-selected bounded neighbour indices; this method
    /// does not invent a second prefetch horizon or analyze an entire book.
    func preanalyze(
        comicID: UUID,
        pages: [ComicPage],
        indices: [Int]
    ) async {
        let descriptor = await provider.descriptor
        let maximumDimension = Int(max(descriptor.inputSize.width, descriptor.inputSize.height))
        for index in indices.prefix(3) {
            guard pages.indices.contains(index), !Task.isCancelled else { return }
            let page = pages[index]
            guard let image = await Self.loadAnalysisImage(
                from: page.url,
                maximumDimension: maximumDimension
            ) else { continue }
            _ = try? await analysis(
                comicID: comicID,
                pageIndex: index,
                pageURL: page.url,
                image: image
            )
        }
    }

    func providerDescriptor() async -> MangaVisionProviderDescriptor {
        await provider.descriptor
    }

    func performanceSnapshot() async -> MangaVisionPerformanceSnapshot {
        let descriptor = await provider.descriptor
        return MangaVisionPerformanceSnapshot(
            modelIdentifier: descriptor.modelIdentifier,
            inferenceCount: inferenceCount,
            memoryCacheHitCount: memoryCacheHitCount,
            diskCacheHitCount: diskCacheHitCount,
            lastInferenceMilliseconds: lastInferenceMilliseconds,
            averageInferenceMilliseconds: inferenceCount > 0
                ? totalInferenceMilliseconds / Double(inferenceCount)
                : nil,
            lastAnalysisMilliseconds: lastAnalysisMilliseconds
        )
    }

    func clearCache() {
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        memoryCache.removeAll()
        memoryOrder.removeAll()
        try? fileManager.removeItem(at: cacheDirectory)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    private func readValidCache(
        from url: URL,
        descriptor: MangaVisionProviderDescriptor,
        identity: MangaPageIdentifier
    ) -> MangaPageAnalysis? {
        guard let data = try? Data(contentsOf: url),
              let cached = try? JSONDecoder().decode(MangaPageAnalysis.self, from: data),
              cached.schemaVersion == MangaPageAnalysis.schemaVersion,
              cached.modelIdentifier == descriptor.modelIdentifier,
              cached.modelVersion == descriptor.modelVersion,
              cached.pageIdentifier == identity else {
            return nil
        }
        return cached
    }

    private func write(_ analysis: MangaPageAnalysis, to url: URL) {
        guard let data = try? JSONEncoder().encode(analysis) else { return }
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
        pruneDiskCacheIfNeeded()
    }

    private func insertIntoMemory(_ analysis: MangaPageAnalysis, forKey key: String) {
        memoryCache[key] = analysis
        touchMemoryKey(key)
        while memoryOrder.count > memoryPageLimit {
            let removed = memoryOrder.removeFirst()
            memoryCache[removed] = nil
        }
    }

    private func touchMemoryKey(_ key: String) {
        memoryOrder.removeAll { $0 == key }
        memoryOrder.append(key)
    }

    private func cacheURL(modelKey: String, identity: MangaPageIdentifier) -> URL {
        cacheDirectory
            .appendingPathComponent(modelKey, isDirectory: true)
            .appendingPathComponent(identity.scope, isDirectory: true)
            .appendingPathComponent(String(format: "%04d", identity.pageIndex + 1))
            .appendingPathExtension("json")
    }

    private func pruneDiskCacheIfNeeded() {
        guard let enumerator = fileManager.enumerator(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        var entries: [(URL, Int64, Date)] = []
        var totalBytes: Int64 = 0
        for case let url as URL in enumerator {
            guard url.pathExtension == "json",
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
            let bytes = Int64(values.fileSize ?? 0)
            totalBytes += bytes
            entries.append((url, bytes, values.contentModificationDate ?? .distantPast))
        }
        guard totalBytes > diskByteLimit else { return }
        for entry in entries.sorted(by: { $0.2 < $1.2 }) where totalBytes > diskByteLimit {
            try? fileManager.removeItem(at: entry.0)
            totalBytes -= entry.1
        }
    }

    nonisolated private static func modelCacheKey(_ descriptor: MangaVisionProviderDescriptor) -> String {
        sha256("\(analysisRevision)|\(descriptor.modelIdentifier)|\(descriptor.modelVersion)")
    }

    nonisolated private static func sourceFingerprint(pageURL: URL, image: UIImage) -> String {
        // Cache identity belongs to the source page, not to a particular 640/4096/6144
        // decode. This is what lets Guided Panel and OCR join the same inference.
        _ = image
        let source: String
        if pageURL.isFileURL {
            let values = try? pageURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            source = "\(pageURL.path)#\(values?.fileSize ?? 0)#\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        } else {
            source = pageURL.absoluteString
        }
        return sha256(source)
    }

    nonisolated private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    nonisolated private static func analysisCGImage(
        from image: UIImage,
        maximumDimension: Int
    ) -> CGImage? {
        guard let source = image.cgImage else { return nil }
        let maximum = max(source.width, source.height)
        guard maximum > maximumDimension else { return source }
        let scale = CGFloat(maximumDimension) / CGFloat(max(maximum, 1))
        let width = max(Int((CGFloat(source.width) * scale).rounded()), 1)
        let height = max(Int((CGFloat(source.height) * scale).rounded()), 1)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return source }
        context.interpolationQuality = .medium
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? source
    }

    private static func loadAnalysisImage(
        from url: URL,
        maximumDimension: Int
    ) async -> UIImage? {
        if RemotePageLoader.isRemotePageURL(url) {
            guard let data = await RemotePageLoader.imageData(forRemotePageURL: url) else { return nil }
            return thumbnail(data: data, maximumDimension: maximumDimension)
        }
        if ComicManager.isArchivePageURL(url) {
            guard let data = ComicManager.imageData(forArchivePageURL: url) else { return nil }
            return thumbnail(data: data, maximumDimension: maximumDimension)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return thumbnail(source: source, maximumDimension: maximumDimension)
    }

    nonisolated private static func thumbnail(data: Data, maximumDimension: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return UIImage(data: data) }
        return thumbnail(source: source, maximumDimension: maximumDimension)
    }

    nonisolated private static func thumbnail(source: CGImageSource, maximumDimension: Int) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    nonisolated private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
