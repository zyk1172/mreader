import CryptoKit
import Foundation
import UIKit
import os

nonisolated enum PanelDetectionSource: String, Codable, Sendable {
    case coreML
    /// Decode/test compatibility only. Koharu Guided Panel never invokes a Vision fallback detector.
    case visionRectangle
    case fullPageFallback
}

nonisolated struct DetectedPanel: Sendable, Equatable {
    let rect: CGRect
    let confidence: Float
    let source: PanelDetectionSource
    let contour: [CGPoint]?

    init(
        rect: CGRect,
        confidence: Float,
        source: PanelDetectionSource,
        contour: [CGPoint]? = nil
    ) {
        self.rect = rect
        self.confidence = confidence
        self.source = source
        self.contour = contour
    }
}

nonisolated struct PanelLayoutPanel: Codable, Sendable, Equatable {
    let rect: NormalizedRect
    let confidence: Float
    let source: PanelDetectionSource
    let contour: MangaVisionContour?
    /// Legacy content-aware crop retained for cache compatibility. Guided navigation always
    /// centers the actual detected frame so off-center text/balloons cannot pull the camera.
    let semanticFocusRect: NormalizedRect?

    init(
        rect: NormalizedRect,
        confidence: Float,
        source: PanelDetectionSource,
        contour: MangaVisionContour? = nil,
        semanticFocusRect: NormalizedRect? = nil
    ) {
        self.rect = rect
        self.confidence = confidence
        self.source = source
        self.contour = contour
        self.semanticFocusRect = semanticFocusRect
    }
}

