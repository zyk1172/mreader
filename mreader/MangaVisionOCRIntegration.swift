import CoreGraphics
import Foundation

/// Bridges page-level Manga Vision regions into the existing TextBlock contract.
/// The Core ML model owns only geometry; OCR remains the source of text/confidence.
nonisolated enum MangaVisionOCRGeometry {
    private struct BalloonCandidate {
        let region: MangaVisionRegion
        let fittedRect: CGRect
        let score: CGFloat
    }

    static func applyingBalloonGeometry(
        to blocks: [TextBlock],
        analysis: MangaPageAnalysis
    ) -> [TextBlock] {
        guard !blocks.isEmpty, !analysis.balloons.isEmpty else { return blocks }
        let balloons = MangaVisionRegionPostProcessor.deduplicated(
            analysis.balloons.filter(isUsableBalloon),
            iouThreshold: 0.58,
            containmentThreshold: 0.90
        )
        guard !balloons.isEmpty else { return blocks }

        return blocks.map { block in
            // Preserve geometry explicitly supplied by Vision translation or another
            // trusted source. Manga Vision is a recovery/enrichment layer, not an
            // authority that overwrites a known bubble.
            guard block.bubbleBox == nil,
                  block.layoutRole == .dialogue,
                  let match = bestBalloon(for: block.boundingBox, balloons: balloons) else {
                return block
            }
            var enriched = block
            enriched.bubbleBox = match
            if enriched.layoutSafeRegion == nil {
                enriched.layoutSafeRegion = match
            }
            return enriched
        }
    }

    static func bestBalloonForDiagnostics(
        textRect: CGRect,
        balloons: [MangaVisionRegion]
    ) -> CGRect? {
        bestBalloon(for: textRect, balloons: balloons)
    }

    private static func bestBalloon(
        for rawTextRect: CGRect,
        balloons: [MangaVisionRegion]
    ) -> CGRect? {
        let textRect = MangaPageCoordinateSpace.clampedNormalizedRect(rawTextRect.standardized)
        guard textRect.width > 0, textRect.height > 0 else { return nil }
        let textArea = max(MangaPageCoordinateSpace.area(textRect), 0.000_001)
        let toleranceX = max(0.004, textRect.width * 0.10)
        let toleranceY = max(0.004, textRect.height * 0.10)
        let center = CGPoint(x: textRect.midX, y: textRect.midY)

        let candidates = balloons.compactMap { balloon -> BalloonCandidate? in
            let rect = balloon.normalizedRect.standardized
            guard rect.width > 0, rect.height > 0 else { return nil }
            let containment = MangaPageCoordinateSpace.containment(of: textRect, in: rect)
            let centerInside = rect.insetBy(dx: -toleranceX, dy: -toleranceY).contains(center)
            // Bounding boxes from two detectors may disagree slightly. Require
            // substantial text coverage, but allow a center-confirmed partial edge.
            guard containment >= 0.55 || (centerInside && containment >= 0.30) else { return nil }

            // Union only repairs small detector under-coverage so the downstream
            // validatedBubbleGeometry contract can safely require containment.
            let fitted = MangaPageCoordinateSpace.clampedNormalizedRect(rect.union(textRect))
            let fittedArea = MangaPageCoordinateSpace.area(fitted)
            guard fittedArea > 0,
                  fittedArea <= 0.55,
                  fittedArea / textArea <= 600 else { return nil }

            let distance = hypot(fitted.midX - textRect.midX, fitted.midY - textRect.midY)
            let diagonal = max(hypot(fitted.width, fitted.height), 0.001)
            let normalizedDistance = distance / diagonal
            // Prefer the bubble that contains most of the OCR text, then the
            // smaller/closer region. Confidence is deliberately a weak tie-breaker.
            let score = containment * 4.0
                - normalizedDistance * 0.9
                - fittedArea * 0.8
                + CGFloat(balloon.confidence) * 0.35
            return BalloonCandidate(region: balloon, fittedRect: fitted, score: score)
        }.sorted { lhs, rhs in
            if abs(lhs.score - rhs.score) > 0.000_1 { return lhs.score > rhs.score }
            let lhsArea = MangaPageCoordinateSpace.area(lhs.fittedRect)
            let rhsArea = MangaPageCoordinateSpace.area(rhs.fittedRect)
            return lhsArea < rhsArea
        }

        guard let best = candidates.first else { return nil }
        if candidates.count > 1 {
            let second = candidates[1]
            let overlap = MangaPageCoordinateSpace.intersectionOverUnion(
                best.fittedRect,
                second.fittedRect
            )
            // Two unrelated balloons with almost identical assignment scores are
            // ambiguous. Refuse to invent grouping instead of joining dialogues.
            if best.score - second.score < 0.08, overlap < 0.25 {
                return nil
            }
        }
        return best.fittedRect
    }

    private static func isUsableBalloon(_ region: MangaVisionRegion) -> Bool {
        guard region.type == .balloon, region.confidence >= 0.20 else { return false }
        let rect = region.normalizedRect
        let area = MangaPageCoordinateSpace.area(rect)
        return rect.width >= 0.004
            && rect.height >= 0.004
            && area >= 0.000_04
            && area <= 0.55
    }
}

