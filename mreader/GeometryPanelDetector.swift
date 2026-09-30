import CoreGraphics
import Foundation

/// Geometry-first panel extraction for ordinary comic pages.
///
/// This detector deliberately does not try to understand characters, text or balloons.
/// It looks for the thing that actually defines most printed panels: page-spanning gutters.
/// A recursive XY-cut turns those negative-space separators into a page layout tree. The
/// learned Manga Vision frame detector remains useful later as a residual detector for
/// borderless/inset/irregular cases, but it is no longer the sole authority for navigation.
nonisolated struct GeometryPanelDetector: PanelDetecting {
    let identifier = "page-geometry-xycut-v2"

    private let maximumDimension: Int

    init(maximumDimension: Int = 1_024) {
        self.maximumDimension = max(maximumDimension, 320)
    }

    func detectPanels(in image: CGImage) throws -> [DetectedPanel] {
        guard let raster = PanelGeometryRaster(
            image: image,
            maximumDimension: maximumDimension
        ) else {
            return []
        }

        let analyzer = PanelGeometryAnalyzer(raster: raster)
        return analyzer.detectPanels()
    }
}

/// Chooses navigation geometry from two independent evidence sources.
///
/// Priority is intentionally asymmetric:
/// 1. page geometry owns conventional gutter-separated layouts;
/// 2. model frames may split an under-segmented geometric leaf or fill a real hole;
/// 3. the model owns the page only when geometry has no credible structure;
/// 4. if neither source is credible, deterministic virtual panels replace speculative boxes.
nonisolated enum PanelCandidateFusion {
    static let revision = "geometry-first-fusion-v12"

    struct Resolution: Sendable {
        let panels: [DetectedPanel]
        let usedVirtualFallback: Bool
        let reason: String
    }

    static func resolve(
        geometry: [DetectedPanel],
        model: [DetectedPanel],
        contentBounds: CGRect,
        imageAspectRatio: CGFloat,
        balloonRegions: [CGRect] = [],
        textRegions: [CGRect] = []
    ) -> Resolution {
        // Content bounds are useful for fallback viewport planning and for deciding
        // whether a learned box looks like a page container. They are not precise enough
        // to rewrite real detector geometry. Preserve frame boundaries exactly here.
        let geometryPanels = PanelPostProcessor.process(geometry)
        let modelPanels = suppressLikelyPageContainers(
            PanelPostProcessor.process(
                model.filter {
                    !isSemanticAlias(
                        $0,
                        balloons: balloonRegions,
                        texts: textRegions
                    )
                }
            ),
            contentBounds: contentBounds
        )

        let geometryUsable = isGeometryAuthoritative(geometryPanels)
        let modelUsable = PanelLayoutQuality.isUsable(modelPanels)

        if geometryUsable {
            let refined = PanelPostProcessor.process(
                refineGeometryLeaves(geometryPanels, with: modelPanels)
            )
            if PanelLayoutQuality.isUsable(refined) {
                return Resolution(
                    panels: refined,
                    usedVirtualFallback: false,
                    reason: "geometry-primary"
                )
            }
            return Resolution(
                panels: geometryPanels,
                usedVirtualFallback: false,
                reason: "geometry-primary-unrefined"
            )
        }

        // A single learned frame is the most dangerous failure mode: on a dense
        // page it can simply be the whole page. Never let one uncorroborated model box
        // become Guided Panel's sole navigation target.
        if modelPanels.count >= 2, modelUsable {
            return Resolution(
                panels: modelPanels,
                usedVirtualFallback: false,
                reason: "model-residual"
            )
        }

        if let corroboratedSingle = corroboratedSinglePanel(
            geometry: geometryPanels,
            model: modelPanels,
            balloonRegions: balloonRegions,
            textRegions: textRegions
        ) {
            return Resolution(
                panels: [corroboratedSingle],
                usedVirtualFallback: false,
                reason: "corroborated-single-panel"
            )
        }

        let combined = PanelPostProcessor.process(geometryPanels + modelPanels)
        if combined.count >= 2,
           !hasUnsupportedCrossSourceContainment(combined),
           PanelLayoutQuality.isUsable(combined) {
            return Resolution(
                panels: combined,
                usedVirtualFallback: false,
                reason: "combined-recovery"
            )
        }

        let virtual = VirtualPanelPlanner.panels(
            in: contentBounds,
            imageAspectRatio: imageAspectRatio
        )
        return Resolution(
            panels: virtual,
            usedVirtualFallback: !virtual.isEmpty,
            reason: virtual.isEmpty ? "no-layout" : "virtual-panel-fallback"
        )
    }

    /// A near-page-sized learned frame that merely contains more specific frame
    /// detections is usually the detector collapsing page structure into one container.
    /// Keep genuine large panels when they stand alone; suppress only the container when
    /// a substantially smaller child provides competing structural evidence.
    private static func suppressLikelyPageContainers(
        _ panels: [DetectedPanel],
        contentBounds: CGRect
    ) -> [DetectedPanel] {
        guard panels.count >= 2 else { return panels }

        let contentArea = max(area(contentBounds.standardized), 0.25)
        return panels.filter { candidate in
            let candidateArea = area(candidate.rect)
            let coverageOfContent = containment(
                of: contentBounds.standardized,
                in: candidate.rect
            )
            guard candidate.source == .coreML,
                  candidateArea >= contentArea * 0.78,
                  coverageOfContent >= 0.82 else {
                return true
            }

            let specificChildCount = panels.filter { other in
                guard other != candidate else { return false }
                let otherArea = area(other.rect)
                guard otherArea >= 0.018,
                      otherArea <= candidateArea * 0.58 else {
                    return false
                }
                return containment(of: other.rect, in: candidate.rect) >= 0.88
            }.count

            // One small child can be a legitimate inset over a full-bleed panel.
            // Two or more specific children are much stronger evidence that the large
            // detection is merely a page/container collapse.
            return specificChildCount < 2
        }
    }

    /// Learned frame predictions that are geometrically almost identical to a speech
    /// balloon are not navigation panels. Text is intentionally only a weak secondary
    /// signal because real panels normally contain text.
    private static func isSemanticAlias(
        _ panel: DetectedPanel,
        balloons: [CGRect],
        texts: [CGRect]
    ) -> Bool {
        guard panel.source == .coreML else { return false }
        let panelArea = area(panel.rect)
        guard panelArea > 0 else { return true }

        for balloon in balloons {
            let balloonArea = area(balloon)
            guard balloonArea > 0 else { continue }
            let iou = intersectionOverUnion(panel.rect, balloon)
            let panelInsideBalloon = containment(of: panel.rect, in: balloon)
            let balloonInsidePanel = containment(of: balloon, in: panel.rect)
            let sizeRatio = min(panelArea, balloonArea) / max(panelArea, balloonArea)

            if iou >= 0.62
                || (panelInsideBalloon >= 0.88 && sizeRatio >= 0.58)
                || (balloonInsidePanel >= 0.92 && sizeRatio >= 0.72) {
                return true
            }
        }

        guard panelArea <= 0.10 else { return false }
        let tightlyMatchingText = texts.contains { text in
            intersectionOverUnion(panel.rect, text) >= 0.68
                || (
                    containment(of: text, in: panel.rect) >= 0.90
                    && area(text) / panelArea >= 0.60
                )
        }
        return tightlyMatchingText
    }

    static func isGeometryAuthoritative(_ panels: [DetectedPanel]) -> Bool {
        guard panels.count >= 2,
              PanelLayoutQuality.isUsable(panels) else {
            return false
        }
        let average = panels.reduce(Float.zero) { $0 + $1.confidence }
            / Float(max(panels.count, 1))
        return average >= 0.62
    }

    /// A learned detector is allowed to split one coarse geometry leaf only when several
    /// mutually compatible frame detections agree that the leaf contains real sub-panels.
    /// This is the residual-detector role: the model fills a structural hole instead of
    /// replacing a good page layout wholesale.
    private static func refineGeometryLeaves(
        _ geometry: [DetectedPanel],
        with model: [DetectedPanel]
    ) -> [DetectedPanel] {
        guard !model.isEmpty else { return geometry }

        var result: [DetectedPanel] = []
        var consumedModelIDs = Set<Int>()

        for geometric in geometry {
            let geometricArea = area(geometric.rect)
            let nested = model.enumerated().compactMap { index, candidate -> (Int, DetectedPanel)? in
                let candidateArea = area(candidate.rect)
                guard candidate.confidence >= 0.48,
                      candidateArea >= 0.012,
                      candidateArea <= geometricArea * 0.78,
                      containment(of: candidate.rect, in: geometric.rect) >= 0.80 else {
                    return nil
                }
                return (index, candidate)
            }

            let nestedPanels = nested.map(\.1)
            if nestedPanels.count >= 2,
               modelGroupCanSplit(geometric, into: nestedPanels) {
                result.append(contentsOf: nestedPanels)
                nested.forEach { consumedModelIDs.insert($0.0) }
            } else {
                result.append(geometric)
            }
        }

        // A high-confidence model frame may fill a region geometry did not cover at
        // all, or represent a genuine inset panel inside one larger background panel.
        // Near-duplicate containers remain rejected; a single inset is admitted only
        // with stronger model confidence and a clearly smaller footprint.
        for (index, candidate) in model.enumerated() where !consumedModelIDs.contains(index) {
            let candidateArea = area(candidate.rect)
            guard candidate.confidence >= 0.62,
                  candidateArea >= 0.018 else {
                continue
            }

            var shouldAppend = true
            for existing in result {
                let existingArea = max(area(existing.rect), 0.000_001)
                let candidateInsideExisting = containment(
                    of: candidate.rect,
                    in: existing.rect
                )
                let existingInsideCandidate = containment(
                    of: existing.rect,
                    in: candidate.rect
                )
                let iou = intersectionOverUnion(candidate.rect, existing.rect)
                let sizeRatio = candidateArea / existingArea

                if candidateInsideExisting >= 0.90 {
                    let credibleInset = candidate.confidence >= 0.74
                        && sizeRatio >= 0.06
                        && sizeRatio <= 0.45
                    if credibleInset {
                        continue
                    }
                    shouldAppend = false
                    break
                }

                if existingInsideCandidate >= 0.70 || iou >= 0.45 {
                    shouldAppend = false
                    break
                }
            }

            if shouldAppend {
                result.append(candidate)
            }
        }

        return result
    }

    private static func modelGroupCanSplit(
        _ geometric: DetectedPanel,
        into candidates: [DetectedPanel]
    ) -> Bool {
        let geometricArea = max(area(geometric.rect), 0.000_001)
        let actualCoverage = min(
            1,
            candidates.reduce(CGFloat.zero) { partial, candidate in
                let intersection = candidate.rect.intersection(geometric.rect)
                return partial + (intersection.isNull ? 0 : area(intersection))
            } / geometricArea
        )
        // Replacing a geometry leaf discards that leaf completely, so residual
        // model frames must explain most of its visible area. A low threshold lets two
        // small false positives erase the majority of an otherwise valid panel.
        guard actualCoverage >= 0.52 else { return false }

        let centersX = candidates.map { $0.rect.midX }
        let centersY = candidates.map { $0.rect.midY }
        let xSpread = (centersX.max() ?? 0) - (centersX.min() ?? 0)
        let ySpread = (centersY.max() ?? 0) - (centersY.min() ?? 0)
        guard xSpread >= geometric.rect.width * 0.16
                || ySpread >= geometric.rect.height * 0.16 else {
            return false
        }

        var excessiveOverlap = 0
        for i in candidates.indices {
            for j in candidates.indices where j > i {
                let overlap = containment(
                    of: candidates[i].rect,
                    in: candidates[j].rect
                )
                let reverse = containment(
                    of: candidates[j].rect,
                    in: candidates[i].rect
                )
                if max(overlap, reverse) > 0.55 {
                    excessiveOverlap += 1
                }
            }
        }
        return excessiveOverlap == 0
    }

    private static func corroboratedSinglePanel(
        geometry: [DetectedPanel],
        model: [DetectedPanel],
        balloonRegions: [CGRect],
        textRegions: [CGRect]
    ) -> DetectedPanel? {
        guard geometry.count == 1, model.count == 1 else { return nil }
        let geometric = geometry[0]
        let learned = model[0]
        guard geometric.confidence >= 0.40,
              intersectionOverUnion(geometric.rect, learned.rect) >= 0.70,
              area(geometric.rect) >= 0.30,
              learned.confidence >= 0.68,
              singlePanelSemanticsArePlausible(
                balloons: balloonRegions,
                texts: textRegions
              ) else {
            return nil
        }
        return geometric.confidence >= learned.confidence ? geometric : learned
    }

    /// Dense, widely dispersed dialogue evidence makes a lone whole-page frame suspect.
    /// This does not synthesize panels; it only prevents two weak "whole page" signals
    /// from falsely corroborating each other on a multi-panel page.
    private static func singlePanelSemanticsArePlausible(
        balloons: [CGRect],
        texts: [CGRect]
    ) -> Bool {
        let evidence: [CGRect]
        if balloons.count >= 3 {
            evidence = balloons
        } else if texts.count >= 3 {
            evidence = texts
        } else {
            evidence = balloons + texts
        }
        guard evidence.count >= 3 else { return true }

        let centers = evidence.map { CGPoint(x: $0.midX, y: $0.midY) }
        let minX = centers.map(\.x).min() ?? 0
        let maxX = centers.map(\.x).max() ?? 0
        let minY = centers.map(\.y).min() ?? 0
        let maxY = centers.map(\.y).max() ?? 0

        return (maxX - minX) < 0.48 && (maxY - minY) < 0.42
    }

    private static func hasUnsupportedCrossSourceContainment(
        _ panels: [DetectedPanel]
    ) -> Bool {
        for lhsIndex in panels.indices {
            for rhsIndex in panels.indices where rhsIndex > lhsIndex {
                let lhs = panels[lhsIndex]
                let rhs = panels[rhsIndex]
                guard lhs.source != rhs.source,
                      (lhs.source == .pageGeometry || rhs.source == .pageGeometry),
                      (lhs.source == .coreML || rhs.source == .coreML) else {
                    continue
                }

                let lhsInside = containment(of: lhs.rect, in: rhs.rect)
                let rhsInside = containment(of: rhs.rect, in: lhs.rect)
                if max(lhsInside, rhsInside) >= 0.82 {
                    return true
                }
            }
        }
        return false
    }

    private static func containment(of inner: CGRect, in outer: CGRect) -> CGFloat {
        let intersection = inner.intersection(outer)
        guard !intersection.isNull else { return 0 }
        return area(intersection) / max(area(inner), 0.000_001)
    }

    private static func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        let intersectionArea = area(intersection)
        return intersectionArea / max(area(lhs) + area(rhs) - intersectionArea, 0.000_001)
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        max(rect.width, 0) * max(rect.height, 0)
    }
}

