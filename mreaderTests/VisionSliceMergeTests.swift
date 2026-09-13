import XCTest
@testable import mreader

/// `VisionSliceMerger` 回归。
///
/// 夹具刻意使用**真实切片几何**：相邻切片的重叠带是 0.45~0.50，
/// 上切片的裁剪底边 = 0.50、下切片的裁剪顶边 = 0.45。
/// 被切开的一半，其 textBox / bubbleBox 必然触及对应的裁剪边缘；
/// 完整落在切片内部的气泡则达不到，这正是区分「同一句话」与「两个不同气泡」的关键证据。
final class VisionSliceMergeTests: XCTestCase {

    /// sliceA 覆盖 0.00~0.50，sliceB 覆盖 0.45~1.00。
    private var sliceA: CGRect { CGRect(x: 0, y: 0, width: 1, height: 0.50) }
    private var sliceB: CGRect { CGRect(x: 0, y: 0.45, width: 1, height: 0.55) }

    private func block(
        _ text: String,
        y: CGFloat,
        height: CGFloat,
        x: CGFloat = 0.20,
        width: CGFloat = 0.30,
        translation: String? = nil,
        bubbleBox: CGRect? = nil,
        orientation: TextOrientation = .horizontal,
        layoutRole: TranslationLayoutRole = .dialogue,
        fontScale: Double? = nil
    ) -> TextBlock {
        TextBlock(
            text: text,
            boundingBox: CGRect(x: x, y: y, width: width, height: height),
            translation: translation,
            confidence: 0.9,
            ocrSource: "vision-model:dialogue",
            estimatedFontScale: fontScale ?? Double(height),
            bubbleBox: bubbleBox,
            textOrientation: orientation,
            layoutRole: layoutRole
        )
    }

    /// 被上切片切开的半句：底边正好落在上切片裁剪底边上。
    private func upperHalf(
        _ text: String,
        bottom: CGFloat = 0.50,
        height: CGFloat = 0.06,
        translation: String? = nil,
        bubbleBox: CGRect? = nil,
        orientation: TextOrientation = .horizontal,
        layoutRole: TranslationLayoutRole = .dialogue,
        x: CGFloat = 0.20,
        width: CGFloat = 0.30,
        fontScale: Double? = nil
    ) -> TextBlock {
        block(
            text,
            y: bottom - height,
            height: height,
            x: x,
            width: width,
            translation: translation,
            bubbleBox: bubbleBox,
            orientation: orientation,
            layoutRole: layoutRole,
            fontScale: fontScale
        )
    }

    /// 被下切片切开的半句：顶边正好落在下切片裁剪顶边上。
    private func lowerHalf(
        _ text: String,
        top: CGFloat = 0.45,
        height: CGFloat = 0.07,
        translation: String? = nil,
        bubbleBox: CGRect? = nil,
        orientation: TextOrientation = .horizontal,
        layoutRole: TranslationLayoutRole = .dialogue,
        x: CGFloat = 0.20,
        width: CGFloat = 0.30,
        fontScale: Double? = nil
    ) -> TextBlock {
        block(
            text,
            y: top,
            height: height,
            x: x,
            width: width,
            translation: translation,
            bubbleBox: bubbleBox,
            orientation: orientation,
            layoutRole: layoutRole,
            fontScale: fontScale
        )
    }

    private func merge(_ upperBlocks: [TextBlock], _ lowerBlocks: [TextBlock]) -> VisionSliceMergeOutcome {
        VisionSliceMerger.merge(
            observations: [
                VisionSliceObservation(index: 0, sourceRect: sliceA, blocks: upperBlocks),
                VisionSliceObservation(index: 1, sourceRect: sliceB, blocks: lowerBlocks)
            ],
            isRightToLeft: false
        )
    }

    // MARK: - 纯文本拼接

    func testJoinedSourceTextRemovesSuffixPrefixOverlap() {
        XCTAssertEqual(
            VisionSliceMerger.joinedSourceText(upper: "今日はいい", lower: "いい天気"),
            "今日はいい天気",
            "重叠部分只能出现一次，不能退化成「今日はいいいい天気」"
        )
        XCTAssertEqual(
            VisionSliceMerger.joinedSourceText(upper: "Hello wor", lower: "world"),
            "Hello world"
        )
        XCTAssertEqual(
            VisionSliceMerger.joinedSourceText(upper: "今日は", lower: "いい天気"),
            "今日はいい天気"
        )
        XCTAssertEqual(
            VisionSliceMerger.joinedSourceText(upper: "Hello, wor", lower: "world!"),
            "Hello, world!"
        )
    }

    func testJoinedSourceTextAddsSpaceForNonOverlappingLatinText() {
        XCTAssertEqual(
            VisionSliceMerger.joinedSourceText(upper: "Hello", lower: "world"),
            "Hello world",
            "拉丁文没有重叠时不能直接粘连"
        )
        XCTAssertEqual(
            VisionSliceMerger.joinedSourceText(upper: "Hello ", lower: "world"),
            "Hello world"
        )
        XCTAssertEqual(
            VisionSliceMerger.joinedSourceText(upper: "今日は", lower: "いい天気"),
            "今日はいい天気",
            "中日文不补空格"
        )
    }

