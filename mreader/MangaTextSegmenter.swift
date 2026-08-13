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
        let smaller = min(fontScale(lhs), fontScale(rhs))
        let larger = max(fontScale(lhs), fontScale(rhs))
        guard larger / max(smaller, 0.000_1) <= 1.25 else { return false }
        return OCRCandidateResolver.colorsAreCompatible(lhs.textColorHex, rhs.textColorHex)
    }

    private static func mergedBlock(from blocks: [TextBlock], isRightToLeft: Bool) -> TextBlock {
        guard blocks.count > 1 else { return blocks[0] }
        let ordered = AITranslator.sortedTextBlocks(blocks, isRightToLeft: isRightToLeft)
        let bounds = ordered.dropFirst().reduce(ordered[0].boundingBox) { $0.union($1.boundingBox) }
        let scale = ordered.reduce(0) { $0 + $1.estimatedFontScale } / Double(ordered.count)
        let confidence = ordered.reduce(0) { $0 + $1.confidence } / Double(ordered.count)
        let sources = Array(Set(ordered.map(\.ocrSource))).sorted().joined(separator: "+")
        return TextBlock(
            id: ordered[0].id,
            text: ordered.map(\.text).reduce("", joinedText),
            boundingBox: bounds,
            confidence: confidence,
            ocrSource: sources,
            estimatedFontScale: scale,
            textColorHex: ordered.compactMap(\.textColorHex).first,
            polygon: ordered.flatMap(\.polygon)
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
        block.boundingBox.height > block.boundingBox.width * 1.35
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
