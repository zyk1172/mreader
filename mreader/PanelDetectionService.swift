import CoreML
import CryptoKit
import Foundation
import UIKit
@preconcurrency import Vision

nonisolated enum PanelDetectionSource: String, Codable, Sendable {
    case coreML
    case visionRectangle
    case fullPageFallback
}

nonisolated struct DetectedPanel: Sendable, Equatable {
    let rect: CGRect
    let confidence: Float
    let source: PanelDetectionSource

    init(rect: CGRect, confidence: Float, source: PanelDetectionSource) {
        self.rect = rect
        self.confidence = confidence
        self.source = source
    }
}

nonisolated struct PanelLayoutPanel: Codable, Sendable, Equatable {
    let rect: NormalizedRect
    let confidence: Float
    let source: PanelDetectionSource
}

nonisolated struct PanelPageLayout: Codable, Sendable, Equatable {
    static let schemaVersion = 2
    static let modelVersion = 1

    let schemaVersion: Int
    let modelVersion: Int
    let detectorIdentifier: String
    let direction: String
    let sourceFingerprint: String
    let panels: [PanelLayoutPanel]
    let contentBounds: NormalizedRect
    let usedFallback: Bool

    var panelRects: [CGRect] { panels.map(\.rect.cgRect) }
}

nonisolated struct NormalizedRect: Codable, Sendable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        x = rect.minX
        y = rect.minY
        width = rect.width
        height = rect.height
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

nonisolated protocol PanelDetector: Sendable {
    var identifier: String { get }
    func detectPanels(in image: CGImage) throws -> [DetectedPanel]
}

nonisolated struct VisionRectanglePanelDetector: PanelDetector {
    let identifier = "vision-rectangle-v2"

    func detectPanels(in image: CGImage) throws -> [DetectedPanel] {
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 30
        request.minimumConfidence = 0.30
        request.minimumSize = 0.06
        request.minimumAspectRatio = 0.06
        request.maximumAspectRatio = 1
        request.quadratureTolerance = 24

        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        try handler.perform([request])

        return (request.results ?? []).map { observation in
            let box = observation.boundingBox
            return DetectedPanel(
                rect: CGRect(
                    x: box.minX,
                    y: 1 - box.maxY,
                    width: box.width,
                    height: box.height
                ),
                confidence: observation.confidence,
                source: .visionRectangle
            )
        }
    }
}

