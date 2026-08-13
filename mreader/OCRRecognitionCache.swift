import CryptoKit
import Foundation
import UIKit

nonisolated struct OCRRecognitionCacheRequest: @unchecked Sendable {
    let pageURL: URL
    let fallbackImage: UIImage
    let options: OCRPreprocessor.Options

    var cacheKey: String {
        let sourceIdentity: String
        if pageURL.isFileURL {
            let values = try? pageURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            sourceIdentity = "\(pageURL.path)#\(values?.fileSize ?? 0)#\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        } else {
            sourceIdentity = pageURL.absoluteString
        }
        let rawValue = [
            "local-ocr-v1",
            sourceIdentity,
            options.isRightToLeft ? "rtl" : "ltr",
            String(format: "%.5f", options.minimumTextHeight),
            options.recognitionMode.rawValue,
            options.languages.joined(separator: ",")
        ].joined(separator: "|")
        return SHA256.hash(data: Data(rawValue.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

nonisolated private struct CachedOCRBlock: Codable, Sendable {
    let id: UUID
    let text: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let confidence: Double
    let source: String
    let estimatedFontScale: Double
    let textColorHex: String?

    init(_ block: TextBlock) {
        id = block.id
        text = block.text
        x = block.boundingBox.minX
        y = block.boundingBox.minY
        width = block.boundingBox.width
        height = block.boundingBox.height
        confidence = block.confidence
        source = block.ocrSource
        estimatedFontScale = block.estimatedFontScale
        textColorHex = block.textColorHex
    }

    var textBlock: TextBlock {
        TextBlock(
            id: id,
            text: text,
            boundingBox: CGRect(x: x, y: y, width: width, height: height),
            confidence: confidence,
            ocrSource: source,
            estimatedFontScale: estimatedFontScale,
            textColorHex: textColorHex
        )
    }
}

nonisolated private struct CachedOCRPage: Codable, Sendable {
    let createdAt: Date
    let rawBlocks: [CachedOCRBlock]
}

actor OCRRecognitionCache {
    static let shared = OCRRecognitionCache()

    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private let memoryPageLimit = 48
    private let diskByteLimit: Int64 = 30 * 1024 * 1024
    private var memoryCache: [String: OCRPipelineResult] = [:]
    private var memoryOrder: [String] = []
    private var inFlight: [String: Task<OCRPipelineResult, Error>] = [:]

    init() {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDirectory = root.appendingPathComponent("LocalOCR", isDirectory: true)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func result(for request: OCRRecognitionCacheRequest) async throws -> OCRPipelineResult {
        let key = request.cacheKey
        if let cached = cachedResult(forKey: key, isRightToLeft: request.options.isRightToLeft) {
            print("MReader local OCR cache hit key=\(key.prefix(10)) blocks=\(cached.resolvedBlocks.count)")
            return cached
        }
        if let existing = inFlight[key] {
            print("MReader local OCR joined in-flight key=\(key.prefix(10))")
            return try await existing.value
        }

        let task = Task(priority: .userInitiated) {
            let image = await OCRPreprocessor.highResolutionImage(
                from: request.pageURL,
                fallback: request.fallbackImage
            ) ?? request.fallbackImage
            return try await MangaOCRPipeline.recognize(in: image, options: request.options)
        }
        inFlight[key] = task
        do {
            let result = try await task.value
            inFlight[key] = nil
            store(result, forKey: key)
            return result
        } catch {
            inFlight[key] = nil
            throw error
        }
    }

    func clearCache() {
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        memoryCache.removeAll()
        memoryOrder.removeAll()
        try? fileManager.removeItem(at: cacheDirectory)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    private func cachedResult(forKey key: String, isRightToLeft: Bool) -> OCRPipelineResult? {
        if let result = memoryCache[key] {
            touchMemoryKey(key)
            return result
        }
        let url = fileURL(forKey: key)
        guard let data = try? Data(contentsOf: url),
              let page = try? JSONDecoder().decode(CachedOCRPage.self, from: data) else {
            return nil
        }
        let result = MangaOCRPipeline.resolveForDiagnostics(
            page.rawBlocks.map(\.textBlock),
            isRightToLeft: isRightToLeft
        )
        insertIntoMemory(result, forKey: key)
        return result
    }

    private func store(_ result: OCRPipelineResult, forKey key: String) {
        guard !result.rawBlocks.isEmpty else { return }
        insertIntoMemory(result, forKey: key)
        let page = CachedOCRPage(
            createdAt: Date(),
            rawBlocks: result.rawBlocks.map(CachedOCRBlock.init)
        )
        guard let data = try? JSONEncoder().encode(page) else { return }
        try? data.write(to: fileURL(forKey: key), options: .atomic)
        pruneDiskCacheIfNeeded()
        print("MReader local OCR cache stored key=\(key.prefix(10)) blocks=\(result.resolvedBlocks.count)")
    }

    private func insertIntoMemory(_ result: OCRPipelineResult, forKey key: String) {
        memoryCache[key] = result
        touchMemoryKey(key)
        while memoryOrder.count > memoryPageLimit {
            memoryCache[memoryOrder.removeFirst()] = nil
        }
    }

    private func touchMemoryKey(_ key: String) {
        memoryOrder.removeAll { $0 == key }
        memoryOrder.append(key)
    }

    private func fileURL(forKey key: String) -> URL {
        cacheDirectory.appendingPathComponent(key).appendingPathExtension("json")
    }

    private func pruneDiskCacheIfNeeded() {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let entries = urls.compactMap { url -> (URL, Int64, Date)? in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
                return nil
            }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
        var totalBytes = entries.reduce(Int64(0)) { $0 + $1.1 }
        guard totalBytes > diskByteLimit else { return }
        for entry in entries.sorted(by: { $0.2 < $1.2 }) where totalBytes > diskByteLimit {
            try? fileManager.removeItem(at: entry.0)
            totalBytes -= entry.1
        }
    }
}
