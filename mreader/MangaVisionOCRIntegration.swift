import CoreGraphics
import Foundation

/// Bridges page-level Manga Vision regions into the existing TextBlock contract.
/// The Core ML model owns only geometry; OCR remains the source of text/confidence.
nonisolated enum MangaVisionPolygonLayout {
    static func interiorSafeRect(
        polygon rawPolygon: [CGPoint],
        bounds rawBounds: CGRect,
        preferredPoint: CGPoint?
    ) -> CGRect? {
        let polygon = rawPolygon.filter { $0.x.isFinite && $0.y.isFinite }
        let bounds = rawBounds.standardized
        guard polygon.count >= 3, bounds.width > 0, bounds.height > 0 else { return nil }

        let rowCount = 48
        let stepY = bounds.height / CGFloat(rowCount)
        guard stepY > 0 else { return nil }
        let preferredX = preferredPoint?.x ?? bounds.midX
        var rows: [(y: CGFloat, minX: CGFloat, maxX: CGFloat)] = []

        for row in 0..<rowCount {
            let y = bounds.minY + (CGFloat(row) + 0.5) * stepY
            var intersections: [CGFloat] = []
            for index in polygon.indices {
                let first = polygon[index]
                let second = polygon[(index + 1) % polygon.count]
                if abs(first.y - second.y) < 0.000_000_1 { continue }
                let lower = min(first.y, second.y)
                let upper = max(first.y, second.y)
                guard y >= lower, y < upper else { continue }
                let t = (y - first.y) / (second.y - first.y)
                intersections.append(first.x + (second.x - first.x) * t)
            }
            intersections.sort()
            var intervals: [(CGFloat, CGFloat)] = []
            var index = 0
            while index + 1 < intersections.count {
                let left = max(intersections[index], bounds.minX)
                let right = min(intersections[index + 1], bounds.maxX)
                if right > left { intervals.append((left, right)) }
                index += 2
            }
            guard !intervals.isEmpty else { continue }
            let selected = intervals
                .filter { preferredX >= $0.0 && preferredX <= $0.1 }
                .max(by: { ($0.1 - $0.0) < ($1.1 - $1.0) })
                ?? intervals.max(by: { ($0.1 - $0.0) < ($1.1 - $1.0) })!
            rows.append((y, selected.0, selected.1))
        }
        guard !rows.isEmpty else { return nil }

        var best: CGRect?
        var bestScore = -CGFloat.greatestFiniteMagnitude
        for start in rows.indices {
            var left = rows[start].minX
            var right = rows[start].maxX
            for end in start..<rows.count {
                if end > start, rows[end].y - rows[end - 1].y > stepY * 1.6 { break }
                left = max(left, rows[end].minX)
                right = min(right, rows[end].maxX)
                guard right > left else { break }
                let minY = max(rows[start].y - stepY / 2, bounds.minY)
                let maxY = min(rows[end].y + stepY / 2, bounds.maxY)
                let raw = CGRect(x: left, y: minY, width: right - left, height: maxY - minY)
                let insetX = max(raw.width * 0.045, bounds.width * 0.012)
                let insetY = max(raw.height * 0.045, bounds.height * 0.012)
                let candidate = raw.insetBy(dx: insetX, dy: insetY)
                guard candidate.width > 0, candidate.height > 0 else { continue }
                let area = candidate.width * candidate.height
                let distance = preferredPoint.map {
                    hypot(candidate.midX - $0.x, candidate.midY - $0.y)
                } ?? 0
                let containsPreferred = preferredPoint.map { candidate.contains($0) } ?? false
                let score = area * (containsPreferred ? 1.35 : 1.0)
                    - distance * max(bounds.width, bounds.height) * 0.08
                if score > bestScore {
                    bestScore = score
                    best = candidate
                }
            }
        }
        return best
    }
}