nonisolated struct CoreMLPanelDetector: PanelDetector, @unchecked Sendable {
    let identifier: String
    private let model: VNCoreMLModel

    private init(model: VNCoreMLModel, identifier: String) {
        self.model = model
        self.identifier = identifier
    }

    static func bundled(bundle: Bundle = .main) -> CoreMLPanelDetector? {
        guard let modelURL = bundle.url(forResource: "PanelDetector", withExtension: "mlmodelc") else {
            return nil
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        guard let mlModel = try? MLModel(contentsOf: modelURL, configuration: configuration),
              let visionModel = try? VNCoreMLModel(for: mlModel) else {
            return nil
        }
        return CoreMLPanelDetector(model: visionModel, identifier: "coreml-panel-v1")
    }

    func detectPanels(in image: CGImage) throws -> [DetectedPanel] {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFit
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        try handler.perform([request])
        let observations = (request.results as? [VNRecognizedObjectObservation]) ?? []

        return observations.compactMap { observation in
            if let topLabel = observation.labels.first,
               topLabel.identifier.caseInsensitiveCompare("panel") != .orderedSame {
                return nil
            }
            let box = observation.boundingBox
            return DetectedPanel(
                rect: CGRect(
                    x: box.minX,
                    y: 1 - box.maxY,
                    width: box.width,
                    height: box.height
                ),
                confidence: observation.confidence,
                source: .coreML
            )
        }
    }
}

nonisolated enum PanelPostProcessor {
    static func process(_ candidates: [DetectedPanel]) -> [DetectedPanel] {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let filtered = candidates.compactMap { panel -> DetectedPanel? in
            let rect = panel.rect.standardized.intersection(unit)
            guard !rect.isNull,
                  rect.width >= 0.055,
                  rect.height >= 0.045 else {
                return nil
            }
            let area = rect.width * rect.height
            guard area >= 0.012,
                  area <= 0.94,
                  panel.confidence >= 0.24 else {
                return nil
            }
            return DetectedPanel(
                rect: rect,
                confidence: panel.confidence,
                source: panel.source
            )
        }

        var kept: [DetectedPanel] = []
        for candidate in filtered.sorted(by: preferredCandidate) {
            let duplicateIndex = kept.firstIndex { existing in
                let intersection = existing.rect.intersection(candidate.rect)
                guard !intersection.isNull else { return false }
                let intersectionArea = intersection.width * intersection.height
                let existingArea = existing.rect.width * existing.rect.height
                let candidateArea = candidate.rect.width * candidate.rect.height
                let unionArea = max(existingArea + candidateArea - intersectionArea, 0.0001)
                let iou = intersectionArea / unionArea
                let containment = intersectionArea / max(min(existingArea, candidateArea), 0.0001)
                return iou >= 0.58 || containment >= 0.82
            }

            if let duplicateIndex {
                if candidate.confidence > kept[duplicateIndex].confidence {
                    kept[duplicateIndex] = candidate
                }
            } else {
                kept.append(candidate)
            }
        }
        return kept
    }

    private static func preferredCandidate(_ lhs: DetectedPanel, _ rhs: DetectedPanel) -> Bool {
        if lhs.confidence != rhs.confidence {
            return lhs.confidence > rhs.confidence
        }
        return lhs.rect.width * lhs.rect.height > rhs.rect.width * rhs.rect.height
    }
}

nonisolated enum PanelLayoutQuality {
    static func isUsable(_ panels: [DetectedPanel]) -> Bool {
        guard (2...12).contains(panels.count) else { return false }
        let averageConfidence = panels.reduce(Float.zero) { $0 + $1.confidence } / Float(panels.count)
        guard averageConfidence >= 0.34 else { return false }

        let totalArea = panels.reduce(CGFloat.zero) { partial, panel in
            partial + panel.rect.width * panel.rect.height
        }
        guard totalArea >= 0.22, totalArea <= 1.65 else { return false }

        var excessiveOverlapPairs = 0
        for lhsIndex in panels.indices {
            for rhsIndex in panels.indices where rhsIndex > lhsIndex {
                let lhs = panels[lhsIndex].rect
                let rhs = panels[rhsIndex].rect
                let intersection = lhs.intersection(rhs)
                guard !intersection.isNull else { continue }
                let intersectionArea = intersection.width * intersection.height
                let smallerArea = min(lhs.width * lhs.height, rhs.width * rhs.height)
                if intersectionArea / max(smallerArea, 0.0001) > 0.45 {
                    excessiveOverlapPairs += 1
                }
            }
        }
        return excessiveOverlapPairs <= max(1, panels.count / 4)
    }
}

actor PanelDetectionService {
    static let shared = PanelDetectionService()

    private struct CacheIdentity: Sendable {
        let scope: String
        let pageComponent: String
    }

    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private let primaryDetector: any PanelDetector
    private let fallbackDetector: any PanelDetector
    private var memoryCache: [String: PanelPageLayout] = [:]

    init(detector: (any PanelDetector)? = nil) {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDirectory = root.appendingPathComponent("PanelLayouts", isDirectory: true)
        fallbackDetector = VisionRectanglePanelDetector()
        primaryDetector = detector ?? CoreMLPanelDetector.bundled() ?? VisionRectanglePanelDetector()
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    /// Compatibility entry point used by the existing GuidedPanelReader.
    /// New call sites should prefer the comicID/pageIndex overload so the cache is easy to inspect.
    func layout(for pageURL: URL, image: UIImage, isRightToLeft: Bool) async -> PanelPageLayout {
        let scopeSource = pageURL.deletingLastPathComponent().absoluteString
        let identity = CacheIdentity(
            scope: "legacy-\(Self.sha256(scopeSource))",
            pageComponent: Self.sha256(pageURL.absoluteString)
        )
        return layout(
            cacheIdentity: identity,
            pageURL: pageURL,
            image: image,
            isRightToLeft: isRightToLeft
        )
    }

    /// Preferred cache shape: Library/Caches/PanelLayouts/<comicUUID>/<0001>.json.
    func layout(
        comicID: UUID,
        pageIndex: Int,
        pageURL: URL,
        image: UIImage,
        isRightToLeft: Bool
    ) async -> PanelPageLayout {
        let identity = CacheIdentity(
            scope: comicID.uuidString.lowercased(),
            pageComponent: String(format: "%04d", max(pageIndex, 0) + 1)
        )
        return layout(
            cacheIdentity: identity,
            pageURL: pageURL,
            image: image,
            isRightToLeft: isRightToLeft
        )
    }

    func clearCache() {
        memoryCache.removeAll()
        try? fileManager.removeItem(at: cacheDirectory)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    nonisolated static func sortedPanelsForDiagnostics(
        _ rects: [CGRect],
        isRightToLeft: Bool
    ) -> [CGRect] {
        let candidates = rects.map {
            DetectedPanel(rect: $0, confidence: 1, source: .visionRectangle)
        }
        return PanelReadingOrder.ordered(candidates, isRightToLeft: isRightToLeft).map(\.rect)
    }

    nonisolated static func cacheRelativePathForDiagnostics(
        comicID: UUID,
        pageIndex: Int
    ) -> String {
        "\(comicID.uuidString.lowercased())/\(String(format: "%04d", max(pageIndex, 0) + 1)).json"
    }

    private func layout(
        cacheIdentity: CacheIdentity,
        pageURL: URL,
        image: UIImage,
        isRightToLeft: Bool
    ) -> PanelPageLayout {
        let direction = isRightToLeft ? "rightToLeft" : "leftToRight"
        let sourceFingerprint = Self.sourceFingerprint(pageURL: pageURL, image: image)
        let memoryKey = "\(cacheIdentity.scope)|\(cacheIdentity.pageComponent)|\(direction)|\(primaryDetector.identifier)|\(sourceFingerprint)"
        if let cached = memoryCache[memoryKey] {
            return cached
        }

        let diskURL = cacheURL(for: cacheIdentity)
        let validDetectorIdentifiers = Set([primaryDetector.identifier, fallbackDetector.identifier])
        if let data = try? Data(contentsOf: diskURL),
           let cached = try? JSONDecoder().decode(PanelPageLayout.self, from: data),
           Self.isCacheValid(
                cached,
                direction: direction,
                validDetectorIdentifiers: validDetectorIdentifiers,
                sourceFingerprint: sourceFingerprint
           ) {
            memoryCache[memoryKey] = cached
            return cached
        }

        guard let analysisImage = Self.analysisCGImage(from: image, maximumDimension: 640) else {
            let fallback = Self.fullPageLayout(
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                direction: direction,
                sourceFingerprint: sourceFingerprint,
                detectorIdentifier: primaryDetector.identifier
            )
            store(fallback, memoryKey: memoryKey, diskURL: diskURL)
            return fallback
        }

        let contentBounds = Self.detectedContentBounds(analysisImage)
        let primaryPanels = (try? primaryDetector.detectPanels(in: analysisImage)) ?? []
        var processed = PanelPostProcessor.process(primaryPanels)
        var detectorIdentifier = primaryDetector.identifier

        if !PanelLayoutQuality.isUsable(processed),
           primaryDetector.identifier != fallbackDetector.identifier {
            let fallbackPanels = (try? fallbackDetector.detectPanels(in: analysisImage)) ?? []
            let fallbackProcessed = PanelPostProcessor.process(fallbackPanels)
            if PanelLayoutQuality.isUsable(fallbackProcessed) {
                processed = fallbackProcessed
                detectorIdentifier = fallbackDetector.identifier
            }
        }

        let result: PanelPageLayout
        if PanelLayoutQuality.isUsable(processed) {
            let ordered = PanelReadingOrder.ordered(processed, isRightToLeft: isRightToLeft)
            result = PanelPageLayout(
                schemaVersion: PanelPageLayout.schemaVersion,
                modelVersion: PanelPageLayout.modelVersion,
                detectorIdentifier: detectorIdentifier,
                direction: direction,
                sourceFingerprint: sourceFingerprint,
                panels: ordered.map {
                    PanelLayoutPanel(
                        rect: NormalizedRect($0.rect),
                        confidence: $0.confidence,
                        source: $0.source
                    )
                },
                contentBounds: NormalizedRect(contentBounds),
                usedFallback: false
            )
        } else {
            result = Self.fullPageLayout(
                bounds: contentBounds,
                direction: direction,
                sourceFingerprint: sourceFingerprint,
                detectorIdentifier: detectorIdentifier
            )
        }

        store(result, memoryKey: memoryKey, diskURL: diskURL)
        return result
    }

    private func cacheURL(for identity: CacheIdentity) -> URL {
        let scopeDirectory = cacheDirectory.appendingPathComponent(identity.scope, isDirectory: true)
        try? fileManager.createDirectory(at: scopeDirectory, withIntermediateDirectories: true)
        return scopeDirectory
            .appendingPathComponent(identity.pageComponent)
            .appendingPathExtension("json")
    }

    private func store(_ layout: PanelPageLayout, memoryKey: String, diskURL: URL) {
        memoryCache[memoryKey] = layout
        guard let data = try? JSONEncoder().encode(layout) else { return }
        try? data.write(to: diskURL, options: .atomic)
    }

    nonisolated private static func isCacheValid(
        _ layout: PanelPageLayout,
        direction: String,
        validDetectorIdentifiers: Set<String>,
        sourceFingerprint: String
    ) -> Bool {
        layout.schemaVersion == PanelPageLayout.schemaVersion
            && layout.modelVersion == PanelPageLayout.modelVersion
            && layout.direction == direction
            && validDetectorIdentifiers.contains(layout.detectorIdentifier)
            && layout.sourceFingerprint == sourceFingerprint
    }

    nonisolated private static func fullPageLayout(
        bounds: CGRect,
        direction: String,
        sourceFingerprint: String,
        detectorIdentifier: String
    ) -> PanelPageLayout {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let safeBounds = bounds.standardized.intersection(unit)
        let fallback = safeBounds.width > 0.1 && safeBounds.height > 0.1 ? safeBounds : unit
        return PanelPageLayout(
            schemaVersion: PanelPageLayout.schemaVersion,
            modelVersion: PanelPageLayout.modelVersion,
            detectorIdentifier: detectorIdentifier,
            direction: direction,
            sourceFingerprint: sourceFingerprint,
            panels: [
                PanelLayoutPanel(
                    rect: NormalizedRect(fallback),
                    confidence: 1,
                    source: .fullPageFallback
                )
            ],
            contentBounds: NormalizedRect(fallback),
            usedFallback: true
        )
    }

    nonisolated private static func analysisCGImage(
        from image: UIImage,
        maximumDimension: Int
    ) -> CGImage? {
        guard let source = image.cgImage else { return nil }
        let sourceWidth = max(source.width, 1)
        let sourceHeight = max(source.height, 1)
        let sourceMaximum = max(sourceWidth, sourceHeight)
        guard sourceMaximum > maximumDimension else { return source }

        let scale = CGFloat(maximumDimension) / CGFloat(sourceMaximum)
        let targetWidth = max(Int((CGFloat(sourceWidth) * scale).rounded()), 1)
        let targetHeight = max(Int((CGFloat(sourceHeight) * scale).rounded()), 1)
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return source
        }
        context.interpolationQuality = .medium
        context.draw(source, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage() ?? source
    }

    nonisolated private static func detectedContentBounds(_ image: CGImage) -> CGRect {
        let sampleWidth = 192
        let sampleHeight = max(
            1,
            Int(CGFloat(sampleWidth) * CGFloat(image.height) / CGFloat(max(image.width, 1)))
        )
        var pixels = [UInt8](repeating: 0, count: sampleWidth * sampleHeight * 4)
        guard let context = CGContext(
            data: &pixels,
            width: sampleWidth,
            height: sampleHeight,
            bitsPerComponent: 8,
            bytesPerRow: sampleWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))

        func luminance(x: Int, y: Int) -> Int {
            let offset = (y * sampleWidth + x) * 4
            return (
                Int(pixels[offset]) * 21
                    + Int(pixels[offset + 1]) * 72
                    + Int(pixels[offset + 2]) * 7
            ) / 100
        }

        let cornerValues = [
            luminance(x: 0, y: 0),
            luminance(x: sampleWidth - 1, y: 0),
            luminance(x: 0, y: sampleHeight - 1),
            luminance(x: sampleWidth - 1, y: sampleHeight - 1)
        ].sorted()
        let background = cornerValues[cornerValues.count / 2]

        func rowContainsContent(_ y: Int) -> Bool {
            var differing = 0
            for x in stride(from: 0, to: sampleWidth, by: 2)
            where abs(luminance(x: x, y: y) - background) > 24 {
                differing += 1
            }
            return differing >= max(3, sampleWidth / 24)
        }

        func columnContainsContent(_ x: Int) -> Bool {
            var differing = 0
            for y in stride(from: 0, to: sampleHeight, by: 2)
            where abs(luminance(x: x, y: y) - background) > 24 {
                differing += 1
            }
            return differing >= max(3, sampleHeight / 24)
        }

        let top = (0..<sampleHeight).first(where: rowContainsContent) ?? 0
        let bottom = (0..<sampleHeight).reversed().first(where: rowContainsContent) ?? (sampleHeight - 1)
        let left = (0..<sampleWidth).first(where: columnContainsContent) ?? 0
        let right = (0..<sampleWidth).reversed().first(where: columnContainsContent) ?? (sampleWidth - 1)
        let padding: CGFloat = 0.012
        return CGRect(
            x: max(CGFloat(left) / CGFloat(sampleWidth) - padding, 0),
            y: max(CGFloat(top) / CGFloat(sampleHeight) - padding, 0),
            width: min(CGFloat(right - left + 1) / CGFloat(sampleWidth) + padding * 2, 1),
            height: min(CGFloat(bottom - top + 1) / CGFloat(sampleHeight) + padding * 2, 1)
        )
    }

    nonisolated private static func sourceFingerprint(pageURL: URL, image: UIImage) -> String {
        let imageSize = image.cgImage.map { "\($0.width)x\($0.height)" }
            ?? "\(Int(image.size.width))x\(Int(image.size.height))"
        let identity: String
        if pageURL.isFileURL {
            let values = try? pageURL.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey]
            )
            identity = "\(pageURL.path)#\(values?.fileSize ?? 0)#\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)#\(imageSize)"
        } else {
            identity = "\(pageURL.absoluteString)#\(imageSize)"
        }
        return sha256(identity)
    }

    nonisolated private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
