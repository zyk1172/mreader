import CoreGraphics
import Foundation

/// 单个 Vision 切片在整页归一化坐标系（0...1）下的识别结果。
///
/// `blocks` 必须已经通过 `mapVisionRect(_:from:)` 映射回整页坐标，
/// 否则跨切片拼接无法判断几何连续性。
nonisolated struct VisionSliceObservation: Sendable {
    /// 切片在整页切片数组中的下标，决定“相邻”关系与阅读顺序。
    let index: Int
    /// 切片在整页归一化坐标中的覆盖区域。裁剪边界由它推导。
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
    /// 因“真正的拼接”而生成的新 block id。调用方必须对完整原文**定向重译**，
    /// 不能只依赖“译文为空”来触发兜底（拼接后的 block 可能带有临时译文）。
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
///
/// 拼接采用 **longest suffix-prefix overlap**：只补上未重叠的部分，
/// `今日はいい` + `いい天気` → `今日はいい天気`（不会退化成 `今日はいいいい天気`）。
nonisolated enum VisionSliceMerger {

    // MARK: - 允许合并的判据（全部必须同时成立）

    /// 相邻切片必须有真实重叠带，否则不存在“同一气泡被切开”的前提。
    static let minimumOverlapHeight: CGFloat = 0.002
    /// 文字 / 气泡必须确实在切片边界被切开：其边框应触及对应切片的裁剪边缘。
    /// 允许的偏差（整页归一化高度）。完整落在切片内部的气泡达不到这个条件。
    static let maximumCutGap: CGFloat = 0.012
    /// 相邻两半的气泡之间允许的最大垂直间隙。
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
                        // 裁剪边界：上切片的底边、下切片的顶边。被切开的一半必然触及它们。
                        upperCut: sliceA.sourceRect.maxY,
                        lowerCut: sliceB.sourceRect.minY
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

        // 贪心：最可信的一对先合并，已参与合并的 block 不再被重复消费。
        candidates.sort { $0.score > $1.score }
        var retranslationRequired: [UUID] = []
        for candidate in candidates {
            guard !entries[candidate.firstIndex].isRemoved,
                  !entries[candidate.secondIndex].isRemoved else { continue }
            let upperBlock = entries[candidate.firstIndex].block
            let lowerBlock = entries[candidate.secondIndex].block
            let merged = mergedBlock(upper: upperBlock, lower: lowerBlock, join: candidate.join)
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
        /// 真正的半句拼接：原文需要拼接，译文必须重新生成。
        /// `provisionalTranslation` 只在定向重译失败时兜底，不代表已完成翻译。
        case split(text: String, provisionalTranslation: String?)

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
        upperCut: CGFloat,
        lowerCut: CGFloat
    ) -> MergeRelation? {
        // 判据 1：阅读方向一致。切片沿水平缝切开，因此无论 LTR / RTL，
        // 上半句永远先于下半句；方向不一致的 block 直接拒绝。
        guard upperBlock.textOrientation == lowerBlock.textOrientation else { return nil }
        // 判据 2：布局语义一致。对白不能和拟声词 / 旁白拼成一句。
        guard upperBlock.layoutRole == lowerBlock.layoutRole else { return nil }

        let upperText = upperBlock.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerText = lowerBlock.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !upperText.isEmpty, !lowerText.isEmpty else { return nil }

        let upperBox = upperBlock.boundingBox
        let lowerBox = lowerBlock.boundingBox
        guard upperBox.width > 0, upperBox.height > 0,
              lowerBox.width > 0, lowerBox.height > 0 else { return nil }

        // 判据 3：两块都必须“确实在切片边界被切开”——上句触及上切片裁剪底边，
        // 下句触及下切片裁剪顶边。完整落在切片内部的气泡满足不了这一条。
        guard isCutAtBottom(upperBox, cut: upperCut),
              isCutAtTop(lowerBox, cut: lowerCut) else { return nil }

        // 判据 4：几何连续。中轴、短边与字号必须相关。
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

        // 判据 5：气泡证据。两侧都给出气泡时，气泡本身也必须被切开且相接，
        // 这样“两个不同气泡恰好靠近切片边界”不会被拼成一句。
        if let upperBubble = upperBlock.bubbleBox, let lowerBubble = lowerBlock.bubbleBox {
            guard isCutAtBottom(upperBubble, cut: upperCut),
                  isCutAtTop(lowerBubble, cut: lowerCut) else { return nil }
            let bubbleGap = lowerBubble.minY - upperBubble.maxY
            let allowance = max(maximumVerticalGap, max(upperBubble.height, lowerBubble.height) * 0.5)
            guard bubbleGap <= allowance else { return nil }
        }

        // 判据 6：文字关系。
        let upperKeys = compactKeySequence(upperText)
        let lowerKeys = compactKeySequence(lowerText)
        guard !upperKeys.isEmpty, !lowerKeys.isEmpty else { return nil }

        var score = 0.55
        let join: TextJoin
        if upperKeys == lowerKeys
            || isPrefix(lowerKeys, of: upperKeys)
            || isPrefix(upperKeys, of: lowerKeys) {
            // 同一句话被两个切片都读到了（或一侧读全、一侧读半）：取信息更全的一侧。
            join = .duplicate(keepUpper: upperKeys.count >= lowerKeys.count)
            score += 0.30
        } else {
            let overlapped = overlappedPrefixLength(upper: upperText, lower: lowerText)
            let primary = upperKeys.count >= lowerKeys.count ? upperBlock : lowerBlock
            join = .split(
                text: joinedSourceText(upper: upperText, lower: lowerText),
                provisionalTranslation: primary.translation
            )
            // 有字符重叠是最强的“同一句话”证据；没有重叠时只能靠几何证据支撑。
            score += overlapped > 0 ? 0.35 : 0.10
            score += min(Double(min(upperKeys.count, lowerKeys.count)) * 0.01, 0.10)
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
        case .split(let joinedText, let provisionalTranslation):
            // 真正的拼接：只拼原文；译文先留最全的一半作兜底，
            // 由调用方对完整原文定向重译后覆盖。
            text = joinedText
            translation = provisionalTranslation
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

    // MARK: - 文本拼接（可单独测试）

    /// 把两半原文拼成完整一句：只补上未重叠的部分。
    ///
    /// - `今日はいい` + `いい天気` → `今日はいい天気`
    /// - `Hello wor` + `world` → `Hello world`
    /// - 拉丁文两侧完全没有重叠时补一个空格，避免 `Hello` + `world` 粘成 `Helloworld`。
    static func joinedSourceText(upper: String, lower: String) -> String {
        let overlapped = overlappedPrefixLength(upper: upper, lower: lower)
        if overlapped > 0 {
            return upper + String(lower.dropFirst(overlapped))
        }
        return needsLatinSeparator(upper: upper, lower: lower)
            ? upper + " " + lower
            : upper + lower
    }

    /// `lower` 开头有多少个字符已被 `upper` 结尾覆盖（按 `lower` 的原始 Character 计数）。
    /// 比较在“去空白、去标点、小写”的紧凑序列上进行，但返回值可安全用于 `dropFirst`。
    static func overlappedPrefixLength(upper: String, lower: String) -> Int {
        let upperKeys = compactKeySequence(upper)
        let lowerKeys = compactKeySequence(lower)
        let maximum = min(upperKeys.count, lowerKeys.count)
        guard maximum > 0 else { return 0 }

        var bestLength = 0
        for length in 1...maximum
        where Array(upperKeys.suffix(length)) == Array(lowerKeys.prefix(length)) {
            bestLength = length
        }
        guard bestLength > 0 else { return 0 }

        var consumedKeys = 0
        var rawCount = 0
        for character in lower {
            rawCount += 1
            guard compactKey(character) != nil else { continue }
            consumedKeys += 1
            if consumedKeys == bestLength { break }
        }
        return rawCount
    }

    private static func isCutAtBottom(_ box: CGRect, cut: CGFloat) -> Bool {
        box.maxY >= cut - maximumCutGap
    }

    private static func isCutAtTop(_ box: CGRect, cut: CGFloat) -> Bool {
        box.minY <= cut + maximumCutGap
    }

    private static func isPrefix(_ candidate: [String], of other: [String]) -> Bool {
        guard candidate.count <= other.count else { return false }
        return Array(other.prefix(candidate.count)) == candidate
    }

    private static func needsLatinSeparator(upper: String, lower: String) -> Bool {
        guard let last = upper.last, let first = lower.first else { return false }
        guard !last.isWhitespace, !first.isWhitespace else { return false }
        return isLatinWordCharacter(last) && isLatinWordCharacter(first)
    }

    private static func isLatinWordCharacter(_ character: Character) -> Bool {
        if character.isNumber { return true }
        guard character.isLetter else { return false }
        return character.unicodeScalars.allSatisfy { $0.value < 0x0250 }
    }

    private static func compactKeySequence(_ text: String) -> [String] {
        text.compactMap(compactKey)
    }

    /// 只保留有意义的字符：丢弃空白与标点，并统一小写。
    /// `nil` 表示该字符不参与前后缀比较。
    private static func compactKey(_ character: Character) -> String? {
        let value = String(character).lowercased()
        guard !value.isEmpty else { return nil }
        let scalars = value.unicodeScalars
        if scalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) { return nil }
        if scalars.allSatisfy({
            CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0)
        }) {
            return nil
        }
        return value
    }

    private static func unionRect(_ lhs: CGRect?, _ rhs: CGRect?) -> CGRect? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): return lhs.union(rhs)
        case let (lhs?, nil): return lhs
        case let (nil, rhs?): return rhs
        default: return nil
        }
    }

    private static func ratio(_ lhs: CGFloat, _ rhs: CGFloat) -> CGFloat {
        let small = min(lhs, rhs)
        let large = max(lhs, rhs)
        guard small > 0 else { return .greatestFiniteMagnitude }
        return large / small
    }
}