/// Conservative fallback similar in spirit to commercial "virtual panel" modes.
///
/// A deterministic viewport is preferable to inventing a speech balloon or text box as a
/// real frame. These regions are explicitly marked as fallback and never masquerade as
/// detected panel geometry.
nonisolated enum VirtualPanelPlanner {
    static func panels(
        in contentBounds: CGRect,
        imageAspectRatio: CGFloat
    ) -> [DetectedPanel] {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let bounds = contentBounds.standardized.intersection(unit)
        guard !bounds.isNull, bounds.width > 0.12, bounds.height > 0.12 else {
            return []
        }

        let sourceRects: [CGRect]
        if imageAspectRatio > 0, imageAspectRatio <= 0.52 {
            sourceRects = (0..<3).map { index in
                CGRect(
                    x: bounds.minX,
                    y: bounds.minY + bounds.height * CGFloat(index) / 3,
                    width: bounds.width,
                    height: bounds.height / 3
                )
            }
        } else if imageAspectRatio >= 1.65 {
            sourceRects = (0..<3).map { index in
                CGRect(
                    x: bounds.minX + bounds.width * CGFloat(index) / 3,
                    y: bounds.minY,
                    width: bounds.width / 3,
                    height: bounds.height
                )
            }
        } else {
            sourceRects = [
                CGRect(
                    x: bounds.minX,
                    y: bounds.minY,
                    width: bounds.width / 2,
                    height: bounds.height / 2
                ),
                CGRect(
                    x: bounds.midX,
                    y: bounds.minY,
                    width: bounds.width / 2,
                    height: bounds.height / 2
                ),
                CGRect(
                    x: bounds.minX,
                    y: bounds.midY,
                    width: bounds.width / 2,
                    height: bounds.height / 2
                ),
                CGRect(
                    x: bounds.midX,
                    y: bounds.midY,
                    width: bounds.width / 2,
                    height: bounds.height / 2
                )
            ]
        }

        return sourceRects.map {
            DetectedPanel(
                rect: $0,
                confidence: 0.30,
                source: .virtualPanel
            )
        }
    }
}