    func testOverlapLengthReportsCoveredPrefix() {
        XCTAssertEqual(VisionSliceMerger.overlappedPrefixLength(upper: "今日はいい", lower: "いい天気"), 2)
        XCTAssertEqual(VisionSliceMerger.overlappedPrefixLength(upper: "Hello wor", lower: "world"), 3)
        XCTAssertEqual(VisionSliceMerger.overlappedPrefixLength(upper: "おはよう", lower: "ございます"), 0)
    }

    // MARK: - 正向：切开的半句必须拼回一句

    func testAdjacentSlicesJoinSplitHalvesIntoOneBlock() {
        let outcome = merge(
            [upperHalf("今日は", translation: "今天")],
            [lowerHalf("いい天気", translation: "天气真好")]
        )

        XCTAssertEqual(outcome.blocks.count, 1, "半句必须合并成一个 translation unit")
        let merged = outcome.blocks.first
        XCTAssertEqual(merged?.text, "今日はいい天気")
        XCTAssertEqual(outcome.retranslationRequiredBlockIDs.count, 1)
        XCTAssertEqual(merged?.id, outcome.retranslationRequiredBlockIDs.first)
        // 拼接后的译文只是最长一半的临时兜底，必须由调用方对完整原文定向重译。
        XCTAssertEqual(merged?.translation, "天气真好")
    }

    func testPartiallyOverlappingHalvesAreJoinedWithoutDuplication() {
        let outcome = merge(
            [upperHalf("今日はいい", translation: "今天很")],
            [lowerHalf("いい天気", translation: "天气好")]
        )

        XCTAssertEqual(outcome.blocks.count, 1)
        XCTAssertEqual(outcome.blocks.first?.text, "今日はいい天気")
        XCTAssertEqual(outcome.retranslationRequiredBlockIDs.count, 1)
    }

    func testEnglishHalvesJoinWithoutDoublingTheOverlap() {
        let outcome = merge(
            [upperHalf("Hello wor", translation: "你好 wo")],
            [lowerHalf("world", translation: "世界")]
        )

        XCTAssertEqual(outcome.blocks.count, 1)
        XCTAssertEqual(outcome.blocks.first?.text, "Hello world")
    }

    func testMergedGeometryAndBubbleAreUnions() {
        let outcome = merge(
            [
                upperHalf(
                    "上",
                    bottom: 0.50,
                    height: 0.06,
                    bubbleBox: CGRect(x: 0.17, y: 0.40, width: 0.36, height: 0.10)
                )
            ],
            [
                lowerHalf(
                    "下",
                    top: 0.45,
                    height: 0.07,
                    bubbleBox: CGRect(x: 0.17, y: 0.44, width: 0.36, height: 0.12)
                )
            ]
        )

        XCTAssertEqual(outcome.blocks.count, 1)
        XCTAssertEqual(outcome.blocks.first?.boundingBox.minY ?? 0, 0.44, accuracy: 0.0001)
        XCTAssertEqual(outcome.blocks.first?.boundingBox.maxY ?? 0, 0.52, accuracy: 0.0001)
        XCTAssertEqual(outcome.blocks.first?.bubbleBox?.minY ?? 0, 0.40, accuracy: 0.0001)
        XCTAssertEqual(outcome.blocks.first?.bubbleBox?.maxY ?? 0, 0.56, accuracy: 0.0001)
    }

    func testOverlappingDuplicateKeepsLongerTextWithoutDuplicatingIt() {
        let outcome = merge(
            [upperHalf("おはよう", translation: "早上好")],
            [lowerHalf("おはようございます", translation: "早上好呀")]
        )

        XCTAssertEqual(outcome.blocks.count, 1)
        XCTAssertEqual(outcome.blocks.first?.text, "おはようございます", "前缀重复应取更全的一侧")
        XCTAssertEqual(outcome.blocks.first?.translation, "早上好呀", "重复不是拼接，可沿用已有译文")
        XCTAssertTrue(outcome.retranslationRequiredBlockIDs.isEmpty)
    }

    // MARK: - 反向：不允许合并

    func testCompleteBubblesNearTheSliceBoundaryAreNotMerged() {
        // 两个完整气泡分别落在切片内部（没有触及裁剪边缘），即便位置很近也不能拼。
        let outcome = merge(
            [upperHalf("こんにちは", bottom: 0.47)],
            [lowerHalf("さようなら", top: 0.47)]
        )

        XCTAssertEqual(outcome.blocks.count, 2, "完整气泡没有被切开，不能拼成一句")
        XCTAssertTrue(outcome.retranslationRequiredBlockIDs.isEmpty)
    }

