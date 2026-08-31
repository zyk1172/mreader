# MReader Agent Notes

这份文档记录 MReader 的项目级开发约束，供后续编码与审核使用。

## 项目范围

- 项目根目录是当前文件所在目录，Xcode 工程为 `mreader.xcodeproj`。
- App 是 SwiftUI iOS 漫画阅读器；核心模块包括本地/Komga 书架、阅读器、OCR、AI 翻译和缓存。
- 修改前先检查 `git status`，不要覆盖用户已有的未提交改动。
- 与本次问题无关的 `LocalWebServer` 并发代码不要和翻译 UI 或 OCR 分组修改混在同一个逻辑变更中。

## 翻译气泡分组不变量

`MangaTextSegmenter` 中必须区分两个概念：

1. `visualBubbleBoxesAreCompatible(...)` 是宽松的兼容性检查，只能作为“明确不同的视觉框”否决条件。小容差 containment 或 IoU `>= 0.18` 不足以证明同一个气泡。
2. `sameVisualBubbleIdentity(...)` 是严格的身份检查。只有高 IoU、接近的中心点、相近的 width/height、相近的面积，并且满足 mutual containment 或极严格的轻微抖动条件时，才可以跳过 OCR 弱启发式。

分组决策必须遵循：

- 明确是同一个气泡：允许跳过字号、颜色、`layoutRole`、行距和文字位置启发式，避免同气泡多行被拆开。
- 只有兼容但无法确认身份：继续使用原有 OCR fallback。
- 明确不同：禁止合并。

变更 `bubbleBox` 分组逻辑时，至少保留以下回归场景：

- `overlappingDistinctVisualBubblesDoNotMerge`：IoU 大于 `0.18` 但两个不同气泡不能合并。
- `nestedButDifferentBubbleGeometryDoesNotAutomaticallyBecomeSameIdentity`：单向外围框包含内部框不能自动成为同一身份。
- 同一气泡多行仍能在字号、颜色或 `layoutRole` 有 OCR 波动时合并。
- 无 `bubbleBox` 的纯 OCR 多行仍保持原有 complete-link fallback 与防链式行为。

## 表面样式不变量

- `detectedBubble` 和 `syntheticBubble` 的 `drawsBackground` 都必须为 `true`。
- 可靠 `bubbleBox` 只决定背景几何来源：可靠时沿用真实气泡；不可靠或缺失时使用紧凑 synthetic bubble。
- synthetic bubble 的排版矩形由译文实际测量结果决定，不能继承整页、超宽或超高的病态 OCR 框。
- synthetic bubble 的原文最小覆盖范围必须经过 `validatedSourceCoverageRect(for:sourceRect:within:)` 的图片边界、页面范围和方向/glyph-aware 校验；又窄又高的竖排 OCR 框不能仅凭页面百分比成为 coverage。
- `ReaderView` 的背景绘制统一通过 `surfaceStyle.drawsBackground` 门控，不能恢复 `.borderless -> content` 的裸字路径。
- `TranslationLayoutRole` 与 surface style 正交；没有 `bubbleBox` 的对白不能被降级成 standalone。

## 缓存与验证

- 分组行为、气泡几何或译文单元数量变化时，必须检查 `AITranslationPageRequest` 的 cache revision 是否需要升级，避免复用旧翻译单元。
- OCR geometry revision 与 OCR cache 版本也要和实际几何语义保持一致；如果只是分组层变化，不要无理由扩大无关缓存失效范围。
- 修改 Swift 代码后优先运行视觉分组测试：

```bash
xcodebuild test \
  -project mreader.xcodeproj \
  -scheme mreader \
  -destination 'platform=iOS Simulator,id=<available-simulator-id>' \
  -only-testing:mreaderTests/VisualBubbleGroupingTests \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO
```

- 提交前运行完整单元测试或至少运行受影响的测试套件，并在总结中记录实际命令和结果。
- `README.md` 应同步描述用户可见的 OCR/翻译行为；本文件记录实现不变量，不要只更新其中一个。