fileprivate nonisolated struct PanelGeometryAnalyzer {
    private enum Axis {
        case horizontal
        case vertical
    }

    fileprivate struct PixelRect {
        let minX: Int
        let minY: Int
        let maxX: Int
        let maxY: Int

        var width: Int { max(maxX - minX, 0) }
        var height: Int { max(maxY - minY, 0) }
        var area: Int { width * height }

        func normalized(width pageWidth: Int, height pageHeight: Int) -> CGRect {
            CGRect(
                x: CGFloat(minX) / CGFloat(max(pageWidth, 1)),
                y: CGFloat(minY) / CGFloat(max(pageHeight, 1)),
                width: CGFloat(width) / CGFloat(max(pageWidth, 1)),
                height: CGFloat(height) / CGFloat(max(pageHeight, 1))
            )
        }
    }

    private struct Separator {
        let axis: Axis
        let start: Int
        let end: Int
        let score: CGFloat

        var center: CGFloat { CGFloat(start + end) / 2 }
    }

    private struct Leaf {
        let rect: PixelRect
        let pathConfidence: CGFloat
        let depth: Int
    }

    private let raster: PanelGeometryRaster

    init(raster: PanelGeometryRaster) {
        self.raster = raster
    }

    func detectPanels() -> [DetectedPanel] {
        let root = raster.detectedContentBounds() ?? PixelRect(
            minX: 0,
            minY: 0,
            maxX: raster.width,
            maxY: raster.height
        )
        guard root.width >= 48, root.height >= 48 else { return [] }

        var leaves: [Leaf] = []
        split(
            root,
            depth: 0,
            pathConfidence: 0,
            output: &leaves
        )

        let accepted = leaves.compactMap { leaf -> (
            leaf: Leaf,
            rect: CGRect,
            edgeSupport: CGFloat,
            inkFraction: CGFloat
        )? in
            let rect = leaf.rect.normalized(
                width: raster.width,
                height: raster.height
            )
            guard rect.width >= 0.045,
                  rect.height >= 0.040,
                  rect.width * rect.height >= 0.010 else {
                return nil
            }

            let edgeSupport = boundarySupport(leaf.rect)
            let inkFraction = raster.inkFraction(in: leaf.rect)

            // Chapter headings, credits and isolated text in page margins can sit above
            // a strong whitespace separator. They are content, but not panels. Require
            // either visible frame-edge support or enough visual activity to look like
            // actual artwork; sparse borderless cases are left for the model residual.
            guard edgeSupport >= 0.50 || inkFraction >= 0.055 else {
                return nil
            }
            return (leaf, rect, edgeSupport, inkFraction)
        }

        // Confidence should describe the usable output, not discarded leaves. A false
        // split that leaves only one accepted region must not manufacture a high-confidence
        // single panel merely because an ignored title/margin leaf existed.
        let splitLayout = accepted.count >= 2
        return accepted.map { item in
            let activity = min(item.inkFraction / 0.20, 1)
            let confidence: Float
            if splitLayout {
                confidence = Float(min(
                    0.96,
                    0.53
                        + item.leaf.pathConfidence * 0.25
                        + item.edgeSupport * 0.13
                        + activity * 0.05
                ))
            } else {
                // A page with no reliable multi-panel structure is evidence of
                // "unknown/splash", not proof that the entire page is one real frame.
                confidence = Float(min(
                    0.48,
                    0.28 + item.edgeSupport * 0.12 + activity * 0.05
                ))
            }

            return DetectedPanel(
                rect: item.rect,
                confidence: confidence,
                source: .pageGeometry
            )
        }
    }

    private func split(
        _ rect: PixelRect,
        depth: Int,
        pathConfidence: CGFloat,
        output: inout [Leaf]
    ) {
        guard depth < 7 else {
            output.append(Leaf(rect: rect, pathConfidence: pathConfidence, depth: depth))
            return
        }

        let separators = [
            bestSeparator(in: rect, axis: .horizontal),
            bestSeparator(in: rect, axis: .vertical)
        ].compactMap { $0 }

        guard let separator = separators.max(by: { $0.score < $1.score }),
              separator.score >= 0.46,
              let children = children(of: rect, splitBy: separator) else {
            output.append(Leaf(rect: rect, pathConfidence: pathConfidence, depth: depth))
            return
        }

        let nextConfidence = depth == 0
            ? separator.score
            : min(pathConfidence, separator.score)
        split(
            children.0,
            depth: depth + 1,
            pathConfidence: nextConfidence,
            output: &output
        )
        split(
            children.1,
            depth: depth + 1,
            pathConfidence: nextConfidence,
            output: &output
        )
    }

    private var minimumChildWidth: Int {
        max(38, Int((CGFloat(raster.width) * 0.055).rounded()))
    }

    private var minimumChildHeight: Int {
        max(34, Int((CGFloat(raster.height) * 0.045).rounded()))
    }

    private func children(
        of rect: PixelRect,
        splitBy separator: Separator
    ) -> (PixelRect, PixelRect)? {
        switch separator.axis {
        case .horizontal:
            let top = PixelRect(
                minX: rect.minX,
                minY: rect.minY,
                maxX: rect.maxX,
                maxY: separator.start
            )
            let bottom = PixelRect(
                minX: rect.minX,
                minY: separator.end,
                maxX: rect.maxX,
                maxY: rect.maxY
            )
            guard top.height >= minimumChildHeight,
                  bottom.height >= minimumChildHeight else {
                return nil
            }
            return (top, bottom)

        case .vertical:
            let left = PixelRect(
                minX: rect.minX,
                minY: rect.minY,
                maxX: separator.start,
                maxY: rect.maxY
            )
            let right = PixelRect(
                minX: separator.end,
                minY: rect.minY,
                maxX: rect.maxX,
                maxY: rect.maxY
            )
            guard left.width >= minimumChildWidth,
                  right.width >= minimumChildWidth else {
                return nil
            }
            return (left, right)
        }
    }

    private func bestSeparator(
        in rect: PixelRect,
        axis: Axis
    ) -> Separator? {
        let range: Range<Int>
        let minimumChild: Int
        switch axis {
        case .horizontal:
            minimumChild = minimumChildHeight
            guard rect.height >= minimumChild * 2 else { return nil }
            range = (rect.minY + minimumChild)..<(rect.maxY - minimumChild)
        case .vertical:
            minimumChild = minimumChildWidth
            guard rect.width >= minimumChild * 2 else { return nil }
            range = (rect.minX + minimumChild)..<(rect.maxX - minimumChild)
        }
        guard !range.isEmpty else { return nil }

        var bands: [(start: Int, end: Int)] = []
        var bandStart: Int?
        var dirtyBridge = 0

        func closeBand(at end: Int) {
            guard let start = bandStart else { return }
            if end > start {
                bands.append((start, end))
            }
            bandStart = nil
            dirtyBridge = 0
        }

        for position in range {
            let white = isGutterLine(position, in: rect, axis: axis)
            if white {
                if bandStart == nil {
                    bandStart = position
                }
                dirtyBridge = 0
            } else if bandStart != nil, dirtyBridge < 1 {
                dirtyBridge += 1
            } else {
                closeBand(at: position - dirtyBridge)
            }
        }
        closeBand(at: range.upperBound - dirtyBridge)

        let axisLength = axis == .horizontal ? rect.height : rect.width
        let minimumThickness = max(2, Int((CGFloat(axisLength) * 0.006).rounded()))

        return bands.compactMap { band -> Separator? in
            let thickness = band.end - band.start
            guard thickness >= minimumThickness else { return nil }

            let firstChildLength: Int
            let secondChildLength: Int
            switch axis {
            case .horizontal:
                firstChildLength = band.start - rect.minY
                secondChildLength = rect.maxY - band.end
            case .vertical:
                firstChildLength = band.start - rect.minX
                secondChildLength = rect.maxX - band.end
            }
            guard firstChildLength >= minimumChild,
                  secondChildLength >= minimumChild else {
                return nil
            }

            let balance = CGFloat(min(firstChildLength, secondChildLength))
                / CGFloat(max(firstChildLength, secondChildLength))
            let rawThicknessFraction = CGFloat(thickness) / CGFloat(max(axisLength, 1))
            // Very large blank areas are usually artwork/background, not gutters.
            guard rawThicknessFraction <= 0.14 else { return nil }
            let thicknessFraction = min(rawThicknessFraction, 0.08) / 0.08

            let bandRect: PixelRect
            let leadingShoulder: PixelRect
            let trailingShoulder: PixelRect
            let shoulderThickness = 3
            switch axis {
            case .horizontal:
                bandRect = PixelRect(
                    minX: rect.minX,
                    minY: band.start,
                    maxX: rect.maxX,
                    maxY: band.end
                )
                leadingShoulder = PixelRect(
                    minX: rect.minX,
                    minY: max(band.start - shoulderThickness, rect.minY),
                    maxX: rect.maxX,
                    maxY: band.start
                )
                trailingShoulder = PixelRect(
                    minX: rect.minX,
                    minY: band.end,
                    maxX: rect.maxX,
                    maxY: min(band.end + shoulderThickness, rect.maxY)
                )
            case .vertical:
                bandRect = PixelRect(
                    minX: band.start,
                    minY: rect.minY,
                    maxX: band.end,
                    maxY: rect.maxY
                )
                leadingShoulder = PixelRect(
                    minX: max(band.start - shoulderThickness, rect.minX),
                    minY: rect.minY,
                    maxX: band.start,
                    maxY: rect.maxY
                )
                trailingShoulder = PixelRect(
                    minX: band.end,
                    minY: rect.minY,
                    maxX: min(band.end + shoulderThickness, rect.maxX),
                    maxY: rect.maxY
                )
            }

            let whiteness = max(
                0,
                1 - raster.inkFraction(in: bandRect) / 0.026
            )
            let bandLuma = raster.averageLuma(in: bandRect)
            let brightness = max(
                0,
                min((bandLuma - 225) / 30, 1)
            )
            let shoulderInk = max(
                raster.inkFraction(in: leadingShoulder),
                raster.inkFraction(in: trailingShoulder)
            )
            let shoulderDark = max(
                raster.darkFraction(in: leadingShoulder),
                raster.darkFraction(in: trailingShoulder)
            )
            let shoulderLuma = (
                raster.averageLuma(in: leadingShoulder)
                    + raster.averageLuma(in: trailingShoulder)
            ) / 2
            let transitionContrast = max(
                0,
                min((bandLuma - shoulderLuma) / 55, 1)
            )

            // A blank stripe inside a single illustration can be white too. Prefer
            // actual dark panel-boundary evidence. Borderless gutters remain eligible
            // only when they are narrow and have a very strong local transition.
            let hasBoundaryEvidence = shoulderDark >= 0.012
                || (
                    rawThicknessFraction <= 0.035
                    && transitionContrast >= 0.45
                    && shoulderInk >= 0.12
                )
            guard hasBoundaryEvidence else { return nil }

            let score =
                thicknessFraction * 0.20
                + whiteness * 0.27
                + brightness * 0.13
                + balance * 0.14
                + min(shoulderDark / 0.10, 1) * 0.16
                + transitionContrast * 0.10

            let candidate = Separator(
                axis: axis,
                start: band.start,
                end: band.end,
                score: score
            )
            guard let candidateChildren = children(of: rect, splitBy: candidate),
                  raster.inkFraction(in: candidateChildren.0) >= 0.007,
                  raster.inkFraction(in: candidateChildren.1) >= 0.007 else {
                return nil
            }
            return candidate
        }.max(by: { $0.score < $1.score })
    }

    private func isGutterLine(
        _ position: Int,
        in rect: PixelRect,
        axis: Axis
    ) -> Bool {
        let strip: PixelRect
        switch axis {
        case .horizontal:
            strip = PixelRect(
                minX: rect.minX,
                minY: position,
                maxX: rect.maxX,
                maxY: position + 1
            )
        case .vertical:
            strip = PixelRect(
                minX: position,
                minY: rect.minY,
                maxX: position + 1,
                maxY: rect.maxY
            )
        }

        return raster.inkFraction(in: strip) <= 0.075
            && raster.darkFraction(in: strip) <= 0.018
            && raster.averageLuma(in: strip) >= 230
    }

    private func boundarySupport(_ rect: PixelRect) -> CGFloat {
        let thickness = max(
            1,
            min(4, Int((CGFloat(min(rect.width, rect.height)) * 0.012).rounded()))
        )
        let bands = [
            PixelRect(
                minX: rect.minX,
                minY: rect.minY,
                maxX: rect.maxX,
                maxY: min(rect.minY + thickness, rect.maxY)
            ),
            PixelRect(
                minX: rect.minX,
                minY: max(rect.maxY - thickness, rect.minY),
                maxX: rect.maxX,
                maxY: rect.maxY
            ),
            PixelRect(
                minX: rect.minX,
                minY: rect.minY,
                maxX: min(rect.minX + thickness, rect.maxX),
                maxY: rect.maxY
            ),
            PixelRect(
                minX: max(rect.maxX - thickness, rect.minX),
                minY: rect.minY,
                maxX: rect.maxX,
                maxY: rect.maxY
            )
        ]

        let supported = bands.filter {
            raster.inkFraction(in: $0) >= 0.16
                || raster.darkFraction(in: $0) >= 0.08
        }.count
        return CGFloat(supported) / 4
    }
}

