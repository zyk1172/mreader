# MReader Agent Notes

这份文档记录 MReader 的项目级开发约束，供后续编码与审核使用。

## 项目范围

- 项目根目录是当前文件所在目录，Xcode 工程为 `mreader.xcodeproj`。
- App 是 SwiftUI iOS 漫画阅读器；核心模块包括本地/Komga 书架、阅读器、OCR、AI 翻译和缓存。
- 修改前先检查 `git status`，不要覆盖用户已有的未提交改动。
- 与本次问题无关的 `LocalWebServer` 并发代码不要和翻译 UI 或 OCR 分组修改混在同一个逻辑变更中。

## 翻译气泡分组不变量

`MangaTextSegmenter` 必须先建立 canonical bubble region，再建立 translation unit：

- 只有通过验证的 bubbleBox 才能创建 region；相同物理气泡的轻微几何漂移要去重。
- 每个 OCR line 先按 textBox 归属 region，再在 region 内按阅读顺序合并；行距、字号、颜色和 layoutRole 不能决定同一 region 的翻译次数。
- region 外的 line 保持独立的 measured-text translation unit；不能用 dialogue gap heuristic 凭空猜出漫画气泡。
- 明确不同的 bubble region 禁止合并。

变更 `bubbleBox` 分组逻辑时，至少保留以下回归场景：

- `overlappingDistinctVisualBubblesDoNotMerge`：重叠但不同的气泡不能合并。
- `nestedButDifferentBubbleGeometryDoesNotAutomaticallyBecomeSameIdentity`：单向外围框包含内部框不能自动成为同一 region。
- 同一气泡多行、混合 bubbleBox/nil line、行距不规则或视觉框轻微漂移时仍只产生一个 unit。
- 无 `bubbleBox` 的纯 OCR 多行保持独立；它们仍然使用紧贴最终译文测量范围的 measured-text 卡片。

## 表面样式不变量

- `detectedBubble` 和 `measuredText` 的 `drawsBackground` 都必须为 `true`。
- 可靠 `bubbleBox` 使用真实气泡几何；不可靠或缺失时使用 measured-text 几何，卡片尺寸只能来自最终译文测量结果。
- `ReaderView` 的背景和边框统一绘制 RoundedRectangle；两种 surface style 只区分几何来源，不能让 OCR `sourceRect` 成为 measured-text 卡片的最小宽高。
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