nonisolated struct PanelPageLayout: Codable, Sendable, Equatable {
    static let schemaVersion = 6
    static let modelVersion = 8

    let schemaVersion: Int
    let modelVersion: Int
    let detectorIdentifier: String
    let direction: String
    let sourceFingerprint: String
    let panels: [PanelLayoutPanel]
    let contentBounds: NormalizedRect
    let usedFallback: Bool
    var isTransient: Bool = false
    let orderingStrategyRaw: String

    init(
        schemaVersion: Int,
        modelVersion: Int,
        detectorIdentifier: String,
        direction: String,
        sourceFingerprint: String,
        panels: [PanelLayoutPanel],
        contentBounds: NormalizedRect,
        usedFallback: Bool,
        orderingStrategy: PanelReadingOrderStrategy = .strictXYCut
    ) {
        self.schemaVersion = schemaVersion
        self.modelVersion = modelVersion
        self.detectorIdentifier = detectorIdentifier
        self.direction = direction
        self.sourceFingerprint = sourceFingerprint
        self.panels = panels
        self.contentBounds = contentBounds
        self.usedFallback = usedFallback
        self.orderingStrategyRaw = orderingStrategy.rawValue
    }

    var panelRects: [CGRect] { panels.map(\.rect.cgRect) }

    func focusRect(at index: Int) -> CGRect {
        guard panels.indices.contains(index) else { return contentBounds.cgRect }
        return panels[index].rect.cgRect
    }

    var orderingStrategy: PanelReadingOrderStrategy {
        PanelReadingOrderStrategy(rawValue: orderingStrategyRaw) ?? .strictXYCut
    }
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

nonisolated enum PanelPostProcessor {
    private static let minimumDimension: CGFloat = 0.025
    private static let minimumArea: CGFloat = 0.0015
    private static let minimumContentRetention: CGFloat = 0.45
    private static let maximumNavigationPanelCount = 20

    /// Converts the calibrated Koharu frame stream into stable navigation targets.
    ///
    /// The end-to-end head can still emit overlapping or partial frame rows. Guided
    /// Panel is a precision-sensitive consumer, so navigation selection remains separate
    /// from raw model decoding and preserves only structurally useful frame targets.
    static func process(
        _ candidates: [DetectedPanel],
        semanticRegions: [MangaVisionRegion] = [],
        contentBounds: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    ) -> [DetectedPanel] {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let clippedContentBounds = contentBounds.standardized.intersection(unit)
        let pageBounds = !clippedContentBounds.isNull
                && clippedContentBounds.width >= 0.1
                && clippedContentBounds.height >= 0.1
            ? clippedContentBounds
            : unit
        let absoluteThreshold = MangaVisionCalibrationProfile.bundled
            .calibration(for: .panel)
            .confidenceThreshold

        let normalized = candidates.compactMap { panel -> DetectedPanel? in
            guard panel.source == .coreML,
                  panel.confidence >= absoluteThreshold else {
                return nil
            }
            let modelRect = panel.rect.standardized.intersection(unit)
            guard !modelRect.isNull, area(modelRect) > 0 else { return nil }
            let rect = modelRect.intersection(pageBounds)
            let retainedContentFraction = area(rect) / area(modelRect)
            guard !rect.isNull,
                  retainedContentFraction >= minimumContentRetention,
                  rect.width >= minimumDimension,
                  rect.height >= minimumDimension,
                  area(rect) >= minimumArea else {
                return nil
            }
            return DetectedPanel(
                rect: rect,
                confidence: panel.confidence,
                source: .coreML,
                contour: rect == modelRect ? panel.contour : nil
            )
        }
        guard !normalized.isEmpty else { return [] }

        // The Koharu frame class is calibrated down to 0.10 because valid large and
        // low-contrast panels frequently score below 0.14. Do not silently re-raise
        // that operating point relative to the page's highest-scoring frame.
        let scoreFiltered = normalized.filter { $0.confidence >= absoluteThreshold }
        let withoutPeripheralMargins = scoreFiltered.filter { candidate in
            !isLikelyPeripheralMargin(
                candidate,
                contentBounds: pageBounds,
                semanticRegions: semanticRegions
            )
        }
        let withoutSemanticAliases = withoutPeripheralMargins.filter { candidate in
            !isLikelySemanticAlias(candidate, semanticRegions: semanticRegions)
        }

        // Keep real Koharu frame detections authoritative, but do not turn a single
        // missed frame into a whole-page stop. Semantic recovery is allowed only to
        // fill a hole in a page that already has at least one surviving frame, and its
        // evidence rules explicitly reject "one balloon + its own text" as a panel.
        // This restores recall without bringing back generic Vision rectangle fallback.
        let recoveryBase = withoutSemanticAliases.filter { area($0.rect) < 0.78 }
        let recovered = recoverSemanticHoles(
            among: recoveryBase,
            semanticRegions: semanticRegions,
            contentBounds: pageBounds,
            minimumConfidence: absoluteThreshold
        )
        let augmented = withoutSemanticAliases + recovered
        let withoutContainers = augmented.filter { candidate in
            !isLikelyWholePageContainer(candidate, among: augmented)
        }

        var deduplicated: [DetectedPanel] = []
        for candidate in withoutContainers.sorted(by: preferred) {
            if deduplicated.contains(where: { isNavigationDuplicate($0, candidate) }) {
                continue
            }
            deduplicated.append(candidate)
        }

        if deduplicated.count <= maximumNavigationPanelCount {
            return deduplicated
        }
        return Array(
            deduplicated
                .sorted(by: preferred)
                .prefix(maximumNavigationPanelCount)
        )
    }

    private static func isLikelyPeripheralMargin(
        _ candidate: DetectedPanel,
        contentBounds: CGRect,
        semanticRegions: [MangaVisionRegion]
    ) -> Bool {
        let page = contentBounds.standardized
        let rect = candidate.rect.standardized.intersection(page)
        guard !rect.isNull, page.width > 0, page.height > 0 else { return true }

        let widthFraction = rect.width / page.width
        let heightFraction = rect.height / page.height
        let stripLike = (widthFraction <= 0.12 && heightFraction >= 0.45)
            || (heightFraction <= 0.12 && widthFraction >= 0.45)
        guard stripLike else { return false }

        let tolerance = max(min(page.width, page.height) * 0.018, 0.006)
        let touchesEdge = rect.minX <= page.minX + tolerance
            || rect.maxX >= page.maxX - tolerance
            || rect.minY <= page.minY + tolerance
            || rect.maxY >= page.maxY - tolerance
        guard touchesEdge else { return false }

        let hasSemanticEvidence = semanticRegions.contains { region in
            guard region.type != .panel else { return false }
            let threshold = MangaVisionCalibrationProfile.bundled
                .calibration(for: region.type)
                .confidenceThreshold
            guard region.confidence >= threshold else { return false }
            let semantic = region.normalizedRect.standardized
            let semanticArea = area(semantic)
            guard semanticArea > 0 else { return false }
            let overlap = rect.intersection(semantic)
            guard !overlap.isNull else { return false }
            let center = CGPoint(x: semantic.midX, y: semantic.midY)
            return rect.contains(center) || area(overlap) / semanticArea >= 0.55
        }
        return !hasSemanticEvidence
    }

    private static func recoverSemanticHoles(
        among panels: [DetectedPanel],
        semanticRegions: [MangaVisionRegion],
        contentBounds: CGRect,
        minimumConfidence: Float
    ) -> [DetectedPanel] {
        // Do not invent an entire panel layout from semantics alone. Recovery is
        // intentionally limited to filling holes in an otherwise usable frame layout.
        guard !panels.isEmpty else { return [] }

        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let safeBounds = contentBounds.standardized.intersection(unit)
        let pageBounds = (!safeBounds.isNull && safeBounds.width > 0.1 && safeBounds.height > 0.1)
            ? safeBounds
            : unit

        let evidence = semanticRegions.filter { region in
            guard region.type == .text || region.type == .balloon else {
                return false
            }
            let threshold = MangaVisionCalibrationProfile.bundled
                .calibration(for: region.type)
                .confidenceThreshold
            guard region.confidence >= threshold else { return false }
            let rect = region.normalizedRect.standardized.intersection(pageBounds)
            return !rect.isNull
                && rect.width >= 0.004
                && rect.height >= 0.004
                && area(rect) >= 0.000_04
                && !panels.contains { semanticRectIsCovered(rect, by: $0.rect) }
        }
        guard !evidence.isEmpty else { return [] }

        var clusters: [[MangaVisionRegion]] = []
        for region in evidence.sorted(by: semanticPreferred) {
            if let index = clusters.firstIndex(where: {
                semanticCluster($0, accepts: region)
            }) {
                clusters[index].append(region)
            } else {
                clusters.append([region])
            }
        }

        return clusters.compactMap { cluster in
            let hasText = cluster.contains { $0.type == .text }
            let hasBalloon = cluster.contains { $0.type == .balloon }
            guard hasText else { return nil }

            let clusterBalloons = cluster.filter { $0.type == .balloon }
            if hasBalloon {
                let hasContentOutsideBalloon = cluster.contains { region in
                    guard region.type == .text else { return false }
                    let center = CGPoint(
                        x: region.normalizedRect.midX,
                        y: region.normalizedRect.midY
                    )
                    return !clusterBalloons.contains { balloon in
                        balloon.normalizedRect.standardized
                            .insetBy(dx: -0.012, dy: -0.012)
                            .contains(center)
                    }
                }
                let hasSeparateBalloon = clusterBalloons.indices.contains { firstIndex in
                    clusterBalloons.indices.contains { secondIndex in
                        guard secondIndex > firstIndex else { return false }
                        let first = clusterBalloons[firstIndex].normalizedRect.standardized
                        let second = clusterBalloons[secondIndex].normalizedRect.standardized
                        let overlap = first.intersection(second)
                        let overlapFraction = overlap.isNull
                            ? 0
                            : area(overlap) / max(min(area(first), area(second)), 0.000_001)
                        return overlapFraction < 0.50
                            && hypot(first.midX - second.midX, first.midY - second.midY) > 0.04
                    }
                }
                // A cluster made only from one balloon and text inside it is dialogue,
                // not enough evidence to synthesize a navigation panel.
                guard hasContentOutsideBalloon || hasSeparateBalloon else { return nil }
            }

            let evidenceScore = cluster.reduce(CGFloat.zero) { partial, region in
                let weight: CGFloat
                switch region.type {
                case .text: weight = 1.0
                case .balloon: weight = 0.75
                case .onomatopoeia: weight = 0
                case .panel: weight = 0
                }
                return partial + CGFloat(region.confidence) * weight
            }
            let corroboratedDialogue = hasText && hasBalloon
            guard corroboratedDialogue || evidenceScore >= 1.05 else { return nil }

            let semanticBounds = cluster
                .map { $0.normalizedRect.standardized }
                .dropFirst()
                .reduce(cluster[0].normalizedRect.standardized) { $0.union($1) }
                .intersection(pageBounds)
            guard !semanticBounds.isNull,
                  semanticBounds.width > 0,
                  semanticBounds.height > 0 else {
                return nil
            }

            // The recovered box is deliberately contextual rather than a tight
            // text/balloon crop. Guided Panel itself no longer adds frame padding.
            let dx = max(semanticBounds.width * 0.55, 0.040)
            let dy = max(semanticBounds.height * 0.55, 0.040)
            let recoveredRect = semanticBounds
                .insetBy(dx: -dx, dy: -dy)
                .intersection(pageBounds)
            let recoveredArea = area(recoveredRect)
            guard !recoveredRect.isNull,
                  recoveredRect.width >= 0.08,
                  recoveredRect.height >= 0.08,
                  recoveredArea >= 0.012,
                  recoveredArea <= 0.48,
                  recoveredArea >= area(semanticBounds) * 1.35 else {
                return nil
            }

            // Never create a second stop that substantially covers an existing frame.
            let maximumExistingCoverage = panels.reduce(CGFloat.zero) { current, panel in
                let overlap = recoveredRect.intersection(panel.rect)
                guard !overlap.isNull else { return current }
                return max(current, area(overlap) / max(recoveredArea, 0.000_001))
            }
            guard maximumExistingCoverage < 0.34 else { return nil }

            let strongest = cluster.map(\.confidence).max() ?? minimumConfidence
            let confidence = max(
                minimumConfidence,
                min(strongest * 0.95, 0.90)
            )
            return DetectedPanel(
                rect: recoveredRect,
                confidence: confidence,
                source: .coreML
            )
        }
    }

    private static func semanticRectIsCovered(
        _ semanticRect: CGRect,
        by panelRect: CGRect
    ) -> Bool {
        let intersection = semanticRect.intersection(panelRect)
        guard !intersection.isNull else { return false }
        let semanticArea = area(semanticRect)
        guard semanticArea > 0 else { return false }
        let containment = area(intersection) / semanticArea
        let center = CGPoint(x: semanticRect.midX, y: semanticRect.midY)
        return containment >= 0.62
            || (panelRect.insetBy(dx: -0.004, dy: -0.004).contains(center)
                && containment >= 0.45)
    }

    private static func semanticCluster(
        _ cluster: [MangaVisionRegion],
        accepts region: MangaVisionRegion
    ) -> Bool {
        guard let first = cluster.first else { return true }
        let bounds = cluster.dropFirst().reduce(first.normalizedRect.standardized) {
            $0.union($1.normalizedRect.standardized)
        }
        let rect = region.normalizedRect.standardized
        let xOverlap = max(
            min(bounds.maxX, rect.maxX) - max(bounds.minX, rect.minX),
            0
        ) / max(min(bounds.width, rect.width), 0.000_001)
        let yOverlap = max(
            min(bounds.maxY, rect.maxY) - max(bounds.minY, rect.minY),
            0
        ) / max(min(bounds.height, rect.height), 0.000_001)
        let horizontalGap = max(
            max(bounds.minX - rect.maxX, rect.minX - bounds.maxX),
            0
        )
        let verticalGap = max(
            max(bounds.minY - rect.maxY, rect.minY - bounds.maxY),
            0
        )

        if xOverlap >= 0.20 && verticalGap <= 0.055 { return true }
        if yOverlap >= 0.20 && horizontalGap <= 0.055 { return true }

        let centerDistance = hypot(bounds.midX - rect.midX, bounds.midY - rect.midY)
        let merged = bounds.union(rect)
        return centerDistance <= 0.09 && area(merged) <= 0.16
    }

    private static func semanticPreferred(
        _ lhs: MangaVisionRegion,
        _ rhs: MangaVisionRegion
    ) -> Bool {
        if lhs.normalizedRect.minY != rhs.normalizedRect.minY {
            return lhs.normalizedRect.minY < rhs.normalizedRect.minY
        }
        if lhs.normalizedRect.minX != rhs.normalizedRect.minX {
            return lhs.normalizedRect.minX < rhs.normalizedRect.minX
        }
        return lhs.confidence > rhs.confidence
    }

    /// Panel rejects only near-identical frame/semantic aliases here while preserving
    /// normal balloons and text that are contained inside a genuine frame.
    private static func isLikelySemanticAlias(
        _ candidate: DetectedPanel,
        semanticRegions: [MangaVisionRegion]
    ) -> Bool {
        let frameRect = candidate.rect.standardized
        let frameArea = area(frameRect)
        guard frameArea > 0 else { return false }

        return semanticRegions.contains { region in
            guard region.type == .balloon
                    || region.type == .text
                    || region.type == .onomatopoeia else {
                return false
            }
            let calibration = MangaVisionCalibrationProfile.bundled.calibration(for: region.type)
            guard region.confidence >= calibration.confidenceThreshold else {
                return false
            }

            let semanticRect = region.normalizedRect.standardized
            let semanticArea = area(semanticRect)
            guard semanticArea > 0 else { return false }
            let intersection = frameRect.intersection(semanticRect)
            guard !intersection.isNull else { return false }

            let intersectionArea = area(intersection)
            let unionArea = max(frameArea + semanticArea - intersectionArea, 0.000_001)
            let iou = intersectionArea / unionArea
            let smallerArea = max(min(frameArea, semanticArea), 0.000_001)
            let containment = intersectionArea / smallerArea
            let sizeRatio = smallerArea / max(frameArea, semanticArea)
            let semanticToFrameScore = CGFloat(region.confidence)
                / max(CGFloat(candidate.confidence), 0.000_1)

            switch region.type {
            case .balloon:
                // A panel commonly contains one large balloon and may have no other
                // text/SFX detections. Only remove a frame candidate when its box is
                // nearly the same object as the balloon; treating ordinary containment
                // as an alias drops real dialogue panels, especially in dense lower rows.
                // Balloons can legitimately cross or dominate a small panel. Reject the
                // frame only when both detections are effectively describing the same
                // object, not merely because a large balloon overlaps the panel.
                let balloonIsNearIdentical =
                    (iou >= 0.72 && containment >= 0.95 && sizeRatio >= 0.68)
                    || (containment >= 0.985 && sizeRatio >= 0.82)
                let balloonDominatesFrame = balloonIsNearIdentical
                    && semanticToFrameScore >= 0.95
                return balloonDominatesFrame
                    && !hasIndependentSemanticSupport(
                        inside: frameRect,
                        excluding: semanticRect,
                        semanticRegions: semanticRegions
                    )
            case .text, .onomatopoeia:
                // Text boxes can legitimately occupy a large fraction of a small frame,
                // so use a stricter near-identity gate for these classes.
                return (iou >= 0.66 || (containment >= 0.97 && sizeRatio >= 0.84))
                    && semanticToFrameScore >= 1.00
            case .panel:
                return false
            }
        }
    }

    private static func hasIndependentSemanticSupport(
        inside frameRect: CGRect,
        excluding matchedBalloonRect: CGRect,
        semanticRegions: [MangaVisionRegion]
    ) -> Bool {
        let expandedBalloonRect = matchedBalloonRect.insetBy(dx: -0.012, dy: -0.012)
        return semanticRegions.contains { region in
            guard region.type == .balloon
                    || region.type == .text
                    || region.type == .onomatopoeia else {
                return false
            }
            let threshold = MangaVisionCalibrationProfile.bundled
                .calibration(for: region.type)
                .confidenceThreshold
            guard region.confidence >= threshold else { return false }

            let semanticRect = region.normalizedRect.standardized
            let semanticArea = area(semanticRect)
            guard semanticArea > 0 else { return false }
            let inFrame = semanticRect.intersection(frameRect)
            guard !inFrame.isNull,
                  area(inFrame) / semanticArea >= 0.50 else {
                return false
            }

            let matchedOverlap = semanticRect.intersection(matchedBalloonRect)
            let matchedCoverage = matchedOverlap.isNull
                ? 0
                : area(matchedOverlap) / semanticArea
            let center = CGPoint(x: semanticRect.midX, y: semanticRect.midY)
            return matchedCoverage < 0.50 && !expandedBalloonRect.contains(center)
        }
    }

    private static func isLikelyWholePageContainer(
        _ candidate: DetectedPanel,
        among panels: [DetectedPanel]
    ) -> Bool {
        let candidateArea = area(candidate.rect)
        guard candidateArea >= 0.78 else { return false }

        let children = panels.filter { other in
            guard other != candidate else { return false }
            let center = CGPoint(x: other.rect.midX, y: other.rect.midY)
            return candidate.rect.contains(center)
                && area(other.rect) <= candidateArea * 0.60
        }
        let requiredChildren = candidateArea >= 0.90 ? 2 : 3
        guard children.count >= requiredChildren else { return false }

        let childArea = children.reduce(CGFloat.zero) { $0 + area($1.rect) }
        guard childArea >= 0.20 else { return false }
        let strongestChild = children.map(\.confidence).max() ?? 0
        return candidateArea >= 0.90
            || candidate.confidence <= strongestChild * 1.25
    }

    private static func isNavigationDuplicate(
        _ lhs: DetectedPanel,
        _ rhs: DetectedPanel
    ) -> Bool {
        let intersection = lhs.rect.intersection(rhs.rect)
        guard !intersection.isNull else { return false }
        let intersectionArea = area(intersection)
        let lhsArea = area(lhs.rect)
        let rhsArea = area(rhs.rect)
        let union = max(lhsArea + rhsArea - intersectionArea, 0.000_001)
        let iou = intersectionArea / union
        let smaller = min(lhsArea, rhsArea)
        let larger = max(lhsArea, rhsArea)
        let containment = intersectionArea / max(smaller, 0.000_001)
        let sizeRatio = smaller / max(larger, 0.000_001)

        // Preserve genuine inset panels. Only collapse boxes that describe
        // essentially the same frame geometry.
        return iou >= 0.75 || (containment >= 0.96 && sizeRatio >= 0.82)
    }

    private static func preferred(_ lhs: DetectedPanel, _ rhs: DetectedPanel) -> Bool {
        if lhs.confidence != rhs.confidence {
            return lhs.confidence > rhs.confidence
        }
        return area(lhs.rect) > area(rhs.rect)
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        max(rect.width, 0) * max(rect.height, 0)
    }
}

nonisolated enum PanelLayoutQuality {
    static func isUsable(_ panels: [DetectedPanel]) -> Bool {
        let threshold = MangaVisionCalibrationProfile.bundled
            .calibration(for: .panel)
            .confidenceThreshold
        return !panels.isEmpty && panels.allSatisfy { panel in
            panel.source == .coreML
                && panel.confidence >= threshold
                && panel.rect.width > 0
                && panel.rect.height > 0
        }
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
    private let visionService: MangaVisionService
    private var memoryCache: [String: PanelPageLayout] = [:]
    private var memoryOrder: [String] = []
    private var generation = UUID()
    private var activeReaderSessionID: UUID?
    private var diskWritesSincePrune = 0
    private var lastDiskPruneAt = Date.distantPast

    init(
        visionService: MangaVisionService = .shared
    ) {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDirectory = root.appendingPathComponent("PanelLayouts", isDirectory: true)
        self.visionService = visionService
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    /// Compatibility entry point used by the existing GuidedPanelReader.
    /// New call sites should prefer the comicID/pageIndex overload so the cache is easy to inspect.
    func layout(
        for pageURL: URL,
        image: UIImage,
        isRightToLeft: Bool,
        requestClass: MangaVisionRequestClass = .currentTask
    ) async -> PanelPageLayout {
        let scopeSource = pageURL.deletingLastPathComponent().absoluteString
        let identity = CacheIdentity(
            scope: "legacy-\(Self.sha256(scopeSource))",
            pageComponent: Self.sha256(pageURL.absoluteString)
        )
        return await layout(
            cacheIdentity: identity,
            comicID: nil,
            pageIndex: nil,
            pageURL: pageURL,
            image: image,
            isRightToLeft: isRightToLeft,
            requestClass: requestClass
        )
    }

    /// Preferred cache shape: Library/Caches/PanelLayouts/<comicUUID>/<0001>.json.
    func layout(
        comicID: UUID,
        pageIndex: Int,
        pageURL: URL,
        image: UIImage,
        isRightToLeft: Bool,
        requestClass: MangaVisionRequestClass = .currentTask
    ) async -> PanelPageLayout {
        let identity = CacheIdentity(
            scope: comicID.uuidString.lowercased(),
            pageComponent: String(format: "%04d", max(pageIndex, 0) + 1)
        )
        return await layout(
            cacheIdentity: identity,
            comicID: comicID,
            pageIndex: pageIndex,
            pageURL: pageURL,
            image: image,
            isRightToLeft: isRightToLeft,
            requestClass: requestClass
        )
    }

    func beginReaderSession(sessionID: UUID) async {
        guard await ReaderSessionRegistry.shared.isActive(sessionID) else { return }
        activeReaderSessionID = sessionID
    }

    func releaseReaderSessionMemory(sessionID: UUID? = nil) {
        if let sessionID {
            guard activeReaderSessionID == sessionID else { return }
        }
        activeReaderSessionID = nil
        // Layouts are cheap to restore from disk. Advancing generation prevents an
        // in-flight Guided Panel calculation from repopulating memory after Reader exit.
        generation = UUID()
        memoryOrder.removeAll()
        memoryCache.removeAll()
    }

    func clearCache() {
        generation = UUID()
        memoryOrder.removeAll()
        memoryCache.removeAll()
        diskWritesSincePrune = 0
        lastDiskPruneAt = .distantPast
        try? fileManager.removeItem(at: cacheDirectory)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    nonisolated static func sortedPanelsForDiagnostics(
        _ rects: [CGRect],
        isRightToLeft: Bool
    ) -> [CGRect] {
        let candidates = rects.map {
            DetectedPanel(rect: $0, confidence: 1, source: .coreML)
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
        comicID: UUID?,
        pageIndex: Int?,
        pageURL: URL,
        image: UIImage,
        isRightToLeft: Bool,
        requestClass: MangaVisionRequestClass
    ) async -> PanelPageLayout {
        let epoch = generation
        let direction = isRightToLeft ? "rightToLeft" : "leftToRight"
        let sourceFingerprint = Self.sourceFingerprint(pageURL: pageURL, image: image)

        // Panel-layout cache hits must remain cheaper than Manga Vision inference.
        // Derive the dependency that an analysis started now would request without
        // touching the model, then only run analysis after both layout caches miss.
        let expectedDependency = await visionService.expectedDependencyIdentity(
            image: image,
            requestClass: requestClass
        )
        var primaryIdentifier = "manga-vision:\(expectedDependency)"
        var memoryKey = "\(cacheIdentity.scope)|\(cacheIdentity.pageComponent)|\(direction)|\(primaryIdentifier)|\(sourceFingerprint)"
        if let cached = memoryCache[memoryKey] {
            return cached
        }

        let diskURL = cacheURL(for: cacheIdentity)
        if let data = try? Data(contentsOf: diskURL),
           let cached = try? JSONDecoder().decode(PanelPageLayout.self, from: data),
           Self.isCacheValid(
                cached,
                direction: direction,
                validDetectorIdentifiers: Set([primaryIdentifier]),
                sourceFingerprint: sourceFingerprint
           ) {
            remember(cached, key: memoryKey)
            return cached
        }

        guard let analysisImage = Self.analysisCGImage(from: image, maximumDimension: 640) else {
            let fallback = Self.fullPageLayout(
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                direction: direction,
                sourceFingerprint: sourceFingerprint,
                detectorIdentifier: primaryIdentifier
            )
            var temporary = fallback
            temporary.isTransient = true
            return temporary
        }

        // Reuse analysis already warmed for the same demand before starting
        // new Core ML work. Interactive navigation may also consume a completed
        // prefetch analysis: Guided Panel needs stable panel geometry immediately,
        // and a later interactive analysis can still refresh richer semantic caches.
        var mangaAnalysis = await visionService.cachedAnalysis(
            comicID: comicID,
            pageIndex: pageIndex,
            pageURL: pageURL,
            image: image,
            requestClass: requestClass
        )
        if mangaAnalysis == nil, requestClass == .interactive {
            mangaAnalysis = await visionService.cachedAnalysis(
                comicID: comicID,
                pageIndex: pageIndex,
                pageURL: pageURL,
                image: image,
                requestClass: .prefetch
            )
        }
        if mangaAnalysis == nil {
            do {
                mangaAnalysis = try await visionService.analysis(
                    comicID: comicID,
                    pageIndex: pageIndex,
                    pageURL: pageURL,
                    image: image,
                    requestClass: requestClass
                )
            } catch {
                MReaderLog.aiVision.error(
                    "Guided Panel Koharu YOLO26s analysis failed page=\(pageIndex ?? -1, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
        guard epoch == generation, !Task.isCancelled else {
            var temporary = Self.fullPageLayout(
                bounds: Self.detectedContentBounds(analysisImage),
                direction: direction,
                sourceFingerprint: sourceFingerprint,
                detectorIdentifier: primaryIdentifier
            )
            temporary.isTransient = true
            return temporary
        }

        // Resource state may have changed after the model-free lookup. If the
        // actual analysis used a different demand, switch identities and honor
        // a layout cached under that exact dependency before recomputing it.
        let actualDependency = await visionService.dependencyIdentity(for: mangaAnalysis)
        if actualDependency != expectedDependency {
            primaryIdentifier = "manga-vision:\(actualDependency)"
            memoryKey = "\(cacheIdentity.scope)|\(cacheIdentity.pageComponent)|\(direction)|\(primaryIdentifier)|\(sourceFingerprint)"
            if let cached = memoryCache[memoryKey] {
                return cached
            }
            if let data = try? Data(contentsOf: diskURL),
               let cached = try? JSONDecoder().decode(PanelPageLayout.self, from: data),
               Self.isCacheValid(
                    cached,
                    direction: direction,
                    validDetectorIdentifiers: Set([primaryIdentifier]),
                    sourceFingerprint: sourceFingerprint
               ) {
                remember(cached, key: memoryKey)
                return cached
            }
        }

        let contentBounds = Self.detectedContentBounds(analysisImage)
        let primaryPanels = (mangaAnalysis?.panels ?? []).map {
            DetectedPanel(
                rect: $0.normalizedRect,
                confidence: $0.confidence,
                source: .coreML,
                contour: $0.contour?.cgPoints
            )
        }
        let processed = PanelPostProcessor.process(
            primaryPanels,
            semanticRegions: (mangaAnalysis?.balloons ?? [])
                + (mangaAnalysis?.texts ?? [])
                + (mangaAnalysis?.onomatopoeias ?? []),
            contentBounds: contentBounds
        )
        let detectorIdentifier = primaryIdentifier

        if let mangaAnalysis, processed.isEmpty {
            MReaderLog.aiVision.error(
                "Guided Panel Koharu YOLO26s returned zero frames page=\(pageIndex ?? -1, privacy: .public) model=\(mangaAnalysis.modelIdentifier ?? "unknown", privacy: .public)"
            )
        }

        // This Koharu integration branch must expose model failures directly.
        // Do not substitute Vision rectangle detection when Koharu frame output is unusable.

        var result: PanelPageLayout
        if PanelLayoutQuality.isUsable(processed) {
            let structure = MangaPageStructureGraph(
                panels: processed,
                analysis: mangaAnalysis,
                isRightToLeft: isRightToLeft
            )
            let readingPlan = PanelReadingOrder.plan(
                processed,
                isRightToLeft: isRightToLeft,
                structure: structure
            )
            result = PanelPageLayout(
                schemaVersion: PanelPageLayout.schemaVersion,
                modelVersion: PanelPageLayout.modelVersion,
                detectorIdentifier: detectorIdentifier,
                direction: direction,
                sourceFingerprint: sourceFingerprint,
                panels: readingPlan.panels.enumerated().map { index, panel in
                    PanelLayoutPanel(
                        rect: NormalizedRect(panel.rect),
                        confidence: panel.confidence,
                        source: panel.source,
                        contour: panel.contour.map { MangaVisionContour(points: $0) },
                        semanticFocusRect: nil
                    )
                },
                contentBounds: NormalizedRect(contentBounds),
                usedFallback: false,
                orderingStrategy: readingPlan.strategy
            )
        } else {
            result = Self.fullPageLayout(
                bounds: contentBounds,
                direction: direction,
                sourceFingerprint: sourceFingerprint,
                detectorIdentifier: detectorIdentifier
            )
        }

        result.isTransient = mangaAnalysis == nil || result.usedFallback
        if !result.isTransient, !Task.isCancelled, generation == epoch {
            store(result, memoryKey: memoryKey, diskURL: diskURL)
        }
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
        remember(layout, key: memoryKey)
        guard let data = try? JSONEncoder().encode(layout) else { return }
        do {
            try data.write(to: diskURL, options: .atomic)
        } catch {
            return
        }

        // Directory enumeration is O(number of cached pages). Do not put that
        // scan on every sequential Guided Panel write; reconcile periodically.
        diskWritesSincePrune += 1
        let now = Date()
        if diskWritesSincePrune >= 32 || now.timeIntervalSince(lastDiskPruneAt) >= 15 * 60 {
            pruneDiskCache()
            diskWritesSincePrune = 0
            lastDiskPruneAt = now
        }
    }

    private func remember(_ layout: PanelPageLayout, key: String) {
        memoryCache[key] = layout
        memoryOrder.removeAll { $0 == key }
        memoryOrder.append(key)
        while memoryOrder.count > 96 { memoryCache[memoryOrder.removeFirst()] = nil }
    }

    private func pruneDiskCache() {
        guard let urls = fileManager.enumerator(at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        let files = urls.compactMap { $0 as? URL }.filter { $0.pathExtension == "json" }.map { url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return (url, values?.fileSize ?? 0, values?.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var total = files.reduce(0) { $0 + $1.1 }
        for (url, bytes, _) in files where total > 24 * 1024 * 1024 {
            if (try? fileManager.removeItem(at: url)) != nil { total -= bytes }
        }
    }

    nonisolated private static func isCacheValid(
        _ layout: PanelPageLayout,
        direction: String,
        validDetectorIdentifiers: Set<String>,
        sourceFingerprint: String
    ) -> Bool {
        !layout.isTransient
            && layout.schemaVersion == PanelPageLayout.schemaVersion
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
            usedFallback: true,
            orderingStrategy: .fullPageFallback
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
        PageContentIdentityResolver.identity(for: pageURL).fingerprint
    }

    nonisolated private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