nonisolated enum MangaVisionOCRGeometry {
    private struct RegionCandidate {
        let rect: CGRect
        let score: CGFloat
        let polygon: [CGPoint]
    }

    /// Enrich local OCR with two different kinds of model geometry:
    /// - a physical `balloon` may become `bubbleBox` and therefore a canonical
    ///   translation-unit boundary;
    /// - a model `text` region may become `layoutSafeRegion`, giving measured
    ///   text more room without pretending a physical speech bubble exists.
    ///
    /// Existing visual/VLM bubble geometry always wins. This keeps the vision-
    /// translation path independent and makes this layer a non-destructive OCR enrichment.
    static func applyingDetectedGeometry(
        to blocks: [TextBlock],
        analysis: MangaPageAnalysis
    ) -> [TextBlock] {
        guard !blocks.isEmpty else { return blocks }
        let balloons = MangaVisionRegionPostProcessor.deduplicated(
            analysis.balloons.filter(isUsableBalloon),
            iouThreshold: 0.58,
            containmentThreshold: 0.90
        )
        let textRegions = MangaVisionRegionPostProcessor.deduplicated(
            analysis.texts.filter(isUsableTextRegion),
            iouThreshold: 0.58,
            containmentThreshold: 0.88
        )
        guard !balloons.isEmpty || !textRegions.isEmpty else { return blocks }

        return blocks.map { block in
            var enriched = block

            // OCR/VLM may already carry approximate bubble geometry. Once Koharu
            // finds the same physical balloon with an instance contour, do not mix the
            // old box with the new polygon: box, polygon and layout-safe region must all
            // come from the same model instance or their local coordinate origins diverge
            // during rendering.
            if let existingBubble = enriched.bubbleBox {
                if let matched = bestBalloon(for: enriched.boundingBox, balloons: balloons) {
                    let overlap = MangaPageCoordinateSpace.intersectionOverUnion(
                        existingBubble,
                        matched.rect
                    )
                    let containment = max(
                        MangaPageCoordinateSpace.containment(of: existingBubble, in: matched.rect),
                        MangaPageCoordinateSpace.containment(of: matched.rect, in: existingBubble)
                    )
                    if (overlap >= 0.35 || containment >= 0.70),
                       matched.polygon.count >= 3 {
                        enriched.bubbleBox = matched.rect
                        enriched.bubblePolygon = matched.polygon
                        enriched.layoutSafeRegion = balloonLayoutSafeRegion(
                            matched,
                            textRect: enriched.boundingBox
                        )
                        return enriched
                    }
                }

                // No reliable Koharu contour: retain the existing source consistently
                // rather than attaching a polygon belonging to a different rectangle.
                if enriched.layoutSafeRegion == nil {
                    enriched.layoutSafeRegion = existingBubble
                }
                return enriched
            }

            if enriched.layoutRole == .dialogue,
               let balloon = bestBalloon(for: enriched.boundingBox, balloons: balloons) {
                enriched.bubbleBox = balloon.rect
                if enriched.bubblePolygon.isEmpty {
                    enriched.bubblePolygon = balloon.polygon
                }
                if enriched.layoutSafeRegion == nil {
                    enriched.layoutSafeRegion = balloonLayoutSafeRegion(
                        balloon,
                        textRect: enriched.boundingBox
                    )
                }
                return enriched
            }

            // Do not manufacture a bubble from a text detector. A padded text
            // region is only a layout hint, useful for narration/labels and for
            // dialogue where the balloon detector genuinely found nothing.
            if enriched.layoutSafeRegion == nil,
               let safeRegion = bestTextSafeRegion(
                    for: enriched.boundingBox,
                    textRegions: textRegions
               ) {
                enriched.layoutSafeRegion = safeRegion
            }
            return enriched
        }
    }

    // Kept as a narrow compatibility name for tests/callers written during the
    // first balloon integration; it now also attaches model text safe regions.
    static func applyingBalloonGeometry(
        to blocks: [TextBlock],
        analysis: MangaPageAnalysis
    ) -> [TextBlock] {
        applyingDetectedGeometry(to: blocks, analysis: analysis)
    }

    static func bestBalloonForDiagnostics(
        textRect: CGRect,
        balloons: [MangaVisionRegion]
    ) -> CGRect? {
        bestBalloon(for: textRect, balloons: balloons)?.rect
    }

    private static func bestBalloon(
        for rawTextRect: CGRect,
        balloons: [MangaVisionRegion]
    ) -> RegionCandidate? {
        let textRect = MangaPageCoordinateSpace.clampedNormalizedRect(rawTextRect.standardized)
        guard textRect.width > 0, textRect.height > 0 else { return nil }
        let textArea = max(MangaPageCoordinateSpace.area(textRect), 0.000_001)
        let toleranceX = max(0.004, textRect.width * 0.10)
        let toleranceY = max(0.004, textRect.height * 0.10)
        let center = CGPoint(x: textRect.midX, y: textRect.midY)

        let candidates = balloons.compactMap { balloon -> RegionCandidate? in
            let rect = balloon.normalizedRect.standardized
            guard rect.width > 0, rect.height > 0 else { return nil }
            let containment = MangaPageCoordinateSpace.containment(of: textRect, in: rect)
            let centerInside = rect.insetBy(dx: -toleranceX, dy: -toleranceY).contains(center)
            // Bounding boxes from two detectors may disagree slightly. Require
            // substantial text coverage, but allow a center-confirmed partial edge.
            guard containment >= 0.55 || (centerInside && containment >= 0.30) else { return nil }

            // Keep the physical model balloon intact. Unioning an OCR text box into
            // it makes the rendered surface drift away from the original mask.
            let fitted = MangaPageCoordinateSpace.clampedNormalizedRect(rect)
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
            return RegionCandidate(
                rect: fitted,
                score: score,
                polygon: balloon.contour?.cgPoints ?? []
            )
        }.sorted { lhs, rhs in
            if abs(lhs.score - rhs.score) > 0.000_1 { return lhs.score > rhs.score }
            return MangaPageCoordinateSpace.area(lhs.rect)
                < MangaPageCoordinateSpace.area(rhs.rect)
        }

        guard let best = candidates.first else { return nil }
        if candidates.count > 1 {
            let second = candidates[1]
            let overlap = MangaPageCoordinateSpace.intersectionOverUnion(best.rect, second.rect)
            // Two unrelated balloons with almost identical assignment scores are
            // ambiguous. Refuse to invent grouping instead of joining dialogues.
            if best.score - second.score < 0.08, overlap < 0.25 {
                return nil
            }
        }
        return best
    }

    private static func balloonLayoutSafeRegion(
        _ balloon: RegionCandidate,
        textRect: CGRect
    ) -> CGRect {
        if balloon.polygon.count >= 3,
           let interior = MangaVisionPolygonLayout.interiorSafeRect(
               polygon: balloon.polygon,
               bounds: balloon.rect,
               preferredPoint: CGPoint(x: textRect.midX, y: textRect.midY)
           ) {
            return interior
        }

        let inset = balloon.rect.insetBy(
            dx: balloon.rect.width * 0.08,
            dy: balloon.rect.height * 0.08
        )
        return inset.width > 0 && inset.height > 0 ? inset : balloon.rect
    }

    private static func bestTextSafeRegion(
        for rawTextRect: CGRect,
        textRegions: [MangaVisionRegion]
    ) -> CGRect? {
        let textRect = MangaPageCoordinateSpace.clampedNormalizedRect(rawTextRect.standardized)
        guard textRect.width > 0, textRect.height > 0 else { return nil }
        let center = CGPoint(x: textRect.midX, y: textRect.midY)
        let candidates = textRegions.compactMap { region -> RegionCandidate? in
            let rect = region.normalizedRect.standardized
            let containment = MangaPageCoordinateSpace.containment(of: textRect, in: rect)
            let centerInside = rect.insetBy(dx: -0.004, dy: -0.004).contains(center)
            guard containment >= 0.45 || (centerInside && containment >= 0.25) else { return nil }

            // Text detections are normally tight. Give measured translation a
            // modest local expansion, still far smaller than a page-level card.
            let padded = MangaPageCoordinateSpace.paddedNormalizedRect(rect, fraction: 0.28)
            let fitted = MangaPageCoordinateSpace.clampedNormalizedRect(padded.union(textRect))
            let area = MangaPageCoordinateSpace.area(fitted)
            guard area > 0, area <= 0.30 else { return nil }
            let distance = hypot(fitted.midX - textRect.midX, fitted.midY - textRect.midY)
            let diagonal = max(hypot(fitted.width, fitted.height), 0.001)
            let score = containment * 3.0
                - distance / diagonal * 0.7
                - area * 0.45
                + CGFloat(region.confidence) * 0.25
            return RegionCandidate(rect: fitted, score: score, polygon: [])
        }
        return candidates.max(by: { $0.score < $1.score })?.rect
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

    private static func isUsableTextRegion(_ region: MangaVisionRegion) -> Bool {
        guard region.type == .text, region.confidence >= 0.18 else { return false }
        let rect = region.normalizedRect
        let area = MangaPageCoordinateSpace.area(rect)
        return rect.width >= 0.002
            && rect.height >= 0.002
            && area >= 0.000_02
            && area <= 0.30
    }
}

/// Single preparation boundary shared by every OCR-backed translation consumer.
///
/// The caller may replace the local OCR candidates with visually reviewed blocks, but
/// geometry enrichment, filtering, segmentation and semantic reading order are always
/// applied here afterwards. This prevents Apple Translation, cloud text translation,
/// OCR magnification and offline translation from drifting into separate page models.
nonisolated enum MangaVisionOCRTranslationPreparation {
    static func prepare(
        baseResult: OCRPipelineResult,
        candidateBlocks: [TextBlock]? = nil,
        analysis: MangaPageAnalysis?,
        safeAreaInset: Double,
        minimumTextHeight: Double,
        isRightToLeft: Bool
    ) -> OCRPipelineResult {
        let candidates = candidateBlocks ?? baseResult.resolvedBlocks
        let enrichedCandidates = analysis.map {
            MangaVisionOCRGeometry.applyingDetectedGeometry(
                to: candidates,
                analysis: $0
            )
        } ?? candidates

        let annotated = AITranslator.annotatedMangaTextBlocks(
            enrichedCandidates,
            safeAreaInset: safeAreaInset,
            minimumTextHeight: minimumTextHeight,
            isRightToLeft: isRightToLeft
        )
        let visible = annotated.filter { !$0.isFiltered }
        let filteredOut = annotated.filter(\.isFiltered)
        let segmentation = MangaTextSegmenter.segment(
            visible,
            isRightToLeft: isRightToLeft
        )

        let orderedResolved: [TextBlock]
        let orderedLines: [TextBlock]
        let orderedBubbles: [TextBlock]
        let enrichedRaw: [TextBlock]
        if let analysis {
            orderedResolved = MangaVisionOCROrdering.orderedBlocks(
                visible,
                analysis: analysis,
                isRightToLeft: isRightToLeft
            )
            orderedLines = MangaVisionOCROrdering.orderedBlocks(
                segmentation.lines,
                analysis: analysis,
                isRightToLeft: isRightToLeft
            )
            orderedBubbles = MangaVisionOCROrdering.orderedBlocks(
                segmentation.bubbles,
                analysis: analysis,
                isRightToLeft: isRightToLeft
            )
            enrichedRaw = MangaVisionOCRGeometry.applyingDetectedGeometry(
                to: baseResult.rawBlocks,
                analysis: analysis
            )
        } else {
            orderedResolved = AITranslator.sortedTextBlocks(visible, isRightToLeft: isRightToLeft)
            orderedLines = AITranslator.sortedTextBlocks(segmentation.lines, isRightToLeft: isRightToLeft)
            orderedBubbles = AITranslator.sortedTextBlocks(segmentation.bubbles, isRightToLeft: isRightToLeft)
            enrichedRaw = baseResult.rawBlocks
        }

        let visibleIDs = Set(visible.map(\.id))
        var rejectedByID: [UUID: TextBlock] = [:]
        for block in baseResult.rejectedBlocks + filteredOut where !visibleIDs.contains(block.id) {
            rejectedByID[block.id] = block
        }

        return OCRPipelineResult(
            rawBlocks: enrichedRaw,
            resolvedBlocks: orderedResolved,
            lineBlocks: orderedLines,
            bubbleBlocks: orderedBubbles,
            rejectedBlocks: AITranslator.sortedTextBlocks(
                Array(rejectedByID.values),
                isRightToLeft: isRightToLeft
            ),
            detectedLanguage: baseResult.detectedLanguage,
            quality: baseResult.quality
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
        let groups = Dictionary(grouping: ranked, by: \.panelIndex)
        return groups.keys.sorted().flatMap { rank in
            AITranslator.sortedTextBlocks(
                (groups[rank] ?? []).map(\.block),
                isRightToLeft: isRightToLeft
            )
        }
    }

    static func applyingReadingOrder(
        to result: OCRPipelineResult,
        analysis: MangaPageAnalysis,
        isRightToLeft: Bool
    ) -> OCRPipelineResult {
        // Attach detected physical balloons before segmentation. This is the key
        // boundary that turns several Japanese vertical OCR columns inside one
        // speech balloon into one translation unit instead of several grey cards.
        let enrichedResolved = MangaVisionOCRGeometry.applyingDetectedGeometry(
            to: result.resolvedBlocks,
            analysis: analysis
        )
        let segmentation = MangaTextSegmenter.segment(
            enrichedResolved,
            isRightToLeft: isRightToLeft
        )
        return OCRPipelineResult(
            rawBlocks: MangaVisionOCRGeometry.applyingDetectedGeometry(
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

