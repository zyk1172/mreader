import CoreGraphics
import Foundation

/// 单个 Vision 切片在整页归一化坐标系（0...1）下的识别结果。
///
/// `blocks` 必须已经通过 `mapVisionRect(_:from:)` 映射回整页坐标，
/// 否则跨切片拼接无法判断几何连续性。
nonisolated struct VisionSliceObservation: Sendable {
    /// 切片在整页切片数组中的下标，决定“相邻”关系与阅读顺序。
    let index: Int
    /// 切片在整页归一化坐标中的覆盖区域。
    let sourceRect: CGRect
    let blocks: [TextBlock]

    nonisolated init(index: Int, sourceRect: CGRect, blocks: [TextBlock]) {
        self.index = index
        self.sourceRect = sourceRect
        self.blocks = blocks
    }
}

/// 跨切片拼接结果。
nonisolated struct VisionSliceMergeOutcome: Sendable {
    /// 合并后的全部 block（含未参与合并的原 block），已按阅读顺序排序。
    let blocks: [TextBlock]
    /// 因“真正的拼接”而生成的新 block id。这些 block 的 `translation` 恒为 nil，
    /// 调用方必须对完整原文重新翻译，绝不能沿用任何一半的旧译文。
    let retranslationRequiredBlockIDs: [UUID]

    nonisolated init(blocks: [TextBlock], retranslationRequiredBlockIDs: [UUID]) {
        self.blocks = blocks
        self.retranslationRequiredBlockIDs = retranslationRequiredBlockIDs
    }
}