/// A page-space filter applied after ROI OCR. VNRecognizeTextRequest.minimumTextHeight
/// is relative to the cropped ROI, so it cannot be the final policy once Manga Vision
/// starts feeding small text crops. This restores the user's page-level threshold and
/// uses the physical font axis: horizontal -> height, vertical -> width.
nonisolated enum OCRPageScaleFilter {
    struct Result: Sendable {
        let accepted: [TextBlock]
        let rejected: [TextBlock]
    }

    static func partition(
        _ blocks: [TextBlock],
        minimumTextHeight: Double
    ) -> Result {
        let minimumAxis = min(max(CGFloat(minimumTextHeight), 0.002), 0.05)
        let minimumArea = minimumAxis * 0.0048
        var accepted: [TextBlock] = []
        var rejected: [TextBlock] = []
        accepted.reserveCapacity(blocks.count)

        for block in blocks {
            let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let rect = block.boundingBox
            let geometryAxis = block.textOrientation == .vertical ? rect.width : rect.height
            let estimatedAxis = block.estimatedFontScale.isFinite && block.estimatedFontScale > 0
                ? CGFloat(block.estimatedFontScale)
                : geometryAxis
            let fontAxis = max(min(estimatedAxis, max(geometryAxis * 3, geometryAxis)), 0)
            let area = max(rect.width, 0) * max(rect.height, 0)

            let reason: String?
            if text.count <= 2, fontAxis < minimumAxis * 1.55 {
                reason = "短文本过小"
            } else if fontAxis < minimumAxis || area < minimumArea {
                reason = "字号/面积过小"
            } else {
                reason = nil
            }

            guard let reason else {
                accepted.append(block)
                continue
            }
            var filtered = block
            filtered.isFiltered = true
            filtered.filterReason = reason
            rejected.append(filtered)
        }
        return Result(accepted: accepted, rejected: rejected)
    }

    static func applying(
        to result: OCRPipelineResult,
        minimumTextHeight: Double,
        isRightToLeft: Bool
    ) -> OCRPipelineResult {
        let filtered = partition(
            result.resolvedBlocks,
            minimumTextHeight: minimumTextHeight
        )
        let segmentation = MangaTextSegmenter.segment(
            filtered.accepted,
            isRightToLeft: isRightToLeft
        )
        return OCRPipelineResult(
            rawBlocks: result.rawBlocks,
            resolvedBlocks: filtered.accepted,
            lineBlocks: segmentation.lines,
            bubbleBlocks: segmentation.bubbles,
            rejectedBlocks: result.rejectedBlocks + filtered.rejected,
            detectedLanguage: result.detectedLanguage,
            quality: result.quality
        )
    }
}

nonisolated enum MangaVisionOCROrdering {
    static func orderedBlocks(
        _ blocks: [TextBlock],
        analysis: MangaPageAnalysis,
        isRightToLeft: Bool
    ) -> [TextBlock] {
        guard blocks.count > 1, !analysis.panels.isEmpty else {
            return AITranslator.sortedTextBlocks(blocks, isRightToLeft: isRightToLeft)
        }
        let semantic = MangaSemanticAnalyzer.makeSemanticPage(
            from: analysis,
            isRightToLeft: isRightToLeft
        )
        let panelRank = Dictionary(uniqueKeysWithValues: semantic.panels.enumerated().map {
            ($0.element.panel.id, $0.offset)
        })

        struct RankedBlock {
            let block: TextBlock
            let panelIndex: Int
        }
        let ranked = blocks.map { block -> RankedBlock in
            let panel = MangaSemanticAnalyzer.owningPanel(
                for: block.boundingBox,
                panels: semantic.panels.map(\.panel)
            )
            return RankedBlock(
                block: block,
                panelIndex: panel.flatMap { panelRank[$0.id] } ?? Int.max
            )
        }
        return ranked.sorted { lhs, rhs in
            if lhs.panelIndex != rhs.panelIndex {
                return lhs.panelIndex < rhs.panelIndex
            }
            let a = lhs.block.boundingBox
            let b = rhs.block.boundingBox
            let rowTolerance = max(min(a.height, b.height) * 0.45, 0.012)
            if abs(a.midY - b.midY) > rowTolerance {
                return a.midY < b.midY
            }
            if abs(a.midX - b.midX) > 0.004 {
                return isRightToLeft ? a.midX > b.midX : a.midX < b.midX
            }
            return a.minY < b.minY
        }.map(\.block)
    }

    static func applyingReadingOrder(
        to result: OCRPipelineResult,
        analysis: MangaPageAnalysis,
        isRightToLeft: Bool
    ) -> OCRPipelineResult {
        // Attach detected physical balloons before segmentation. This is the key
        // boundary that turns several Japanese vertical OCR columns inside one
        // speech balloon into one translation unit instead of several grey cards.
        let enrichedResolved = MangaVisionOCRGeometry.applyingBalloonGeometry(
            to: result.resolvedBlocks,
            analysis: analysis
        )
        let segmentation = MangaTextSegmenter.segment(
            enrichedResolved,
            isRightToLeft: isRightToLeft
        )
        return OCRPipelineResult(
            rawBlocks: MangaVisionOCRGeometry.applyingBalloonGeometry(
                to: result.rawBlocks,
                analysis: analysis
            ),
            resolvedBlocks: orderedBlocks(
                enrichedResolved,
                analysis: analysis,
                isRightToLeft: isRightToLeft
            ),
            lineBlocks: orderedBlocks(
                segmentation.lines,
                analysis: analysis,
                isRightToLeft: isRightToLeft
            ),
            bubbleBlocks: orderedBlocks(
                segmentation.bubbles,
                analysis: analysis,
                isRightToLeft: isRightToLeft
            ),
            rejectedBlocks: result.rejectedBlocks,
            detectedLanguage: result.detectedLanguage,
            quality: result.quality
        )
    }
}
