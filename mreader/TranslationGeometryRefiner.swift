import CoreGraphics
import Foundation

/// 视觉模型负责识别/翻译，本地 OCR 只校准文字几何。
///
/// 保留模型给出的译文、气泡范围与阅读顺序；当同一文字能和本地 OCR 匹配时，
/// 用本地的 textBox、字号尺度及可用颜色替换模型几何，避免模型坐标漂移影响排版。
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
            guard let matchIndex = bestMatch(
                for: vision,
                among: localOCRBlocks,
                availableIndexes: availableLocalIndexes
            ) else {
                return vision
            }
            availableLocalIndexes.remove(matchIndex)
            let local = localOCRBlocks[matchIndex]
            return TextBlock(
                id: vision.id,
                text: vision.text,
                boundingBox: local.boundingBox,
                translation: vision.translation,
                confidence: max(vision.confidence, local.confidence),
                ocrSource: "\(vision.ocrSource)+local-geometry",
                isFiltered: vision.isFiltered,
                filterReason: vision.filterReason,
                estimatedFontScale: local.estimatedFontScale,
                textColorHex: local.textColorHex ?? vision.textColorHex,
                bubbleBox: vision.bubbleBox,
                polygon: local.polygon.isEmpty ? vision.polygon : local.polygon,
                bubblePolygon: vision.bubblePolygon,
                translationLines: vision.translationLines
            )
        }
    }

    private static func bestMatch(
        for vision: TextBlock,
        among localBlocks: [TextBlock],
        availableIndexes: Set<Int>
    ) -> Int? {
        let candidates = availableIndexes.compactMap { index -> (Int, CGFloat)? in
            let local = localBlocks[index]
            let text = textSimilarity(vision.text, local.text)
            let overlap = intersectionOverUnion(vision.boundingBox, local.boundingBox)
            let distance = normalizedCenterDistance(vision.boundingBox, local.boundingBox)
            let proximity = max(0, 1 - distance / 0.28)
            let score = text * 0.58 + overlap * 0.30 + proximity * 0.12

            // OCR 文本完全不同且空间上也没有证据时，不把错误几何套到译文上。
            guard score >= 0.46,
                  text >= 0.38 || (overlap >= 0.52 && distance <= 0.10) else {
                return nil
            }
            return (index, score)
        }
        return candidates.max { lhs, rhs in lhs.1 < rhs.1 }?.0
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
        let common = longestCommonSubsequenceLength(leftScalars, rightScalars)
        return CGFloat(common) / CGFloat(max(leftScalars.count, rightScalars.count))
    }

    private static func normalizedText(_ text: String) -> String {
        text
            .lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) || (0x3400...0x9FFF).contains($0.value) || (0x3040...0x30FF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }
            .map(String.init)
            .joined()
    }

    private static func longestCommonSubsequenceLength(
        _ lhs: [Unicode.Scalar],
        _ rhs: [Unicode.Scalar]
    ) -> Int {
        var previous = Array(repeating: 0, count: rhs.count + 1)
        for left in lhs {
            var current = Array(repeating: 0, count: rhs.count + 1)
            for (index, right) in rhs.enumerated() {
                if left == right {
                    current[index + 1] = previous[index] + 1
                } else {
                    current[index + 1] = max(previous[index + 1], current[index])
                }
            }
            previous = current
        }
        return previous[rhs.count]
    }
}
