import CryptoKit
import Foundation
import UIKit
@preconcurrency import Vision

nonisolated struct PanelPageLayout: Codable, Sendable, Equatable {
    let panels: [NormalizedRect]
    let contentBounds: NormalizedRect

    var panelRects: [CGRect] { panels.map(\.cgRect) }
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

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

actor PanelDetectionService {
    static let shared = PanelDetectionService()

    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private var memoryCache: [String: PanelPageLayout] = [:]

    init() {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDirectory = root.appendingPathComponent("PanelLayouts", isDirectory: true)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func layout(for pageURL: URL, image: UIImage, isRightToLeft: Bool) async -> PanelPageLayout {
        let key = Self.cacheKey(pageURL: pageURL, isRightToLeft: isRightToLeft)
        if let cached = memoryCache[key] { return cached }
        let diskURL = cacheDirectory.appendingPathComponent(key).appendingPathExtension("json")
        if let data = try? Data(contentsOf: diskURL),
           let cached = try? JSONDecoder().decode(PanelPageLayout.self, from: data) {
            memoryCache[key] = cached
            return cached
        }

        let result = await Task.detached(priority: .userInitiated) {
            Self.detectLayout(in: image, isRightToLeft: isRightToLeft)
        }.value
        memoryCache[key] = result
        if let data = try? JSONEncoder().encode(result) {
            try? data.write(to: diskURL, options: .atomic)
        }
        return result
    }

    func clearCache() {
        memoryCache.removeAll()
        try? fileManager.removeItem(at: cacheDirectory)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    nonisolated static func sortedPanelsForDiagnostics(_ rects: [CGRect], isRightToLeft: Bool) -> [CGRect] {
        sortPanels(rects, isRightToLeft: isRightToLeft)
    }

    nonisolated private static func detectLayout(in image: UIImage, isRightToLeft: Bool) -> PanelPageLayout {
        guard let cgImage = image.cgImage else {
            let full = NormalizedRect(CGRect(x: 0, y: 0, width: 1, height: 1))
            return PanelPageLayout(panels: [full], contentBounds: full)
        }
        let contentBounds = detectedContentBounds(cgImage)
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 30
        request.minimumConfidence = 0.32
        request.minimumSize = 0.08
        request.minimumAspectRatio = 0.08
        request.maximumAspectRatio = 1
        request.quadratureTolerance = 22
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        try? handler.perform([request])

        let candidates = (request.results ?? []).compactMap { observation -> CGRect? in
            let box = observation.boundingBox
            let rect = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            let area = rect.width * rect.height
            guard rect.width > 0.08, rect.height > 0.06, area > 0.015, area < 0.92 else { return nil }
            return rect.insetBy(dx: -0.006, dy: -0.006)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let deduplicated = deduplicate(candidates)
        let sorted = sortPanels(deduplicated, isRightToLeft: isRightToLeft)
        let fallback = contentBounds.width > 0.1 && contentBounds.height > 0.1
            ? contentBounds
            : CGRect(x: 0, y: 0, width: 1, height: 1)
        return PanelPageLayout(
            panels: (sorted.isEmpty ? [fallback] : sorted).map(NormalizedRect.init),
            contentBounds: NormalizedRect(fallback)
        )
    }

    nonisolated private static func sortPanels(_ rects: [CGRect], isRightToLeft: Bool) -> [CGRect] {
        let rowTolerance: CGFloat = 0.08
        return rects.sorted { lhs, rhs in
            if abs(lhs.midY - rhs.midY) > rowTolerance {
                return lhs.midY < rhs.midY
            }
            return isRightToLeft ? lhs.midX > rhs.midX : lhs.midX < rhs.midX
        }
    }

    nonisolated private static func deduplicate(_ rects: [CGRect]) -> [CGRect] {
        var result: [CGRect] = []
        for rect in rects.sorted(by: { $0.width * $0.height > $1.width * $1.height }) {
            let overlaps = result.contains { existing in
                let intersection = existing.intersection(rect)
                guard !intersection.isNull else { return false }
                let intersectionArea = intersection.width * intersection.height
                let smallerArea = min(existing.width * existing.height, rect.width * rect.height)
                return intersectionArea / max(smallerArea, 0.0001) > 0.72
            }
            if !overlaps { result.append(rect) }
        }
        return result
    }

    nonisolated private static func detectedContentBounds(_ image: CGImage) -> CGRect {
        let sampleWidth = 192
        let sampleHeight = max(1, Int(CGFloat(sampleWidth) * CGFloat(image.height) / CGFloat(max(image.width, 1))))
        var pixels = [UInt8](repeating: 0, count: sampleWidth * sampleHeight * 4)
        guard let context = CGContext(
            data: &pixels,
            width: sampleWidth,
            height: sampleHeight,
            bitsPerComponent: 8,
            bytesPerRow: sampleWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))

        func luminance(x: Int, y: Int) -> Int {
            let offset = (y * sampleWidth + x) * 4
            return (Int(pixels[offset]) * 21 + Int(pixels[offset + 1]) * 72 + Int(pixels[offset + 2]) * 7) / 100
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
            for x in stride(from: 0, to: sampleWidth, by: 2) where abs(luminance(x: x, y: y) - background) > 24 {
                differing += 1
            }
            return differing >= max(3, sampleWidth / 24)
        }
        func columnContainsContent(_ x: Int) -> Bool {
            var differing = 0
            for y in stride(from: 0, to: sampleHeight, by: 2) where abs(luminance(x: x, y: y) - background) > 24 {
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

    nonisolated private static func cacheKey(pageURL: URL, isRightToLeft: Bool) -> String {
        let identity: String
        if pageURL.isFileURL {
            let values = try? pageURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            identity = "\(pageURL.path)#\(values?.fileSize ?? 0)#\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        } else {
            identity = pageURL.absoluteString
        }
        let raw = "panel-v1|\(identity)|\(isRightToLeft ? "rtl" : "ltr")"
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