/// 跨切片文本合并器。
///
/// 职责边界（与 `OCRCandidateResolver` 互补，互不替代）：
/// - `OCRCandidateResolver`：多份重复候选里挑最可信的一份，**只做去重**。
/// - `VisionSliceMerger`：把被切片边界切开的同一句话**按阅读顺序拼回完整原文**，
///   然后交给 `OCRCandidateResolver` 去重。
///
/// 处理顺序：Vision 分片识别 → 映射回整页坐标 → `VisionSliceMerger` → `OCRCandidateResolver` → 翻译。
nonisolated enum VisionSliceMerger {

    // MARK: - 允许合并的判据（全部必须同时成立）

    /// 相邻切片必须有真实重叠带，否则不存在“同一气泡被切开”的前提。
    static let minimumOverlapHeight: CGFloat = 0.002
    /// 上/下半句之间允许的最大垂直间隙（整页归一化高度）。
    static let maximumVerticalGap: CGFloat = 0.012
    /// 两半中轴的水平偏移上限，相对较宽一侧的宽度。
    static let maximumCenterOffsetRatio: CGFloat = 0.60
    /// 短边尺寸（横排取高度、竖排取宽度）比例上限。
    static let maximumShortSideRatio: CGFloat = 2.6
    /// 字号尺度比例上限，防止把“大标题 + 小对白”拼成一句。
    static let maximumFontScaleRatio: CGFloat = 2.2

    static func merge(
        observations: [VisionSliceObservation],
        isRightToLeft: Bool
    ) -> VisionSliceMergeOutcome {
        let ordered = observations.sorted { $0.index < $1.index }
        guard ordered.count > 1 else {
            return VisionSliceMergeOutcome(
                blocks: AITranslator.sortedTextBlocks(ordered.flatMap(\.blocks), isRightToLeft: isRightToLeft),
                retranslationRequiredBlockIDs: []
            )
        }

        var entries: [SliceEntry] = []
        for observation in ordered {
            for block in observation.blocks {
                entries.append(SliceEntry(sliceIndex: observation.index, block: block))
            }
        }

        var candidates: [MergeCandidate] = []
        for position in 0..<(ordered.count - 1) {
            // sliceA 是页码更靠上的切片，sliceB 是它下方的相邻切片。
            let sliceA = ordered[position]
            let sliceB = ordered[position + 1]
            // 只有相邻切片允许合并。
            guard sliceA.index + 1 == sliceB.index else { continue }
            let overlap = sliceA.sourceRect.intersection(sliceB.sourceRect)
            guard !overlap.isNull, overlap.width > 0, overlap.height >= minimumOverlapHeight else {
                continue
            }
            let indicesA = entries.indices.filter { entries[$0].sliceIndex == sliceA.index }
            let indicesB = entries.indices.filter { entries[$0].sliceIndex == sliceB.index }
            for indexA in indicesA {
                for indexB in indicesB {
                    guard let relation = mergeRelation(
                        upperBlock: entries[indexA].block,
                        lowerBlock: entries[indexB].block,
                        overlap: overlap
                    ) else { continue }
                    candidates.append(MergeCandidate(
                        firstIndex: indexA,
                        secondIndex: indexB,
                        score: relation.score,
                        join: relation.join
                    ))
                }
            }
        }

        // 贪心：最可信的一对先合并，已参与合并的 observation 不再被重复消费。
        candidates.sort { $0.score > $1.score }
        var retranslationRequired: [UUID] = []
        for candidate in candidates {
            guard !entries[candidate.firstIndex].isRemoved,
                  !entries[candidate.secondIndex].isRemoved else { continue }
            let upperBlock = entries[candidate.firstIndex].block
            let lowerBlock = entries[candidate.secondIndex].block
            let merged = mergedBlock(
                upper: upperBlock,
                lower: lowerBlock,
                join: candidate.join
            )
            entries[candidate.firstIndex].block = merged
            entries[candidate.secondIndex].isRemoved = true
            if candidate.join.requiresRetranslation {
                retranslationRequired.append(merged.id)
            }
        }

        let resolved = entries.filter { !$0.isRemoved }.map(\.block)
        return VisionSliceMergeOutcome(
            blocks: AITranslator.sortedTextBlocks(resolved, isRightToLeft: isRightToLeft),
            retranslationRequiredBlockIDs: retranslationRequired
        )
    }

    // MARK: - 内部类型

    private struct SliceEntry {
        let sliceIndex: Int
        var block: TextBlock
        var isRemoved = false
    }

    /// 两个来自相邻切片的 block 之间的拼接方式。
    enum TextJoin: Sendable {
        /// 两个切片读到了同一条（部分）文本，取信息更全的一侧，不重复拼接。
        case duplicate(keepUpper: Bool)
        /// 真正的半句拼接：需要把两侧原文按阅读顺序连成完整一句。
        case split(String)

        var requiresRetranslation: Bool {
            if case .split = self { return true }
            return false
        }
    }

    private struct MergeRelation {
        let join: TextJoin
        let score: Double
    }

    private struct MergeCandidate {
        let firstIndex: Int
        let secondIndex: Int
        let score: Double
        let join: TextJoin
    }

    // MARK: - 判据实现

    private static func mergeRelation(
        upperBlock: TextBlock,
        lowerBlock: TextBlock,
        overlap: CGRect
    ) -> MergeRelation? {
        // 判据 1：阅读方向一致。切片沿水平缝切开，因此无论 LTR / RTL，
        // 上半句永远先于下半句；方向不一致的 block 直接拒绝。
        guard upperBlock.textOrientation == lowerBlock.textOrientation else { return nil }

        let upperText = normalized(upperBlock.text)
        let lowerText = normalized(lowerBlock.text)
        guard !upperText.isEmpty, !lowerText.isEmpty else { return nil }

        let upperBox = upperBlock.boundingBox
        let lowerBox = lowerBlock.boundingBox
        guard upperBox.width > 0, upperBox.height > 0,
              lowerBox.width > 0, lowerBox.height > 0 else { return nil }

        // 判据 2：两块都必须落在 overlap 带附近，即“在切片边界处被切断”。
        let tolerance = max(overlap.height * 0.5, 0.010)
        guard upperBox.maxY >= overlap.minY - tolerance,
              lowerBox.minY <= overlap.maxY + tolerance else { return nil }

        // 判据 3：几何连续。中轴与短边必须相关。
        let widest = max(upperBox.width, lowerBox.width)
        guard abs(upperBox.midX - lowerBox.midX) <= widest * maximumCenterOffsetRatio else {
            return nil
        }
        let shortSideRatio: CGFloat
        if upperBlock.textOrientation == .horizontal {
            shortSideRatio = ratio(upperBox.height, lowerBox.height)
        } else {
            shortSideRatio = ratio(upperBox.width, lowerBox.width)
        }
        guard shortSideRatio <= maximumShortSideRatio else { return nil }
        let fontScaleRatio = ratio(
            CGFloat(upperBlock.estimatedFontScale),
            CGFloat(lowerBlock.estimatedFontScale)
        )
        guard fontScaleRatio <= maximumFontScaleRatio else { return nil }

        // 判据 4：bubbleBox 高度相关。两侧都给气泡时，气泡必须垂直相邻。
        if let upperBubble = upperBlock.bubbleBox, let lowerBubble = lowerBlock.bubbleBox {
            let bubbleGap = lowerBubble.minY - upperBubble.maxY
            let allowance = max(maximumVerticalGap, max(upperBubble.height, lowerBubble.height) * 0.5)
            guard bubbleGap <= allowance,
                  bubbleGap >= -max(upperBubble.height, lowerBubble.height) else { return nil }
        }

        // 判据 5：文字存在前后缀关系 → 重叠重复，取更全的一侧；
        // 否则视为真正的半句拼接，必须垂直紧邻。
        let gap = lowerBox.minY - upperBox.maxY
        let join: TextJoin
        var score = 0.6
        if upperText == lowerText
            || lowerText.hasPrefix(upperText)
            || upperText.hasPrefix(lowerText) {
            join = .duplicate(keepUpper: upperText.count >= lowerText.count)
            score += 0.25
        } else {
            guard gap <= maximumVerticalGap,
                  gap >= -max(overlap.height, 0.010) else { return nil }
            join = .split(upperBlock.text + lowerBlock.text)
            // 越接近无缝，越可能是同一句话。
            score += 0.4 * (1 - Double(min(max(gap, 0) / maximumVerticalGap, 1)))
            // 两侧都有实际内容（不是单字噪声）。
            score += min(Double(min(upperText.count, lowerText.count)) * 0.01, 0.1)
        }
        return MergeRelation(join: join, score: score)
    }

    private static func mergedBlock(
        upper: TextBlock,
        lower: TextBlock,
        join: TextJoin
    ) -> TextBlock {
        let text: String
        let translation: String?
        let translationLines: [String]
        let primary: TextBlock
        let requiresRetranslation = join.requiresRetranslation
        switch join {
        case .duplicate(let keepUpper):
            // 重叠重复：保留信息更全的一侧（含它的译文），不制造重复原文。
            let source = keepUpper ? upper : lower
            text = source.text
            translation = source.translation
            translationLines = source.translationLines
            primary = source
        case .split(let joinedText):
            // 真正的拼接：只拼原文，不拼两段旧译文。
            text = joinedText
            translation = nil
            translationLines = []
            primary = upper
        }

        return TextBlock(
            id: upper.id,
            text: text,
            boundingBox: upper.boundingBox.union(lower.boundingBox),
            translation: translation,
            confidence: max(upper.confidence, lower.confidence),
            ocrSource: "vision-model:slice-merge:\(primary.layoutRole.rawValue)",
            isFiltered: upper.isFiltered && lower.isFiltered,
            filterReason: upper.isFiltered && lower.isFiltered ? upper.filterReason : nil,
            estimatedFontScale: requiresRetranslation
                ? (upper.estimatedFontScale + lower.estimatedFontScale) / 2
                : primary.estimatedFontScale,
            textColorHex: primary.textColorHex,
            bubbleBox: unionRect(upper.bubbleBox, lower.bubbleBox),
            layoutSafeRegion: unionRect(upper.layoutSafeRegion, lower.layoutSafeRegion),
            // 拼接后的多边形不再完整；保留 union 矩形作为唯一定位依据。
            polygon: [],
            bubblePolygon: [],
            translationLines: translationLines,
            textOrientation: primary.textOrientation,
            layoutRole: primary.layoutRole,
            sourceLineCount: requiresRetranslation
                ? max(upper.sourceLineCount, lower.sourceLineCount)
                : primary.sourceLineCount
        )
    }

    private static func unionRect(_ lhs: CGRect?, _ rhs: CGRect?) -> CGRect? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): return lhs.union(rhs)
        case let (lhs?, nil): return lhs
        case let (nil, rhs?): return rhs
        default: return nil
        }
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[\\p{P}\\p{S}]", with: "", options: .regularExpression)
    }

    private static func ratio(_ lhs: CGFloat, _ rhs: CGFloat) -> CGFloat {
        let small = min(lhs, rhs)
        let large = max(lhs, rhs)
        guard small > 0 else { return .greatestFiniteMagnitude }
        return large / small
    }
}
