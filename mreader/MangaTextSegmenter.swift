import CoreGraphics
import Foundation

nonisolated struct MangaTextSegmentation: Sendable {
    let lines: [TextBlock]
    let bubbles: [TextBlock]
}
nonisolated enum MangaTextSegmenter {
    /// A canonical region is created only from a validated bubbleBox. OCR lines
    /// are assigned to the region afterwards; line spacing and line count never
    /// decide how many translation requests the region produces.
    private struct DetectedBubbleRegion {
        let id: UUID
        var rect: CGRect
        var polygon: [CGPoint]
        var lines: [TextBlock]
    }

    static func segment(
        _ blocks: [TextBlock],
        isRightToLeft: Bool
    ) -> MangaTextSegmentation {
        let sorted = AITranslator.sortedTextBlocks(
            OCRCandidateResolver.resolve(blocks, isRightToLeft: isRightToLeft).resolvedBlocks,
            isRightToLeft: isRightToLeft
        )

        let lineGroups = completeLinkGroups(sorted, relation: canShareLine)
        let lines = lineGroups.map { group in
            // Complete-link grouping here merges OCR observations that belong to
            // one physical source line. It is not the bubble grouping step.
            mergedBlock(
                from: group,
                isRightToLeft: isRightToLeft,
                sourceLineCount: 1
            )
        }
        let orderedLines = AITranslator.sortedTextBlocks(
            lines,
            isRightToLeft: isRightToLeft
        )
        let bubbles = canonicalBubbleBlocks(
            from: orderedLines,
            isRightToLeft: isRightToLeft
        )

        return MangaTextSegmentation(
            lines: orderedLines,
            bubbles: bubbles
        )
    }

    private static func completeLinkGroups(
        _ blocks: [TextBlock],
        relation: (TextBlock, TextBlock) -> Bool
    ) -> [[TextBlock]] {
        var groups: [[TextBlock]] = []
        for block in blocks {
            if let index = groups.firstIndex(where: { group in
                group.allSatisfy { relation($0, block) }
            }) {
                groups[index].append(block)
            } else {
                groups.append([block])
            }
        }
        return groups
    }

    /// Builds translation units from canonical bubble regions and measured
    /// paragraphs.
    ///
    /// Reliable bubble geometry is the grouping boundary:
    ///
    /// 1. deduplicate overlapping detections that describe the same physical bubble;
    /// 2. attach every local OCR line whose textBox is inside that region;
    /// 3. merge the region lines in reading order;
    /// 4. cluster the remaining OCR lines into conservative measured-text
    ///    paragraphs without inventing a bubbleBox.
    ///
    /// A measured paragraph is a translation unit, not a synthetic bubble. Its
    /// lines may be merged when they are adjacent source text, but the result
    /// keeps bubbleBox == nil and therefore continues to use measured-text
    /// surface geometry.
    private static func canonicalBubbleBlocks(
        from lines: [TextBlock],
        isRightToLeft: Bool
    ) -> [TextBlock] {
        var regions: [DetectedBubbleRegion] = []
        var unassignedLines: [TextBlock] = []

        for line in lines {
            guard let geometry = reliableBubbleGeometry(for: line) else {
                unassignedLines.append(line)
                continue
            }

            if let index = regions.firstIndex(where: {
                canonicalBubbleBoxesRepresentSame($0.rect, geometry.box)
            }) {
                regions[index].lines.append(line)
                // Keep the original canonical rectangle when both detections
                // are numerically identical. CGRect.union can turn a literal
                // 0.42 width into 0.42000000000000004, which needlessly changes
                // the persisted/rendered geometry. Only expand for actual drift.
                if regions[index].rect != geometry.box {
                    regions[index].rect = regions[index].rect.union(geometry.box)
                }
                if regions[index].polygon.isEmpty, !geometry.polygon.isEmpty {
                    regions[index].polygon = geometry.polygon
                }
            } else {
                regions.append(
                    DetectedBubbleRegion(
                        id: line.id,
                        rect: geometry.box,
                        polygon: geometry.polygon,
                        lines: [line]
                    )
                )
            }
        }

        var measuredTextLines: [TextBlock] = []
        for line in unassignedLines {
            let candidates = regions.indices.filter {
                bubbleContainsText(regions[$0].rect, line.boundingBox)
            }
            guard let selected = candidates.min(by: {
                regionAssignmentPrecedes(regions[$0], regions[$1], for: line)
            }) else {
                measuredTextLines.append(line)
                continue
            }
            regions[selected].lines.append(line)
        }

        var units: [TextBlock] = []
        for region in regions {
            let regionLines = AITranslator.sortedTextBlocks(
                region.lines,
                isRightToLeft: isRightToLeft
            )
            let sourceLineCount = regionLines.reduce(0) { total, line in
                total + max(line.sourceLineCount, 1)
            }
            units.append(
                mergedBlock(
                    from: regionLines,
                    isRightToLeft: isRightToLeft,
                    sourceLineCount: sourceLineCount,
                    bubbleRegion: region
                )
            )
        }
        units.append(contentsOf: clusterMeasuredParagraphs(
            measuredTextLines,
            isRightToLeft: isRightToLeft
        ))

        return AITranslator.sortedTextBlocks(
            units,
            isRightToLeft: isRightToLeft
        )
    }

    /// Groups OCR lines that form one continuous paragraph while deliberately
    /// avoiding any claim that the paragraph is a comic bubble. This is the
    /// measured-text fallback for Apple/native OCR, whose line observations do
    /// not carry reliable bubble geometry.
    private static func clusterMeasuredParagraphs(
        _ lines: [TextBlock],
        isRightToLeft: Bool
    ) -> [TextBlock] {
        let ordered = AITranslator.sortedTextBlocks(
            lines,
            isRightToLeft: isRightToLeft
        )
        guard ordered.count > 1 else { return ordered }

        var groups: [[TextBlock]] = []
        for line in ordered {
            guard var last = groups.last,
                  let previous = last.last,
                  canAppendMeasuredParagraphLine(
                      previous,
                      line,
                      currentGroup: last,
                      isRightToLeft: isRightToLeft
                  ) else {
                groups.append([line])
                continue
            }

            last.append(line)
            groups[groups.count - 1] = last
        }

        return groups.map { group in
            guard group.count > 1 else { return group[0] }
            let sourceLineCount = group.reduce(0) { total, line in
                total + max(line.sourceLineCount, 1)
            }
            return mergedBlock(
                from: group,
                isRightToLeft: isRightToLeft,
                sourceLineCount: sourceLineCount
            )
        }
    }

    /// Adjacent-line paragraph relation. The relation is intentionally based
    /// on the previous accepted line instead of complete-linking against the
    /// entire group: real bubbles and paragraphs often have modest line-gap
    /// variation from one line to the next.
    private static func canAppendMeasuredParagraphLine(
        _ previous: TextBlock,
        _ current: TextBlock,
        currentGroup: [TextBlock],
        isRightToLeft: Bool
    ) -> Bool {
        // Without a reliable bubble region, vertical OCR columns are
        // ambiguous: adjacent columns share the same vertical projection and
        // can look like one paragraph. Keep them as independent measured-text
        // units rather than guessing across manga reading columns.
        guard !isVertical(previous) else { return false }
        guard stylesAreCompatible(previous, current),
              previous.textOrientation == current.textOrientation,
              followsReadingOrder(previous, current, isRightToLeft: isRightToLeft),
              projectionsAreAligned(previous, current) else {
            return false
        }

        let smallerScale = min(fontScale(previous), fontScale(current))
        let lineGap: CGFloat
        if isVertical(previous) {
            lineGap = gap(
                previous.boundingBox.minX,
                previous.boundingBox.maxX,
                current.boundingBox.minX,
                current.boundingBox.maxX
            )
        } else {
            lineGap = gap(
                previous.boundingBox.minY,
                previous.boundingBox.maxY,
                current.boundingBox.minY,
                current.boundingBox.maxY
            )
        }
        // A gap around one line height is common in comic lettering. The
        // slightly wider continuation window handles a third line whose
        // spacing differs from the first pair, while 1.5x remains a useful
        // guard against merging adjacent independent bubbles.
        let maximumGap = max(smallerScale * 1.35, 0.006)
        guard lineGap <= maximumGap else { return false }

        let union = currentGroup.dropFirst().reduce(currentGroup[0].boundingBox) {
            $0.union($1.boundingBox)
        }.union(current.boundingBox)
        guard union.width <= 0.82,
              union.height <= 0.48 else {
            return false
        }
        return true
    }

    private static func followsReadingOrder(
        _ previous: TextBlock,
        _ current: TextBlock,
        isRightToLeft: Bool
    ) -> Bool {
        let tolerance: CGFloat = 0.006
        if isVertical(previous) {
            if isRightToLeft {
                return current.boundingBox.maxX <= previous.boundingBox.minX + tolerance
            }
            return current.boundingBox.minX >= previous.boundingBox.maxX - tolerance
        }
        return current.boundingBox.minY >= previous.boundingBox.minY - tolerance
    }

    private static func projectionsAreAligned(
        _ lhs: TextBlock,
        _ rhs: TextBlock
    ) -> Bool {
        let left = lhs.boundingBox
        let right = rhs.boundingBox
        let (first, second): (ClosedRange<CGFloat>, ClosedRange<CGFloat>)
        if isVertical(lhs) {
            first = left.minY...left.maxY
            second = right.minY...right.maxY
        } else {
            first = left.minX...left.maxX
            second = right.minX...right.maxX
        }

        let overlap = max(
            0,
            min(first.upperBound, second.upperBound)
                - max(first.lowerBound, second.lowerBound)
        )
        let smallerExtent = max(
            min(first.upperBound - first.lowerBound, second.upperBound - second.lowerBound),
            0.000_001
        )
        if overlap / smallerExtent >= 0.20 {
            return true
        }

        let firstCenter = (first.lowerBound + first.upperBound) * 0.5
        let secondCenter = (second.lowerBound + second.upperBound) * 0.5
        let smallerScale = min(fontScale(lhs), fontScale(rhs))
        return abs(firstCenter - secondCenter) <= max(smallerScale * 3.0, 0.018)
    }

    private static func reliableBubbleGeometry(
        for block: TextBlock
    ) -> (box: CGRect, polygon: [CGPoint])? {
        OCRCandidateResolver.validatedBubbleGeometry(
            for: block.boundingBox,
            candidates: [block]
        )
    }

    /// Same-region matching is deliberately more tolerant than line-level
    /// identity. A small geometry drift from two OCR/vision passes must not turn
    /// one physical bubble into multiple translation requests. Large one-way
    /// containment remains separate because it commonly means nested detections.
    private static func canonicalBubbleBoxesRepresentSame(
        _ lhs: CGRect,
        _ rhs: CGRect
    ) -> Bool {
        let left = lhs.standardized
        let right = rhs.standardized
        guard rectIsFinite(left),
              rectIsFinite(right),
              left.width > 0,
              left.height > 0,
              right.width > 0,
              right.height > 0 else {
            return false
        }

        let leftArea = rectArea(left)
        let rightArea = rectArea(right)
        let smallerArea = max(min(leftArea, rightArea), 0.000_001)
        let areaRatio = max(leftArea, rightArea) / smallerArea
        let widthRatio = max(left.width, right.width)
            / max(min(left.width, right.width), 0.000_001)
        let heightRatio = max(left.height, right.height)
            / max(min(left.height, right.height), 0.000_001)
        guard areaRatio <= 1.80,
              widthRatio <= 1.60,
              heightRatio <= 1.60 else {
            return false
        }

        let intersection = left.intersection(right)
        guard !intersection.isNull,
              intersection.width > 0,
              intersection.height > 0 else {
            return false
        }
        let intersectionArea = rectArea(intersection)
        let unionArea = leftArea + rightArea - intersectionArea
        let iou = unionArea > 0 ? intersectionArea / unionArea : 0
        guard iou >= 0.45 else { return false }

        let minimumDimension = min(
            min(left.width, right.width),
            min(left.height, right.height)
        )
        let centerDistance = hypot(
            left.midX - right.midX,
            left.midY - right.midY
        )
        guard centerDistance <= max(minimumDimension * 0.75, 0.020) else {
            return false
        }

        let tolerance: CGFloat = 0.006
        let leftContainsRight = left.insetBy(
            dx: -tolerance,
            dy: -tolerance
        ).contains(right)
        let rightContainsLeft = right.insetBy(
            dx: -tolerance,
            dy: -tolerance
        ).contains(left)

        // A large one-way containment is more likely to be an outer false
        // detection plus an inner bubble than jitter from one region.
        if leftContainsRight != rightContainsLeft, areaRatio > 1.45 {
            return false
        }
        return true
    }

    private static func regionAssignmentPrecedes(
        _ lhs: DetectedBubbleRegion,
        _ rhs: DetectedBubbleRegion,
        for line: TextBlock
    ) -> Bool {
        let lhsArea = rectArea(lhs.rect)
        let rhsArea = rectArea(rhs.rect)
        if abs(lhsArea - rhsArea) > 0.000_001 {
            // Prefer the smallest containing region when detections overlap.
            return lhsArea < rhsArea
        }

        let lhsDistance = hypot(
            lhs.rect.midX - line.boundingBox.midX,
            lhs.rect.midY - line.boundingBox.midY
        )
        let rhsDistance = hypot(
            rhs.rect.midX - line.boundingBox.midX,
            rhs.rect.midY - line.boundingBox.midY
        )
        return lhsDistance < rhsDistance
    }

    private static func rectArea(_ rect: CGRect) -> CGFloat {
        max(rect.width, 0) * max(rect.height, 0)
    }

    private static func rectIsFinite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite
            && rect.origin.y.isFinite
            && rect.size.width.isFinite
            && rect.size.height.isFinite
    }

    private static func canShareLine(_ lhs: TextBlock, _ rhs: TextBlock) -> Bool {
        guard stylesAreCompatible(lhs, rhs) else { return false }
        let left = lhs.boundingBox
        let right = rhs.boundingBox
        let scale = min(fontScale(lhs), fontScale(rhs))
        let leftVertical = isVertical(lhs)
        let rightVertical = isVertical(rhs)
        guard leftVertical == rightVertical else { return false }

        if leftVertical {
            let verticalGap = gap(left.minY, left.maxY, right.minY, right.maxY)
            return abs(left.midX - right.midX) <= scale * 0.55
                && verticalGap <= scale * 0.45
        }

        let horizontalGap = gap(left.minX, left.maxX, right.minX, right.maxX)
        return abs(left.midY - right.midY) <= scale * 0.55
            && horizontalGap <= scale * 0.45
    }

    private static func stylesAreCompatible(_ lhs: TextBlock, _ rhs: TextBlock) -> Bool {
        guard lhs.layoutRole == rhs.layoutRole else { return false }
        let smaller = min(fontScale(lhs), fontScale(rhs))
        let larger = max(fontScale(lhs), fontScale(rhs))
        guard larger / max(smaller, 0.000_1) <= 1.25 else { return false }
        return OCRCandidateResolver.colorsAreCompatible(lhs.textColorHex, rhs.textColorHex)
    }

    private static func mergedBlock(
        from blocks: [TextBlock],
        isRightToLeft: Bool,
        sourceLineCount: Int,
        bubbleRegion: DetectedBubbleRegion? = nil
    ) -> TextBlock {
        guard let first = blocks.first else {
            preconditionFailure("Cannot merge an empty OCR block group")
        }
        guard blocks.count > 1 || bubbleRegion != nil else {
            return first
        }

        let ordered = AITranslator.sortedTextBlocks(
            blocks,
            isRightToLeft: isRightToLeft
        )
        let bounds = ordered.dropFirst().reduce(ordered[0].boundingBox) {
            $0.union($1.boundingBox)
        }
        // The merged rectangle represents source text geometry. Font scale is
        // kept on the short glyph axis and is not inferred from the union span.
        let sortedScales = ordered.map(\.estimatedFontScale).sorted()
        let scale = sortedScales[sortedScales.count / 2]
        let confidence = ordered.reduce(0) { $0 + $1.confidence }
            / Double(ordered.count)
        let sources = Array(Set(ordered.map(\.ocrSource)))
            .sorted()
            .joined(separator: "+")
        let selectedBubble: (box: CGRect, polygon: [CGPoint])?
        if let bubbleRegion {
            selectedBubble = (bubbleRegion.rect, bubbleRegion.polygon)
        } else {
            selectedBubble = selectedVisualBubble(
                from: ordered,
                containing: bounds
            )
        }

        let safeCandidates = ordered.compactMap(\.layoutSafeRegion)
        let proposedSafeRegion: CGRect? = safeCandidates.isEmpty
            ? nil
            : safeCandidates.dropFirst().reduce(safeCandidates[0]) { $0.union($1) }
        let mergedSafeRegion = TranslationRegionPolicy.resolvedLayoutSafeRegion(
            sourceTextRegion: bounds,
            proposedSafeRegion: proposedSafeRegion,
            detectedBubble: selectedBubble?.box,
            pageBounds: CGRect(x: 0, y: 0, width: 1, height: 1)
        ) ?? selectedBubble?.box

        return TextBlock(
            id: ordered[0].id,
            text: ordered.map(\.text).reduce("", joinedText),
            boundingBox: bounds,
            confidence: confidence,
            ocrSource: sources,
            estimatedFontScale: scale,
            textColorHex: ordered.compactMap(\.textColorHex).first,
            bubbleBox: selectedBubble?.box,
            layoutSafeRegion: mergedSafeRegion,
            polygon: ordered.flatMap(\.polygon),
            bubblePolygon: selectedBubble?.polygon ?? [],
            textOrientation: ordered[0].textOrientation,
            layoutRole: ordered[0].layoutRole,
            sourceLineCount: max(sourceLineCount, 1)
        )
    }

    /// A line-level merge may still have several visual observations. Keep a
    /// validated candidate instead of unioning independent bubble regions.
    private static func selectedVisualBubble(
        from blocks: [TextBlock],
        containing textBounds: CGRect
    ) -> (box: CGRect, polygon: [CGPoint])? {
        OCRCandidateResolver.validatedBubbleGeometry(
            for: textBounds,
            candidates: blocks
        )
    }

    private static func joinedText(_ lhs: String, _ rhs: String) -> String {
        let left = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty else { return right }
        guard !right.isEmpty else { return left }
        if left.hasSuffix("-") { return String(left.dropLast()) + right }
        if containsHanOrKana(left) || containsHanOrKana(right) { return left + right }
        let noSpaceBefore = CharacterSet(charactersIn: ".,!?;:)]}」』》）！？。，、；：")
        if let first = right.unicodeScalars.first, noSpaceBefore.contains(first) {
            return left + right
        }
        return left + " " + right
    }

    private static func containsHanOrKana(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x3400...0x9FFF).contains(scalar.value)
                || (0x3040...0x30FF).contains(scalar.value)
        }
    }

    private static func isVertical(_ block: TextBlock) -> Bool {
        block.textOrientation == .vertical
    }

    private static func fontScale(_ block: TextBlock) -> CGFloat {
        max(CGFloat(block.estimatedFontScale), 0.001)
    }

    private static func gap(
        _ firstMin: CGFloat,
        _ firstMax: CGFloat,
        _ secondMin: CGFloat,
        _ secondMax: CGFloat
    ) -> CGFloat {
        max(0, max(firstMin, secondMin) - min(firstMax, secondMax))
    }

    private static func bubbleContainsText(_ bubble: CGRect, _ text: CGRect) -> Bool {
        let normalizedBubble = bubble.standardized
        let normalizedText = text.standardized
        guard normalizedBubble.width > 0,
              normalizedBubble.height > 0,
              normalizedText.width > 0,
              normalizedText.height > 0 else {
            return false
        }
        // Mapping from visual verification and local OCR can differ by a small
        // normalized edge amount; this is only for line-to-region assignment.
        let tolerance = max(
            0.006,
            min(0.020, min(normalizedBubble.width, normalizedBubble.height) * 0.08)
        )
        return normalizedBubble
            .insetBy(dx: -tolerance, dy: -tolerance)
            .contains(normalizedText)
    }
}
