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
    let identifier = "page-geometry-xycut-v1"

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
    static let revision = "geometry-first-fusion-v1"

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
        let geometryPanels = PanelPostProcessor.process(
            clippedToContent(geometry, contentBounds: contentBounds)
        )
        let modelPanels = PanelPostProcessor.process(
            clippedToContent(model, contentBounds: contentBounds)
                .filter {
                    !isSemanticAlias(
                        $0,
                        balloons: balloonRegions,
                        texts: textRegions
                    )
                }
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

        if modelUsable {
            return Resolution(
                panels: modelPanels,
                usedVirtualFallback: false,
                reason: "model-residual"
            )
        }

        let combined = PanelPostProcessor.process(geometryPanels + modelPanels)
        if PanelLayoutQuality.isUsable(combined) {
            return Resolution(
                panels: combined,
                usedVirtualFallback: false,
                reason: "combined-recovery"
            )
        }

        if let corroboratedSingle = corroboratedSinglePanel(
            geometry: geometryPanels,
            model: modelPanels
        ) {
            return Resolution(
                panels: [corroboratedSingle],
                usedVirtualFallback: false,
                reason: "corroborated-single-panel"
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

    /// Clip only when the detected content bounds actually remove page margin.
    /// A candidate that would lose too much area is kept unchanged so a slightly noisy
    /// content-bound estimate cannot amputate a legitimate full-bleed panel.
    private static func clippedToContent(
        _ panels: [DetectedPanel],
        contentBounds: CGRect
    ) -> [DetectedPanel] {
        let bounds = contentBounds.standardized
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else {
            return panels
        }

        return panels.compactMap { panel in
            let intersection = panel.rect.standardized.intersection(bounds)
            guard !intersection.isNull,
                  intersection.width > 0,
                  intersection.height > 0 else {
                return nil
            }
            let retention = area(intersection) / max(area(panel.rect), 0.000_001)
            guard retention >= 0.72 else { return panel }
            return DetectedPanel(
                rect: intersection,
                confidence: panel.confidence,
                source: panel.source,
                contour: panel.contour
            )
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

    private static func isGeometryAuthoritative(_ panels: [DetectedPanel]) -> Bool {
        guard panels.count >= 2,
              PanelLayoutQuality.isUsable(panels) else {
            return false
        }
        let average = panels.reduce(Float.zero) { $0 + $1.confidence }
            / Float(max(panels.count, 1))
        return average >= 0.50
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

        // A high-confidence model frame may fill a region that geometry did not cover at
        // all (for example an inset panel floating over a full-bleed background).
        for (index, candidate) in model.enumerated() where !consumedModelIDs.contains(index) {
            guard candidate.confidence >= 0.62,
                  area(candidate.rect) >= 0.018 else {
                continue
            }
            let covered = result.contains {
                containment(of: candidate.rect, in: $0.rect) >= 0.70
                    || intersectionOverUnion(candidate.rect, $0.rect) >= 0.45
            }
            if !covered {
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
        let union = candidates.dropFirst().reduce(candidates[0].rect) {
            $0.union($1.rect)
        }
        let unionCoverage = area(union.intersection(geometric.rect)) / geometricArea
        guard unionCoverage >= 0.34 else { return false }

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
        model: [DetectedPanel]
    ) -> DetectedPanel? {
        guard geometry.count == 1, model.count == 1 else { return nil }
        let geometric = geometry[0]
        let learned = model[0]
        guard intersectionOverUnion(geometric.rect, learned.rect) >= 0.58,
              area(geometric.rect) >= 0.30,
              learned.confidence >= 0.48 else {
            return nil
        }
        return geometric.confidence >= learned.confidence ? geometric : learned
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

fileprivate struct PanelGeometryAnalyzer {
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
        let root = PixelRect(
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

        let splitLayout = leaves.count >= 2
        return leaves.compactMap { leaf in
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
            let activity = min(
                raster.inkFraction(in: leaf.rect) / 0.20,
                1
            )
            let confidence: Float
            if splitLayout {
                confidence = Float(min(
                    0.96,
                    0.53
                        + leaf.pathConfidence * 0.25
                        + edgeSupport * 0.13
                        + activity * 0.05
                ))
            } else {
                // A page with no detected separator is evidence of "unknown/splash",
                // not proof that the entire page is one real frame.
                confidence = Float(min(0.48, 0.28 + edgeSupport * 0.12 + activity * 0.05))
            }

            return DetectedPanel(
                rect: rect,
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
        guard depth < 7,
              rect.width >= minimumChildWidth * 2,
              rect.height >= minimumChildHeight * 2 else {
            output.append(Leaf(rect: rect, pathConfidence: pathConfidence, depth: depth))
            return
        }

        let separators = [
            bestSeparator(in: rect, axis: .horizontal),
            bestSeparator(in: rect, axis: .vertical)
        ].compactMap { $0 }

        guard let separator = separators.max(by: { $0.score < $1.score }),
              separator.score >= 0.46,
              let children = children(of: rect, splitBy: separator),
              raster.inkFraction(in: children.0) >= 0.007,
              raster.inkFraction(in: children.1) >= 0.007 else {
            output.append(Leaf(rect: rect, pathConfidence: pathConfidence, depth: depth))
            return
        }

        let nextConfidence = max(pathConfidence, separator.score)
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
            range = (rect.minY + minimumChild)..<(rect.maxY - minimumChild)
        case .vertical:
            minimumChild = minimumChildWidth
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
            let shoulderLuma = (
                raster.averageLuma(in: leadingShoulder)
                    + raster.averageLuma(in: trailingShoulder)
            ) / 2
            let transitionContrast = max(
                0,
                min((bandLuma - shoulderLuma) / 55, 1)
            )

            // A blank stripe inside a single illustration can be white too. Require a
            // local transition at one side of the stripe (panel border or real content)
            // before promoting it into structural page geometry.
            guard shoulderInk >= 0.035 || transitionContrast >= 0.08 else {
                return nil
            }

            let score =
                thicknessFraction * 0.22
                + whiteness * 0.28
                + brightness * 0.14
                + balance * 0.14
                + min(shoulderInk / 0.20, 1) * 0.12
                + transitionContrast * 0.10

            return Separator(
                axis: axis,
                start: band.start,
                end: band.end,
                score: score
            )
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

        return raster.inkFraction(in: strip) <= 0.026
            && raster.darkFraction(in: strip) <= 0.006
            && raster.averageLuma(in: strip) >= 238
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

fileprivate struct PanelGeometryRaster {
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
