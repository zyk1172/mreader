import CoreGraphics
import Foundation

/// Vision 可能把同一气泡的多行文字合并成一个 item，而 Apple OCR 会返回多条 line。
/// 这里按“一个 Vision block 对应一组 local line block”匹配并合并几何。
nonisolated enum TranslationGeometryRefiner {
    static func refine(
        visionBlocks: [TextBlock],
        localOCRBlocks: [TextBlock],
        isRightToLeft: Bool
    ) -> [TextBlock] {
        guard !visionBlocks.isEmpty, !localOCRBlocks.isEmpty else { return visionBlocks }

        var availableLocalIndexes = Set(localOCRBlocks.indices)
        let orderedVision = AITranslator.sortedTextBlocks(visionBlocks, isRightToLeft: isRightToLeft)

        return orderedVision.map { vision in
            let matches = matchingIndexes(
                for: vision,
                among: localOCRBlocks,
                availableIndexes: availableLocalIndexes
            )
            guard !matches.isEmpty else { return vision }
            availableLocalIndexes.subtract(matches)

            let locals = matches.map { localOCRBlocks[$0] }
            let localBounds = locals.dropFirst().reduce(locals[0].boundingBox) { $0.union($1.boundingBox) }
            let inheritedLayoutRole: TranslationLayoutRole =
                vision.layoutRole == .standalone || locals.contains(where: {
                    $0.layoutRole == .standalone
                }) ? .standalone : .dialogue
            return TextBlock(
                id: vision.id,
                text: vision.text,
                boundingBox: localBounds,
                translation: vision.translation,
                confidence: max(vision.confidence, locals.map(\.confidence).max() ?? 0),
                ocrSource: "\(vision.ocrSource)+local-geometry",
                isFiltered: vision.isFiltered,
                filterReason: vision.filterReason,
                estimatedFontScale: weightedMedianFontScale(locals),
                textColorHex: locals.compactMap(\.textColorHex).first ?? vision.textColorHex,
                bubbleBox: vision.bubbleBox,
                polygon: locals.flatMap(\.polygon).isEmpty ? vision.polygon : locals.flatMap(\.polygon),
                bubblePolygon: vision.bubblePolygon,
                translationLines: vision.translationLines,
                textOrientation: majorityOrientation(locals),
                layoutRole: inheritedLayoutRole
            )
        }
    }

    private static func matchingIndexes(
        for vision: TextBlock,
        among localBlocks: [TextBlock],
        availableIndexes: Set<Int>
    ) -> Set<Int> {
        let expandedVision = vision.boundingBox.insetBy(
            dx: -max(vision.boundingBox.width * 0.35, 0.025),
            dy: -max(vision.boundingBox.height * 0.75, 0.04)
        )
        let candidates = availableIndexes.compactMap { index -> (index: Int, score: CGFloat, text: CGFloat, insideExpanded: Bool)? in
            let local = localBlocks[index]
            let text = textSimilarity(vision.text, local.text)
            let overlap = intersectionOverUnion(vision.boundingBox, local.boundingBox)
            let distance = normalizedCenterDistance(vision.boundingBox, local.boundingBox)
            let insideExpanded = !expandedVision.intersection(local.boundingBox).isNull
            let spatial = insideExpanded || distance <= 0.30
            guard spatial, text >= 0.20 || overlap >= 0.30 else { return nil }
            let proximity = max(0, 1 - distance / 0.30)
            return (index, text * 0.62 + overlap * 0.23 + proximity * 0.15, text, insideExpanded)
        }

        guard let strongest = candidates.max(by: { $0.score < $1.score }) else { return [] }
        // 强匹配或多个短 line 同时命中时，允许把同一 Vision 框内的 line 一并纳入。
        if strongest.text >= 0.55 || candidates.count > 1 {
            return Set(candidates.filter { candidate in
                candidate.text >= 0.20 && (
                    candidate.insideExpanded
                        || candidate.index == strongest.index
                )
            }.map(\.index))
        }
        return [strongest.index]
    }

    private static func majorityOrientation(_ blocks: [TextBlock]) -> TextOrientation {
        let horizontalWeight = blocks.filter { $0.textOrientation == .horizontal }
            .reduce(0.0) { $0 + max(Double($1.boundingBox.width * $1.boundingBox.height), 0.000_1) }
        let verticalWeight = blocks.filter { $0.textOrientation == .vertical }
            .reduce(0.0) { $0 + max(Double($1.boundingBox.width * $1.boundingBox.height), 0.000_1) }
        return horizontalWeight >= verticalWeight ? .horizontal : .vertical
    }

    private static func weightedMedianFontScale(_ blocks: [TextBlock]) -> Double {
        let values = blocks.map { block in
            (value: block.estimatedFontScale, weight: max(Double(block.boundingBox.width * block.boundingBox.height), 0.000_1))
        }.sorted { $0.value < $1.value }
        let target = values.reduce(0) { $0 + $1.weight } / 2
        var cumulative = 0.0
        for value in values {
            cumulative += value.weight
            if cumulative >= target { return value.value }
        }
        return values.last?.value ?? 0
    }

    private static func normalizedCenterDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        hypot(lhs.midX - rhs.midX, lhs.midY - rhs.midY)
    }

    private static func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        let union = lhs.width * lhs.height + rhs.width * rhs.height - intersection.width * intersection.height
        return union > 0 ? intersection.width * intersection.height / union : 0
    }

    private static func textSimilarity(_ lhs: String, _ rhs: String) -> CGFloat {
        let left = normalizedText(lhs)
        let right = normalizedText(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        if left == right { return 1 }
        if left.contains(right) || right.contains(left) {
            return CGFloat(min(left.count, right.count)) / CGFloat(max(left.count, right.count))
        }
        let leftScalars = Array(left.unicodeScalars)
        let rightScalars = Array(right.unicodeScalars)
        return CGFloat(longestCommonSubsequenceLength(leftScalars, rightScalars))
            / CGFloat(max(leftScalars.count, rightScalars.count))
    }

    private static func normalizedText(_ text: String) -> String {
        text.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
                || (0x3400...0x9FFF).contains($0.value)
                || (0x3040...0x30FF).contains($0.value)
                || (0xAC00...0xD7AF).contains($0.value)
        }.map(String.init).joined()
    }

    private static func longestCommonSubsequenceLength(
        _ lhs: [Unicode.Scalar],
        _ rhs: [Unicode.Scalar]
    ) -> Int {
        var previous = Array(repeating: 0, count: rhs.count + 1)
        for left in lhs {
            var current = Array(repeating: 0, count: rhs.count + 1)
            for (index, right) in rhs.enumerated() {
                current[index + 1] = left == right
                    ? previous[index] + 1
                    : max(previous[index + 1], current[index])
            }
            previous = current
        }
        return previous[rhs.count]
    }
}
