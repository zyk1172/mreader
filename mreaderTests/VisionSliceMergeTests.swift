import XCTest
@testable import mreader

/// `VisionSliceMerger` 回归：长条页跨切片半句必须拼回完整原文，
/// 且不得把不同气泡、不同方向或相距过远的文字误拼成一句。
final class VisionSliceMergeTests: XCTestCase {

    // MARK: - 夹具

    /// 两个相邻切片：slice 0 覆盖 0.00~0.50，slice 1 覆盖 0.45~1.00，
    /// 重叠带 = 0.45~0.50（高度 0.05）。
    private var adjacentSlices: (upper: CGRect, lower: CGRect) {
        (
            upper: CGRect(x: 0, y: 0, width: 1, height: 0.50),
            lower: CGRect(x: 0, y: 0.45, width: 1, height: 0.55)
        )
    }

    private func block(
        _ text: String,
        y: CGFloat,
        height: CGFloat = 0.04,
        x: CGFloat = 0.20,
        width: CGFloat = 0.30,
        translation: String? = nil,
        bubbleBox: CGRect? = nil,
        orientation: TextOrientation = .horizontal,
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
            layoutRole: .dialogue
        )
    }

    // MARK: - 正向

    func testAdjacentSlicesJoinSplitHalvesIntoOneBlock() {
        let slices = adjacentSlices
        let outcome = VisionSliceMerger.merge(
            observations: [
                VisionSliceObservation(
                    index: 0,
                    sourceRect: slices.upper,
                    blocks: [block("今日は", y: 0.44, translation: "今天")]
                ),
                VisionSliceObservation(
                    index: 1,
                    sourceRect: slices.lower,
                    blocks: [block("いい天気", y: 0.48, translation: "天气真好")]
                )
            ],
            isRightToLeft: false
        )

        XCTAssertEqual(outcome.blocks.count, 1, "半句必须合并成一个 translation unit")
        let merged = try? XCTUnwrap(outcome.blocks.first)
        XCTAssertEqual(merged?.text, "今日はいい天気", "sourceText 必须拼成完整原文")
        XCTAssertNil(merged?.translation, "不得直接拼两段旧译文，必须重新翻译")
        XCTAssertEqual(outcome.retranslationRequiredBlockIDs.count, 1)
        XCTAssertEqual(merged?.id, outcome.retranslationRequiredBlockIDs.first)
    }

    func testMergedGeometryIsUnionOfBothHalves() {
        let slices = adjacentSlices
        let outcome = VisionSliceMerger.merge(
            observations: [
                VisionSliceObservation(
                    index: 0,
                    sourceRect: slices.upper,
                    blocks: [block("上", y: 0.44, height: 0.04)]
                ),
                VisionSliceObservation(
                    index: 1,
                    sourceRect: slices.lower,
                    blocks: [block("下", y: 0.48, height: 0.06)]
                )
            ],
            isRightToLeft: false
        )

        let merged = outcome.blocks.first
        XCTAssertEqual(merged?.boundingBox.minY ?? 0, 0.44, accuracy: 0.0001)
        XCTAssertEqual(merged?.boundingBox.maxY ?? 0, 0.54, accuracy: 0.0001)
    }

    func testMergedBubbleBoxIsUnionWhenBothSlicesReportedOne() {
        let slices = adjacentSlices
        let outcome = VisionSliceMerger.merge(
            observations: [
                VisionSliceObservation(
                    index: 0,
                    sourceRect: slices.upper,
                    blocks: [block("上", y: 0.43, bubbleBox: CGRect(x: 0.17, y: 0.41, width: 0.36, height: 0.08))]
                ),
                VisionSliceObservation(
                    index: 1,
                    sourceRect: slices.lower,
                    blocks: [block("下", y: 0.47, bubbleBox: CGRect(x: 0.17, y: 0.45, width: 0.36, height: 0.10))]
                )
            ],
            isRightToLeft: false
        )

        XCTAssertEqual(outcome.blocks.count, 1)
        XCTAssertEqual(outcome.blocks.first?.bubbleBox?.minY ?? 0, 0.41, accuracy: 0.0001)
        XCTAssertEqual(outcome.blocks.first?.bubbleBox?.maxY ?? 0, 0.55, accuracy: 0.0001)
    }

    func testOverlappingDuplicateKeepsLongerTextWithoutDuplicatingIt() {
        let slices = adjacentSlices
        let outcome = VisionSliceMerger.merge(
            observations: [
                VisionSliceObservation(
                    index: 0,
                    sourceRect: slices.upper,
                    blocks: [block("おはよう", y: 0.44, translation: "早上好")]
                ),
                VisionSliceObservation(
                    index: 1,
                    sourceRect: slices.lower,
                    blocks: [block("おはようございます", y: 0.46, translation: "早上好呀")]
                )
            ],
            isRightToLeft: false
        )

        XCTAssertEqual(outcome.blocks.count, 1)
        XCTAssertEqual(outcome.blocks.first?.text, "おはようございます", "前缀重复应取更全的一侧")
        XCTAssertEqual(outcome.blocks.first?.translation, "早上好呀", "重复不是拼接，保留已有译文")
        XCTAssertTrue(outcome.retranslationRequiredBlockIDs.isEmpty)
    }

    // MARK: - 反向：不允许合并

    func testNonAdjacentSlicesAreNotMerged() {
        let slices = adjacentSlices
        let outcome = VisionSliceMerger.merge(
            observations: [
                VisionSliceObservation(index: 0, sourceRect: slices.upper, blocks: [block("今日は", y: 0.44)]),
                VisionSliceObservation(index: 2, sourceRect: slices.lower, blocks: [block("いい天気", y: 0.48)])
            ],
            isRightToLeft: false
        )

        XCTAssertEqual(outcome.blocks.count, 2, "只有相邻切片允许合并")
        XCTAssertTrue(outcome.retranslationRequiredBlockIDs.isEmpty)
    }

    func testBlocksFarOutsideOverlapBandAreNotMerged() {
        let slices = adjacentSlices
        let outcome = VisionSliceMerger.merge(
            observations: [
                VisionSliceObservation(index: 0, sourceRect: slices.upper, blocks: [block("今日は", y: 0.10)]),
                VisionSliceObservation(index: 1, sourceRect: slices.lower, blocks: [block("いい天気", y: 0.80)])
            ],
            isRightToLeft: false
        )

        XCTAssertEqual(outcome.blocks.count, 2, "相距很远的文字不能拼成一句")
    }

    func testMismatchedTextOrientationIsNotMerged() {
        let slices = adjacentSlices
        let outcome = VisionSliceMerger.merge(
            observations: [
                VisionSliceObservation(
                    index: 0,
                    sourceRect: slices.upper,
                    blocks: [block("今日は", y: 0.44, orientation: .vertical)]
                ),
                VisionSliceObservation(
                    index: 1,
                    sourceRect: slices.lower,
                    blocks: [block("いい天気", y: 0.48, orientation: .horizontal)]
                )
            ],
            isRightToLeft: false
        )

        XCTAssertEqual(outcome.blocks.count, 2, "阅读方向不一致不得合并")
    }

    func testMismatchedFontScaleIsNotMerged() {
        let slices = adjacentSlices
        let outcome = VisionSliceMerger.merge(
            observations: [
                VisionSliceObservation(
                    index: 0,
                    sourceRect: slices.upper,
                    blocks: [block("今日は", y: 0.44, fontScale: 0.02)]
                ),
                VisionSliceObservation(
                    index: 1,
                    sourceRect: slices.lower,
                    blocks: [block("いい天気", y: 0.48, fontScale: 0.09)]
                )
            ],
            isRightToLeft: false
        )

        XCTAssertEqual(outcome.blocks.count, 2, "字号差异过大（大标题 / 小对白）不得合并")
    }

    func testHorizontallyDisplacedBlocksAreNotMerged() {
        let slices = adjacentSlices
        let outcome = VisionSliceMerger.merge(
            observations: [
                VisionSliceObservation(
                    index: 0,
                    sourceRect: slices.upper,
                    blocks: [block("左", y: 0.44, x: 0.05, width: 0.20)]
                ),
                VisionSliceObservation(
                    index: 1,
                    sourceRect: slices.lower,
                    blocks: [block("右", y: 0.48, x: 0.65, width: 0.20)]
                )
            ],
            isRightToLeft: false
        )

        XCTAssertEqual(outcome.blocks.count, 2, "中轴偏移过大不得合并")
    }

    func testSingleSliceReturnsInputUnchanged() {
        let slice = CGRect(x: 0, y: 0, width: 1, height: 1)
        let outcome = VisionSliceMerger.merge(
            observations: [
                VisionSliceObservation(index: 0, sourceRect: slice, blocks: [block("一行", y: 0.30)])
            ],
            isRightToLeft: false
        )

        XCTAssertEqual(outcome.blocks.count, 1)
        XCTAssertEqual(outcome.blocks.first?.text, "一行")
        XCTAssertTrue(outcome.retranslationRequiredBlockIDs.isEmpty)
    }

    func testBlockConsumedOnceAcrossThreeSlices() {
        // 三个切片：0(0~0.40) / 1(0.36~0.72) / 2(0.68~1.00)。
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
                    blocks: [block("あ", y: 0.34, translation: "a")]
                ),
                VisionSliceObservation(
                    index: 1,
                    sourceRect: slices[1],
                    blocks: [block("い", y: 0.38, translation: "i")]
                ),
                VisionSliceObservation(
                    index: 2,
                    sourceRect: slices[2],
                    blocks: [block("う", y: 0.70, translation: "u")]
                )
            ],
            isRightToLeft: false
        )

        // 0/1 在 overlap(0.36~0.40) 处拼接；2 远离 overlap 不参与。
        XCTAssertEqual(outcome.blocks.count, 2)
        XCTAssertEqual(outcome.blocks.first?.text, "あい")
        XCTAssertNil(outcome.blocks.first?.translation)
        XCTAssertEqual(outcome.blocks.last?.text, "う")
        XCTAssertEqual(outcome.retranslationRequiredBlockIDs.count, 1)
    }
}
