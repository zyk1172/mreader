import CoreGraphics
import Foundation

nonisolated struct MangaTextSegmentation: Sendable {
    let lines: [TextBlock]
    let bubbles: [TextBlock]
}

nonisolated enum MangaTextSegmenter {
    private enum BubbleRelation {
        case same
        case different
        case unknown
    }

    private enum BubbleRegionMembership {
        case inside
        case outside
        case unavailable
    }

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
        let lines = lineGroups.map { group in
            // complete-link 分组在这里已经把 observation 合成一条源 line；
            // 不要把其中的候选数量误记成 line 数。
            mergedBlock(
                from: group,
                isRightToLeft: isRightToLeft,
                sourceLineCount: 1
            )
        }
        let bubbleGroups = dialogueClusterGroups(
            AITranslator.sortedTextBlocks(lines, isRightToLeft: isRightToLeft),
            isRightToLeft: isRightToLeft
        )
        let bubbles = bubbleGroups.map { group in
            let sourceLineCount = group.reduce(0) { total, block in
                total + max(block.sourceLineCount, 1)
            }
            return mergedBlock(
                from: group,
                isRightToLeft: isRightToLeft,
                sourceLineCount: sourceLineCount
            )
        }
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

    /// 将 line block 组合成最终 translation unit。这里明确分成三层：
    ///
    /// 1. 严格的 visual bubble identity 可以跨越行距直接合并；
    /// 2. visual bubble 明确冲突时直接拆开；
    /// 3. 其余情况按 same / different / unknown 三态关系处理：unknown 仍然
    ///    使用相邻对白行构建 cluster，而不是回退到旧的 complete-link bubble
    ///    启发式；可靠 bubbleBox 则作为组级区域吸收其中的本地 OCR 行。
    ///
    /// 第 3 层仍保留连续行的字号、颜色、方向、投影和整体尺寸护栏；相邻行距
    /// 出现突变时会断开，避免两个说话人的对白通过单条中间行链式吞并。
    private static func dialogueClusterGroups(
        _ blocks: [TextBlock],
        isRightToLeft: Bool
    ) -> [[TextBlock]] {
        var groups: [[TextBlock]] = []
        for block in blocks {
            // 严格身份优先于排序距离和所有 OCR 弱信号。若同一视觉气泡跨过了
            // 其它 group 的阅读位置，仍回到它自己的 identity group。
            if let identityIndex = groups.firstIndex(where: { group in
                groupSharesStrictVisualIdentity(group, with: block)
            }) {
                let expandedUnion = union(of: groups[identityIndex], adding: block)
                if expandedUnion.width <= 0.65, expandedUnion.height <= 0.48 {
                    groups[identityIndex].append(block)
                } else {
                    // 和 canShareBubble 的页面范围护栏保持一致：身份再强也不能
                    // 让一个异常 span 变成遮挡大半页面的 translation unit。
                    groups.append([block])
                }
                continue
            }

            if let lastIndex = groups.indices.last,
               canAppendToDialogueCluster(
                   block,
                   group: groups[lastIndex],
                   isRightToLeft: isRightToLeft
               ) {
                groups[lastIndex].append(block)
            } else {
                groups.append([block])
            }
        }
        return groups
    }

    private static func groupSharesStrictVisualIdentity(
        _ group: [TextBlock],
        with block: TextBlock
    ) -> Bool {
        guard !group.isEmpty,
              block.bubbleBox != nil,
              group.allSatisfy({ $0.bubbleBox != nil }) else {
            return false
        }
        return group.allSatisfy { member in
            isVertical(member) == isVertical(block)
                && visualBubbleBoxesAreCompatible(member.bubbleBox, block.bubbleBox)
                && sameVisualBubbleIdentity(member, block)
        }
    }

    private static func canAppendToDialogueCluster(
        _ block: TextBlock,
        group: [TextBlock],
        isRightToLeft: Bool
    ) -> Bool {
        guard let previous = group.last,
              !group.isEmpty else {
            return false
        }

        let expandedUnion = union(of: group, adding: block)
        guard expandedUnion.width <= 0.65, expandedUnion.height <= 0.48 else {
            return false
        }

        switch bubbleRelation(of: block, relativeTo: group) {
        case .different:
            // 两个可靠框明确冲突：不能被行距或其它 OCR 弱信号重新合并。
            return false
        case .same:
            // 已确认是同一视觉气泡时，允许跨越不规则行距、字号和颜色采样
            // 波动；仍保留方向和阅读顺序硬护栏。
            return canJoinBubbleRegion(
                block,
                group: group,
                isRightToLeft: isRightToLeft
            )
        case .unknown:
            switch bubbleRegionMembership(of: block, in: group) {
            case .inside:
                // 一个可靠气泡框已经提供了 group-level 几何证据。位于该区域
                // 内的 nil bubbleBox 行不应再受旧的逐行行距阈值影响。
                return canJoinBubbleRegion(
                    block,
                    group: group,
                    isRightToLeft: isRightToLeft
                )
            case .outside:
                // 对已知气泡区域而言，明确位于区域外的无框行不能被 adjacent
                // clustering 吞回去；nil 只表示未知，不表示可以跨越已知边界。
                return false
            case .unavailable:
                // 两边都没有可用区域，或只有候选行携带 bubbleBox 时，仍按
                // dialogue adjacency 处理，不把 unknown 误判成 different。
                return canShareDialogueClusterLine(
                    previous,
                    block,
                    group: group,
                    isRightToLeft: isRightToLeft
                )
            }
        }
    }

    /// 返回 block 相对于当前 group 的三态 bubble 关系。
    ///
    /// `nil` 是 unknown：它只代表这一行没有独立的视觉气泡证据，不能被当成
    /// “不同气泡”。只有两个可靠 bubbleBox 明确不兼容时才返回 different；
    /// 只有已知框满足严格 identity 时才返回 same。
    private static func bubbleRelation(
        of block: TextBlock,
        relativeTo group: [TextBlock]
    ) -> BubbleRelation {
        guard let blockBubble = block.bubbleBox else { return .unknown }
        let groupBubbles = group.compactMap(\.bubbleBox)
        guard !groupBubbles.isEmpty else { return .unknown }

        guard groupBubbles.allSatisfy({
            visualBubbleBoxesAreCompatible($0, blockBubble)
        }) else {
            return .different
        }

        let everyKnownMemberHasSameIdentity = group.allSatisfy { member in
            guard member.bubbleBox != nil else { return true }
            return sameVisualBubbleIdentity(member, block)
        }
        return everyKnownMemberHasSameIdentity ? .same : .unknown
    }

    /// 判断 block 是否落在当前 group 的可靠 bubble 区域内。
    ///
    /// 已有 group bubble 时，只允许没有 bubbleBox 的本地 OCR 行通过区域吸收；
    /// 一个新的显式 bubbleBox 即使看起来嵌套在旧框里，也必须继续走 unknown 的
    /// 对白相邻规则，避免把“外围框 + 内部真实框”错误提升为同一气泡。
    private static func bubbleRegionMembership(
        of block: TextBlock,
        in group: [TextBlock]
    ) -> BubbleRegionMembership {
        let groupBubbles = group.compactMap(\.bubbleBox)
        if !groupBubbles.isEmpty {
            guard block.bubbleBox == nil else { return .unavailable }
            return groupBubbles.contains(where: {
                bubbleContainsText($0, block.boundingBox)
            }) ? .inside : .outside
        }

        guard let blockBubble = block.bubbleBox,
              !group.isEmpty,
              group.allSatisfy({ bubbleContainsText(blockBubble, $0.boundingBox) }) else {
            return .unavailable
        }
        return .inside
    }

    /// same/区域内的加入只保留文本方向和阅读顺序硬护栏，不再使用字号、颜色或
    /// 行距推断。视觉气泡是区域级对象，这些弱信号不能否决区域内的本地 OCR 行。
    private static func canJoinBubbleRegion(
        _ block: TextBlock,
        group: [TextBlock],
        isRightToLeft: Bool
    ) -> Bool {
        guard let previous = group.last,
              group.allSatisfy({ isVertical($0) == isVertical(block) }) else {
            return false
        }
        return followsReadingOrder(
            previous,
            block,
            isRightToLeft: isRightToLeft
        )
    }

    private static func canShareDialogueClusterLine(
        _ lhs: TextBlock,
        _ rhs: TextBlock,
        group: [TextBlock],
        isRightToLeft: Bool
    ) -> Bool {
        guard lhs.layoutRole == .dialogue,
              rhs.layoutRole == .dialogue,
              isVertical(lhs) == isVertical(rhs) else {
            return false
        }

        let smallerScale = min(fontScale(lhs), fontScale(rhs))
        let largerScale = max(fontScale(lhs), fontScale(rhs))
        // Apple/native OCR 没有 bubbleBox 时只放宽“组内端点距离”，不放宽
        // 原有的字号/颜色护栏；否则同几何但字号明显不同的两个说话人会被
        // 新的 cluster 误合并。短句与长句的宽度不参与这个判断。
        guard largerScale / max(smallerScale, 0.000_1) <= 1.25,
              OCRCandidateResolver.colorsAreCompatible(
                  lhs.textColorHex,
                  rhs.textColorHex,
                  maximumDistance: 72
              ) else {
            return false
        }

        guard followsReadingOrder(lhs, rhs, isRightToLeft: isRightToLeft) else {
            return false
        }

        let lineGap = dialogueAxisGap(lhs, rhs)
        let lineAxisSize = isVertical(lhs)
            ? min(lhs.boundingBox.width, rhs.boundingBox.width)
            : min(lhs.boundingBox.height, rhs.boundingBox.height)
        let maximumGap: CGFloat
        if group.count == 1 {
            // The first pair has no local cluster baseline yet. Keep its window
            // close to one line height so two nearby single-line bubbles cannot
            // seed a contaminated group. The screenshot regression gap (0.030
            // for a 0.045 line) remains comfortably inside this limit.
            maximumGap = max(smallerScale * 1.35, lineAxisSize * 1.25, 0.006)
        } else {
            maximumGap = min(
                max(smallerScale * 2.2, lineAxisSize * 1.8, 0.020),
                0.10
            )
        }
        guard lineGap <= maximumGap else { return false }

        let crossOverlap: CGFloat
        let crossCenterDistance: CGFloat
        let crossSize: CGFloat
        if isVertical(lhs) {
            crossOverlap = overlapLength(
                lhs.boundingBox.minY,
                lhs.boundingBox.maxY,
                rhs.boundingBox.minY,
                rhs.boundingBox.maxY
            )
            crossCenterDistance = abs(lhs.boundingBox.midY - rhs.boundingBox.midY)
            crossSize = min(lhs.boundingBox.height, rhs.boundingBox.height)
        } else {
            crossOverlap = overlapLength(
                lhs.boundingBox.minX,
                lhs.boundingBox.maxX,
                rhs.boundingBox.minX,
                rhs.boundingBox.maxX
            )
            crossCenterDistance = abs(lhs.boundingBox.midX - rhs.boundingBox.midX)
            crossSize = min(lhs.boundingBox.width, rhs.boundingBox.width)
        }
        let crossOverlapRatio = crossOverlap / max(crossSize, 0.000_1)
        let crossCenterTolerance = max(crossSize * 0.75, smallerScale * 2.5)
        guard crossOverlapRatio >= 0.12 || crossCenterDistance <= crossCenterTolerance else {
            return false
        }

        // Use the already accepted adjacent gaps as a local baseline. This keeps a
        // normal 2–4 line dialogue cluster connected even when its first/last lines
        // are far apart, while an abrupt larger gap starts a new speaker cluster.
        guard group.count >= 2 else { return true }
        let adjacentGaps = zip(group, group.dropFirst()).map {
            dialogueAxisGap($0.0, $0.1)
        }
        guard !adjacentGaps.isEmpty else { return true }
        let sortedGaps = adjacentGaps.sorted()
        let baselineGap = sortedGaps[sortedGaps.count / 2]
        let gapTolerance = max(baselineGap * 0.45, smallerScale * 0.10, 0.004)
        return lineGap <= baselineGap + gapTolerance
    }

    private static func union(of group: [TextBlock], adding block: TextBlock) -> CGRect {
        guard let first = group.first else { return block.boundingBox }
        return group.dropFirst().reduce(first.boundingBox) { $0.union($1.boundingBox) }
            .union(block.boundingBox)
    }

    private static func dialogueAxisGap(_ lhs: TextBlock, _ rhs: TextBlock) -> CGFloat {
        if isVertical(lhs) {
            return gap(
                lhs.boundingBox.minX,
                lhs.boundingBox.maxX,
                rhs.boundingBox.minX,
                rhs.boundingBox.maxX
            )
        }
        return gap(
            lhs.boundingBox.minY,
            lhs.boundingBox.maxY,
            rhs.boundingBox.minY,
            rhs.boundingBox.maxY
        )
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
        sourceLineCount: Int
    ) -> TextBlock {
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
            layoutRole: ordered[0].layoutRole,
            sourceLineCount: sourceLineCount
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

    /// 严格证明两个视觉框来自同一个气泡。这里故意不把“一个框包含另一个框”
    /// 当作充分条件：外围误检框和内部真实气泡也会满足单向包含。
    ///
    /// 同一视觉检测结果通常会给出相同或只有轻微抖动的矩形，因此 identity 需要
    /// 同时满足高 IoU、中心距离、宽高比和面积比。轻微平移时允许高 IoU 的抖动框；
    /// 但显著的单向包含必须失败，只有小容差内的 mutual containment 才能直接确认。
    private static func sameVisualBubbleIdentity(_ lhs: TextBlock, _ rhs: TextBlock) -> Bool {
        guard let lhsBox = lhs.bubbleBox?.standardized,
              let rhsBox = rhs.bubbleBox?.standardized,
              lhsBox.width > 0,
              lhsBox.height > 0,
              rhsBox.width > 0,
              rhsBox.height > 0 else {
            return false
        }

        let lhsArea = lhsBox.width * lhsBox.height
        let rhsArea = rhsBox.width * rhsBox.height
        let smallerArea = max(min(lhsArea, rhsArea), 0.000_001)
        let areaRatio = max(lhsArea, rhsArea) / smallerArea
        let widthRatio = max(lhsBox.width, rhsBox.width)
            / max(min(lhsBox.width, rhsBox.width), 0.000_001)
        let heightRatio = max(lhsBox.height, rhsBox.height)
            / max(min(lhsBox.height, rhsBox.height), 0.000_001)
        guard areaRatio <= 1.40,
              widthRatio <= 1.30,
              heightRatio <= 1.30 else {
            return false
        }

        let intersection = lhsBox.intersection(rhsBox)
        guard !intersection.isNull else { return false }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = lhsArea + rhsArea - intersectionArea
        let iou = unionArea > 0 ? intersectionArea / unionArea : 0
        guard iou >= 0.72 else { return false }

        let centerDistance = hypot(
            lhsBox.midX - rhsBox.midX,
            lhsBox.midY - rhsBox.midY
        )
        let minimumDimension = min(
            min(lhsBox.width, rhsBox.width),
            min(lhsBox.height, rhsBox.height)
        )
        guard centerDistance <= max(minimumDimension * 0.45, 0.012) else {
            return false
        }

        let tolerance: CGFloat = 0.006
        let lhsContainsRhs = lhsBox.insetBy(dx: -tolerance, dy: -tolerance).contains(rhsBox)
        let rhsContainsLhs = rhsBox.insetBy(dx: -tolerance, dy: -tolerance).contains(lhsBox)

        // 单向包含是外围框/内部框的典型形状；即使 IoU 偶然很高，也不能把它
        // 直接视为同一身份。没有包含关系的轻微平移框则必须再满足更严格的指标。
        if lhsContainsRhs != rhsContainsLhs {
            return false
        }
        if lhsContainsRhs && rhsContainsLhs {
            return true
        }

        let jitterCenterTolerance = max(minimumDimension * 0.30, 0.008)
        return iou >= 0.82
            && areaRatio <= 1.20
            && widthRatio <= 1.18
            && heightRatio <= 1.18
            && centerDistance <= jitterCenterTolerance
    }

    /// 两个视觉框没有可观重叠、也不在小容差下相互包含，说明它们已经是不同漫画气泡。
    /// 该判断只承担宽松的 compatibility / veto 语义；它不能反过来证明两个框
    /// 是同一个气泡，后者必须由 `sameVisualBubbleIdentity` 严格确认。
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

    private static func followsReadingOrder(
        _ lhs: TextBlock,
        _ rhs: TextBlock,
        isRightToLeft: Bool
    ) -> Bool {
        let tolerance = max(min(fontScale(lhs), fontScale(rhs)) * 0.25, 0.004)
        if isVertical(lhs) {
            return isRightToLeft
                ? rhs.boundingBox.midX <= lhs.boundingBox.midX + tolerance
                : rhs.boundingBox.midX >= lhs.boundingBox.midX - tolerance
        }
        return rhs.boundingBox.midY >= lhs.boundingBox.midY - tolerance
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
        // bubbleBox 已经过视觉复核，但坐标映射和 OCR textBox 仍可能有少量边缘
        // 抖动；只给有限的归一化容差，不把邻近框的整段文字吸进来。
        let tolerance = max(
            0.006,
            min(0.020, min(normalizedBubble.width, normalizedBubble.height) * 0.08)
        )
        return normalizedBubble
            .insetBy(dx: -tolerance, dy: -tolerance)
            .contains(normalizedText)
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
