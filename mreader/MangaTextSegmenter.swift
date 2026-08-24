import CoreGraphics
import Foundation

nonisolated struct MangaTextSegmentation: Sendable {
    let lines: [TextBlock]
    let bubbles: [TextBlock]
}

nonisolated enum MangaTextSegmenter {
    static func segment(
        _ blocks: [TextBlock],
        isRightToLeft: Bool
    ) -> MangaTextSegmentation {
        let sorted = AITranslator.sortedTextBlocks(
            OCRCandidateResolver.resolve(blocks, isRightToLeft: isRightToLeft).resolvedBlocks,
            isRightToLeft: isRightToLeft
        )
        guard sorted.count > 1 else {
            return MangaTextSegmentation(lines: sorted, bubbles: sorted)
        }

        let lineGroups = completeLinkGroups(sorted, relation: canShareLine)
        let lines = lineGroups.map { mergedBlock(from: $0, isRightToLeft: isRightToLeft) }
        let bubbleGroups = completeLinkGroups(
            AITranslator.sortedTextBlocks(lines, isRightToLeft: isRightToLeft),
            relation: canShareBubble
        )
        let bubbles = bubbleGroups.map { mergedBlock(from: $0, isRightToLeft: isRightToLeft) }
        return MangaTextSegmentation(
            lines: AITranslator.sortedTextBlocks(lines, isRightToLeft: isRightToLeft),
            bubbles: AITranslator.sortedTextBlocks(bubbles, isRightToLeft: isRightToLeft)
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

    private static func canShareBubble(_ lhs: TextBlock, _ rhs: TextBlock) -> Bool {
        guard stylesAreCompatible(lhs, rhs) else { return false }
        // 只有视觉链路才携带真实 bubbleBox。两端都有且明确指向不同气泡时，不能再仅凭
        // 文字距离把相邻对白合并；任一端没有视觉信息则保留纯 OCR 的既有行为。
        guard visualBubbleBoxesAreCompatible(lhs.bubbleBox, rhs.bubbleBox) else { return false }
        let left = lhs.boundingBox
        let right = rhs.boundingBox
        let union = left.union(right)
        guard union.width <= 0.65, union.height <= 0.48 else { return false }
        let scale = min(fontScale(lhs), fontScale(rhs))
        let leftVertical = isVertical(lhs)
        let rightVertical = isVertical(rhs)
        guard leftVertical == rightVertical else { return false }

        if leftVertical {
            let horizontalGap = gap(left.minX, left.maxX, right.minX, right.maxX)
            let overlap = overlapLength(left.minY, left.maxY, right.minY, right.maxY)
            let overlapRatio = overlap / max(min(left.height, right.height), 0.000_1)
            return horizontalGap <= scale * 0.72 && overlapRatio >= 0.35
        }

        let verticalGap = gap(left.minY, left.maxY, right.minY, right.maxY)
        let overlap = overlapLength(left.minX, left.maxX, right.minX, right.maxX)
        let overlapRatio = overlap / max(min(left.width, right.width), 0.000_1)
        let centerTolerance = max(min(left.width, right.width) * 0.55, scale * 1.2)
        return verticalGap <= scale * 0.62
            && (overlapRatio >= 0.2 || abs(left.midX - right.midX) <= centerTolerance)
    }

    private static func stylesAreCompatible(_ lhs: TextBlock, _ rhs: TextBlock) -> Bool {
        guard lhs.layoutRole == rhs.layoutRole else { return false }
        let smaller = min(fontScale(lhs), fontScale(rhs))
        let larger = max(fontScale(lhs), fontScale(rhs))
        guard larger / max(smaller, 0.000_1) <= 1.25 else { return false }
        return OCRCandidateResolver.colorsAreCompatible(lhs.textColorHex, rhs.textColorHex)
    }

    private static func mergedBlock(from blocks: [TextBlock], isRightToLeft: Bool) -> TextBlock {
        guard blocks.count > 1 else { return blocks[0] }
        let ordered = AITranslator.sortedTextBlocks(blocks, isRightToLeft: isRightToLeft)
        let bounds = ordered.dropFirst().reduce(ordered[0].boundingBox) { $0.union($1.boundingBox) }
        // The merged rectangle's long axis is line length, not glyph size. A
        // median of the source glyph estimates remains stable when one OCR
        // observation has an over-sized crop or a rotated axis-aligned box.
        let sortedScales = ordered.map(\.estimatedFontScale).sorted()
        let scale = sortedScales[sortedScales.count / 2]
        let confidence = ordered.reduce(0) { $0 + $1.confidence } / Double(ordered.count)
        let sources = Array(Set(ordered.map(\.ocrSource))).sorted().joined(separator: "+")
        let selectedBubble = selectedVisualBubble(from: ordered, containing: bounds)
        return TextBlock(
            id: ordered[0].id,
            text: ordered.map(\.text).reduce("", joinedText),
            boundingBox: bounds,
            confidence: confidence,
            ocrSource: sources,
            estimatedFontScale: scale,
            textColorHex: ordered.compactMap(\.textColorHex).first,
            bubbleBox: selectedBubble?.box,
            polygon: ordered.flatMap(\.polygon),
            bubblePolygon: selectedBubble?.polygon ?? [],
            textOrientation: ordered[0].textOrientation,
            layoutRole: ordered[0].layoutRole
        )
    }

    /// 不把多个视觉 bubbleBox 做 union：不同对白一旦被误合并，union 会扩大成遮挡漫画的
    /// 大框。只有候选本身能在小容差下容纳合并后的 textBox 时才保留，并优先最小真实气泡。
    private static func selectedVisualBubble(
        from blocks: [TextBlock],
        containing textBounds: CGRect
    ) -> (box: CGRect, polygon: [CGPoint])? {
        OCRCandidateResolver.validatedBubbleGeometry(
            for: textBounds,
            candidates: blocks
        )
    }

    /// 两个视觉框没有可观重叠、也不在小容差下相互包含，说明它们已经是不同漫画气泡。
    /// 这项约束只在两端都有视觉结果时生效，不能改变纯 OCR 的距离分组策略。
    private static func visualBubbleBoxesAreCompatible(_ lhs: CGRect?, _ rhs: CGRect?) -> Bool {
        guard let lhs, let rhs else { return true }
        let tolerance: CGFloat = 0.006
        if lhs.insetBy(dx: -tolerance, dy: -tolerance).contains(rhs)
            || rhs.insetBy(dx: -tolerance, dy: -tolerance).contains(lhs) {
            return true
        }
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return false }
        let unionArea = lhs.width * lhs.height + rhs.width * rhs.height
            - intersection.width * intersection.height
        let iou = unionArea > 0 ? intersection.width * intersection.height / unionArea : 0
        return iou >= 0.18
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

    private static func gap(_ firstMin: CGFloat, _ firstMax: CGFloat, _ secondMin: CGFloat, _ secondMax: CGFloat) -> CGFloat {
        max(0, max(firstMin, secondMin) - min(firstMax, secondMax))
    }

    private static func overlapLength(_ firstMin: CGFloat, _ firstMax: CGFloat, _ secondMin: CGFloat, _ secondMax: CGFloat) -> CGFloat {
        max(0, min(firstMax, secondMax) - max(firstMin, secondMin))
    }
}