    func testBubbleEvidenceBlocksMergeWhenBubblesWereNotCut() {
        // 文字框看似被切开，但两侧气泡都是完整的 → 属于两个不同气泡。
        let outcome = merge(
            [
                upperHalf(
                    "今日はいい",
                    bubbleBox: CGRect(x: 0.17, y: 0.34, width: 0.36, height: 0.13)
                )
            ],
            [
                lowerHalf(
                    "いい天気",
                    bubbleBox: CGRect(x: 0.17, y: 0.47, width: 0.36, height: 0.09)
                )
            ]
        )

        XCTAssertEqual(outcome.blocks.count, 2, "bubbleBox 必须和 textBox 一样被切开才允许合并")
    }

    func testNonAdjacentSlicesAreNotMerged() {
        let outcome = VisionSliceMerger.merge(
            observations: [
                VisionSliceObservation(index: 0, sourceRect: sliceA, blocks: [upperHalf("今日は")]),
                VisionSliceObservation(index: 2, sourceRect: sliceB, blocks: [lowerHalf("いい天気")])
            ],
            isRightToLeft: false
        )

        XCTAssertEqual(outcome.blocks.count, 2, "只有相邻切片允许合并")
    }

    func testBlocksFarOutsideTheSliceBoundaryAreNotMerged() {
        let outcome = merge(
            [block("今日は", y: 0.10, height: 0.05)],
            [block("いい天気", y: 0.80, height: 0.05)]
        )

        XCTAssertEqual(outcome.blocks.count, 2, "相距很远的文字不能拼成一句")
    }

    func testMismatchedTextOrientationIsNotMerged() {
        let outcome = merge(
            [upperHalf("今日は", orientation: .vertical)],
            [lowerHalf("いい天気", orientation: .horizontal)]
        )

        XCTAssertEqual(outcome.blocks.count, 2, "阅读方向不一致不得合并")
    }

    func testMismatchedLayoutRoleIsNotMerged() {
        let outcome = merge(
            [upperHalf("今日は", layoutRole: .dialogue)],
            [lowerHalf("いい天気", layoutRole: .standalone)]
        )

        XCTAssertEqual(outcome.blocks.count, 2, "对白与拟声词 / 旁白不能拼成一句")
    }

    func testMismatchedFontScaleIsNotMerged() {
        let outcome = merge(
            [upperHalf("今日は", fontScale: 0.02)],
            [lowerHalf("いい天気", fontScale: 0.09)]
        )

        XCTAssertEqual(outcome.blocks.count, 2, "字号差异过大（大标题 / 小对白）不得合并")
    }

    func testHorizontallyDisplacedBlocksAreNotMerged() {
        let outcome = merge(
            [upperHalf("左", x: 0.05, width: 0.20)],
            [lowerHalf("右", x: 0.65, width: 0.20)]
        )

        XCTAssertEqual(outcome.blocks.count, 2, "中轴偏移过大不得合并")
    }

    func testSingleSliceReturnsInputUnchanged() {
        let outcome = VisionSliceMerger.merge(
            observations: [
                VisionSliceObservation(
                    index: 0,
                    sourceRect: CGRect(x: 0, y: 0, width: 1, height: 1),
                    blocks: [block("一行", y: 0.30, height: 0.05)]
                )
            ],
            isRightToLeft: false
        )

        XCTAssertEqual(outcome.blocks.count, 1)
        XCTAssertEqual(outcome.blocks.first?.text, "一行")
        XCTAssertTrue(outcome.retranslationRequiredBlockIDs.isEmpty)
    }

    func testBlockConsumedOnceAcrossThreeSlices() {
        let slices = [
            CGRect(x: 0, y: 0, width: 1, height: 0.40),
            CGRect(x: 0, y: 0.36, width: 1, height: 0.36),
            CGRect(x: 0, y: 0.68, width: 1, height: 0.32)
        ]
        let outcome = VisionSliceMerger.merge(
            observations: [
                VisionSliceObservation(
                    index: 0,
                    sourceRect: slices[0],
                    // 被 slice0 底边（0.40）切开。
                    blocks: [block("あ", y: 0.34, height: 0.06, translation: "a")]
                ),
                VisionSliceObservation(
                    index: 1,
                    sourceRect: slices[1],
                    // 被 slice1 顶边（0.36）切开。
                    blocks: [block("い", y: 0.36, height: 0.06, translation: "i")]
                ),
                VisionSliceObservation(
                    index: 2,
                    sourceRect: slices[2],
                    blocks: [block("う", y: 0.70, height: 0.06, translation: "u")]
                )
            ],
            isRightToLeft: false
        )

        XCTAssertEqual(outcome.blocks.count, 2, "0/1 拼接，2 不参与")
        XCTAssertEqual(outcome.blocks.first?.text, "あい")
        XCTAssertEqual(outcome.blocks.last?.text, "う")
        XCTAssertEqual(outcome.retranslationRequiredBlockIDs.count, 1)
    }
}