fileprivate nonisolated struct PanelGeometryRaster {
    let width: Int
    let height: Int

    private let inkIntegral: [Int]
    private let darkIntegral: [Int]
    private let lumaIntegral: [Int64]

    init?(
        image: CGImage,
        maximumDimension: Int
    ) {
        let sourceWidth = max(image.width, 1)
        let sourceHeight = max(image.height, 1)
        let maximum = max(sourceWidth, sourceHeight)
        let scale = min(
            1,
            CGFloat(maximumDimension) / CGFloat(max(maximum, 1))
        )
        let targetWidth = max(Int((CGFloat(sourceWidth) * scale).rounded()), 1)
        let targetHeight = max(Int((CGFloat(sourceHeight) * scale).rounded()), 1)

        var pixels = [UInt8](
            repeating: 255,
            count: targetWidth * targetHeight
        )
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: targetWidth,
                    height: targetHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: targetWidth,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else {
                return false
            }

            context.setFillColor(gray: 1, alpha: 1)
            context.fill(
                CGRect(
                    x: 0,
                    y: 0,
                    width: targetWidth,
                    height: targetHeight
                )
            )
            // Store row zero as the visual top of the comic page.
            context.translateBy(x: 0, y: CGFloat(targetHeight))
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .medium
            context.draw(
                image,
                in: CGRect(
                    x: 0,
                    y: 0,
                    width: targetWidth,
                    height: targetHeight
                )
            )
            return true
        }
        guard rendered else { return nil }

        width = targetWidth
        height = targetHeight

        let stride = targetWidth + 1
        var ink = [Int](repeating: 0, count: stride * (targetHeight + 1))
        var dark = [Int](repeating: 0, count: stride * (targetHeight + 1))
        var luma = [Int64](repeating: 0, count: stride * (targetHeight + 1))

        for y in 0..<targetHeight {
            var rowInk = 0
            var rowDark = 0
            var rowLuma: Int64 = 0
            for x in 0..<targetWidth {
                let value = Int(pixels[y * targetWidth + x])
                rowInk += value < 238 ? 1 : 0
                rowDark += value < 96 ? 1 : 0
                rowLuma += Int64(value)

                let destination = (y + 1) * stride + (x + 1)
                ink[destination] = ink[y * stride + (x + 1)] + rowInk
                dark[destination] = dark[y * stride + (x + 1)] + rowDark
                luma[destination] = luma[y * stride + (x + 1)] + rowLuma
            }
        }

        inkIntegral = ink
        darkIntegral = dark
        lumaIntegral = luma
    }

    func detectedContentBounds() -> PanelGeometryAnalyzer.PixelRect? {
        let full = PanelGeometryAnalyzer.PixelRect(
            minX: 0,
            minY: 0,
            maxX: width,
            maxY: height
        )
        guard width >= 8, height >= 8 else { return full }

        func rowHasContent(_ y: Int) -> Bool {
            let strip = PanelGeometryAnalyzer.PixelRect(
                minX: 0,
                minY: y,
                maxX: width,
                maxY: min(y + 1, height)
            )
            return inkFraction(in: strip) >= 0.012
                || darkFraction(in: strip) >= 0.002
        }

        func columnHasContent(_ x: Int) -> Bool {
            let strip = PanelGeometryAnalyzer.PixelRect(
                minX: x,
                minY: 0,
                maxX: min(x + 1, width),
                maxY: height
            )
            return inkFraction(in: strip) >= 0.012
                || darkFraction(in: strip) >= 0.002
        }

        guard let top = (0..<height).first(where: rowHasContent),
              let bottom = (0..<height).reversed().first(where: rowHasContent),
              let left = (0..<width).first(where: columnHasContent),
              let right = (0..<width).reversed().first(where: columnHasContent) else {
            return full
        }

        let padding = max(2, Int((CGFloat(max(width, height)) * 0.006).rounded()))
        let bounds = PanelGeometryAnalyzer.PixelRect(
            minX: max(left - padding, 0),
            minY: max(top - padding, 0),
            maxX: min(right + 1 + padding, width),
            maxY: min(bottom + 1 + padding, height)
        )
        guard bounds.width >= 48, bounds.height >= 48 else { return full }
        return bounds
    }

    func inkFraction(in rect: PanelGeometryAnalyzer.PixelRect) -> CGFloat {
        fraction(integral: inkIntegral, in: rect)
    }

    func darkFraction(in rect: PanelGeometryAnalyzer.PixelRect) -> CGFloat {
        fraction(integral: darkIntegral, in: rect)
    }

    func averageLuma(in rect: PanelGeometryAnalyzer.PixelRect) -> CGFloat {
        let area = max(rect.area, 1)
        let value = sum(integral: lumaIntegral, in: rect)
        return CGFloat(value) / CGFloat(area)
    }

    private func fraction(
        integral: [Int],
        in rect: PanelGeometryAnalyzer.PixelRect
    ) -> CGFloat {
        let area = max(rect.area, 1)
        return CGFloat(sum(integral: integral, in: rect)) / CGFloat(area)
    }

    private func sum(
        integral: [Int],
        in rect: PanelGeometryAnalyzer.PixelRect
    ) -> Int {
        let x0 = min(max(rect.minX, 0), width)
        let y0 = min(max(rect.minY, 0), height)
        let x1 = min(max(rect.maxX, x0), width)
        let y1 = min(max(rect.maxY, y0), height)
        let stride = width + 1
        return integral[y1 * stride + x1]
            - integral[y0 * stride + x1]
            - integral[y1 * stride + x0]
            + integral[y0 * stride + x0]
    }

    private func sum(
        integral: [Int64],
        in rect: PanelGeometryAnalyzer.PixelRect
    ) -> Int64 {
        let x0 = min(max(rect.minX, 0), width)
        let y0 = min(max(rect.minY, 0), height)
        let x1 = min(max(rect.maxX, x0), width)
        let y1 = min(max(rect.maxY, y0), height)
        let stride = width + 1
        return integral[y1 * stride + x1]
            - integral[y0 * stride + x1]
            - integral[y1 * stride + x0]
            + integral[y0 * stride + x0]
    }
}
