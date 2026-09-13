# mreader 代码审查报告 — 聚焦翻译逻辑

审查日期：2026-09-13
审查范围：`mreader/`（67 个 Swift 文件，38041 行）+ `mreaderTests/`（30 个测试文件）
审查重点：放大镜弹窗、视觉翻译文本正确性、缩放/平移手势、代码质量 / 性能 / 安全 / 可维护性

---

## 0. 结论摘要

| # | 议题 | 判定 | 根因所在环节 | 优先级 |
|---|---|---|---|---|
| 1 | 过小文字放大镜弹窗 | **建议移除（或降级为调试开关）**，`ocr.autoMagnify` 应默认禁用 | 渲染层命中测试 + 误触入口设计 | P0 |
| 2 | 视觉翻译返回文本不正确 | **确认存在多因缺陷** | 识别层（无 text↔box 交叉校验）+ 渲染层（缩放后覆盖层不跟随） | P0 |
| 3 | 双指放大后单指拖动平移 | **确认失效（功能未实现）** | 手势层（完全缺失平移手势）+ 坐标映射未接 zoomScale/panOffset | P0 |
| 4 | 其余维度 | 3 项 P0、9 项 P1、6 项 P2 | — | 见 §5 |

三个核心结论都指向同一类系统性缺陷：**同一份状态被多处独立推导，且推导路径之间缺少交叉校验与门控**（图 1）。

---

## 1. 放大镜弹窗：实现审查与误触风险评估

### 1.1 实现位置

放大镜不是一个独立弹窗，而是覆盖在页面图片上的一层"白底文字卡片"：

| 组件 | 位置 |
|---|---|
| 覆盖层渲染 | `ReaderView.swift:4079-4097` `ocrMagnificationOverlay(in:)` |
| 白卡布局 | `ReaderView.swift:4516-4550` `ocrLayoutItems(in:)` |
| 卡片候选来源 | `ReaderView.swift:4825-4858` `startOCRMagnification()` → `preparedOCRResult(...).bubbleBlocks` |
| 工具栏开关 | `ReaderView.swift:962-983`（右下角悬浮按钮，`text.magnifyingglass`，accessibilityLabel `reader.ocrMagnify`） |
| 每漫画自动开关 | `ReaderView.swift:1266-1270`（设置项 `ocr.autoMagnify` = 「自动文字放大」） |
| 激活判定 | `ReaderView.swift:753-755` `isOCRMagnificationActive = isOCREnabled && (visible \|\| auto)` |
| 字号 | `ReaderView.swift:4737-4739` `uniformOCRFontSize = 11 + normalizedOCRScale * 8`（11–19pt，与页面原始字号无关） |

**关于"过小文字触发"这一前提的更正**：代码中**不存在**"文字过小 → 自动弹出放大镜"的判断逻辑。实际触发路径只有两条，且都是用户显式开启：

1. 点击右下角工具栏按钮 → `isOCRMagnificationVisible.toggle()`（`ReaderView.swift:965`）；
2. 设置里打开 `ocr.autoMagnify` → `comic.isAutoOCRMagnificationEnabled = true`（`ReaderView.swift:1268`），此后**每次翻页 / 每次图片重载 / 每次改 OCR 模式都会重新触发全页识别**（`ReaderView.swift:4596-4598, 4636-4638, 3870-3876, 3949-3957`）。

"过小文字"与实际行为的关联在于**过滤阈值下限过低**：`ocrMinimumTextHeight` 默认 `0.002` 且滑杆下限就是 `0.002`（`ComicBook.swift:141`、`ReaderView.swift:1369`），`annotatedMangaTextBlocks` 只丢弃 `height < minimumHeight || area < minimumHeight*0.0048` 的块（`AITranslator.swift:3282-3327`）。因此在默认配置下，页码、水印、边角拟声、广告级小字几乎**全部通过过滤**并进入 `bubbleBlocks`，每块都生成一张白底卡片。用户观感即"小字一多，满屏白卡弹窗"。

### 1.2 误触风险：确认成立，且有 4 条硬证据

| # | 证据 | 位置 | 后果 |
|---|---|---|---|
| E1 | **覆盖层未禁用命中测试**。翻译覆盖层两处显式 `.allowsHitTesting(false)`（`ReaderView.swift:4024, 4041`），而放大镜覆盖层**没有** | `ReaderView.swift:4079-4097` | 白卡吞掉其下方所有触摸：点击翻页、长按翻译在卡片区域内全部失效；用户"点不动"，只能再次点开关关闭 → 典型误触后无法自恢复 |
| E2 | **开关紧邻 AI 翻译按钮**，同为 44×44、间距 10pt | `ReaderView.swift:960-1000` | 想按 AI 翻译却误开放大镜。开启即触发一次全页 Vision OCR（GPU/CPU 重负载 + 耗电），且页面被白卡完全遮挡 |
| E3 | **开关随控制栏隐藏而消失**，但覆盖层不会消失 | `ReaderView.swift:941-955, 957` | 关闭控制栏后无任何可点区域能关掉白卡，用户被困在遮挡态 |
| E4 | **`isRecognizingOCR` 守卫导致"开了没反应"**：`loadImage()` 先 `cancel()` 旧任务再调 `startOCRMagnification()`，但旧任务的 catch 尚未执行、标志仍为 `true`，新调用被 `guard !isRecognizingOCR` 直接返回 | `ReaderView.swift:4826, 4560-4561, 4596-4598` | 翻页后放大镜静默失效（覆盖层空白），需再次手动切换才恢复 |

补充：放大镜与 AI 翻译**各自独立跑一遍完整 OCR**（`recognizedPipelineResult` 走同一缓存，但放大镜只在 `ocrTextBlocks` 消费 `bubbleBlocks`），在"自动翻译 + 自动放大"同时开启时，同一页会触发两次全页识别调度。

### 1.3 判定：移除或禁用

**建议：从生产渲染路径移除 `ocrMagnificationOverlay`；`ocr.autoMagnify` 开关默认关闭并标注为实验项（或直接删除）。**

理由：
- 该功能的业务价值（放大难读小字）已被两条更强路径覆盖：① 用户本身就有的双指缩放；② AI 翻译气泡重新排版（`translationOverlay`，正确设置了命中测试豁免与防重叠布局 `ReaderView.swift:4419-4488`）。
- 它带来的负向成本是确定的：遮挡画面、吞触摸、与翻译重复跑 OCR、误触后难以退出。
- 若保留，最低限度必须补：`allowsHitTesting(false)`（E1）、与 AI 按钮拉开距离/移入控制栏二级菜单（E2）、覆盖层内提供关闭入口（E3）、用独立于 `isRecognizingOCR` 的代际 token 替代布尔守卫（E4）。

---

## 2. 视觉翻译返回文本不正确：分环节定位

审查链路：识别 → 文本/译文配对 → 坐标映射 → 语言处理 → 渲染。

### 2.1 逐环节结论

| 环节 | 是否缺陷源 | 依据 |
|---|---|---|
| **识别（vision 请求）** | **是（主因）** | 请求体正确（整页 JPEG + `defaultVisionTranslationPromptTemplate`，`AITranslator.swift:700-730, 1833-1865`）；但**响应解析只做结构校验，不做"文字↔坐标"交叉校验**（见 2.2） |
| **文本/译文配对** | 否（配对本身正确） | `parseVisionTranslationBlocks` 的 `sourceText`/`translation`/`textBox` **取自同一 item**，不依赖数组下标、不读 `id`（`AITranslator.swift:2660-2689`），因此顺序打乱不会串译；strict 路径按 id 映射并强制数量相等（`AIPageTranslation.swift:411-481`） |
| **坐标映射** | **否（映射正确）/ 是（渲染时未接缩放）** | 归一化 0–1 线性映射，数学正确（`AITranslator.swift:2749-2778`、`OCRCoordinateMapper.swift:65-88`）；但 `ReaderView.swift:4245-4249` 调用 `displayTransform` 时**未传 `zoomScale`/`panOffset`**（参数存在但全仓 0 调用，`OCRCoordinateMapper.swift:19-20`）→ 一旦用户缩放，所有气泡坐标仍按 1× 计算 → 放大后译文整体错位。这最容易被用户描述为"翻译文字不对" |
| **语言处理** | **是（次因）** | 中文目标语言校验要求 `han > 0 && kana == 0 && hangul == 0`（`AIPageTranslation.swift:752-755`）；纯拉丁/数字/象声译文（"OK!"、"SOS"、"ドン" 的拉丁转写）判为不兼容 |
| **渲染** | 否（不改写文本，但会放大错位观感） | `displayTranslation`（`ReaderView.swift:4054-4067`）与 `TranslationTextRenderer` 的 `.clipped()`（`ReaderView.swift:5507`）只裁剪不改内容 |

### 2.2 主因证据：vision 链路缺少校验，且与 OCR 链路能力不对称

`parseVisionTranslationBlocks` 的 `requiresTextBox` 分支逐项校验 `sourceText` 非空、`translation` 非空、`textBox`/`layoutSafeRegion` 存在、`confidence ∈ [0,1]`、`classification` 合法（`AITranslator.swift:2605-2643`），**但从不检查模型给的 `textBox` 是否真的对应 `sourceText`，也不做任何"模型是否看错行/看错气泡"的复核**。译文直接落在模型给出的框上（`AITranslator.swift:2687, 2754-2755, 2779-2790`）。

而 OCR 链路有、vision 链路没有的两道校正：

- 视觉复核 `TranslationRuntimeService.visualVerifyOCRRegions(...)` —— 仅 OCR 分支调用（`AITranslationPageCoordinator.swift:432-454`），vision 分支直接 `return`（`AITranslationPageCoordinator.swift:352-371`）→ 离线路径才跑 `TranslationGeometryRefiner`（离线专用）。
- 结果：OCR 模式下模型的错误会被二次复核压低，vision 模式下模型错了就是最终结果。**这就是"视觉翻译文本不正确"最直接的机制**——尤其是竖排日漫（同页多气泡、文字与气泡错配概率高）。

### 2.3 其余可复现根因（按置信度排序）

**① 切片路径丢字 / 拆句（高，长条页必现）**
`shouldSliceBeforeVision` 在 `height/width > 2.2` 时切片（`AITranslator.swift:2404-2409`），切片间有 10% 重叠（`AITranslator.swift:2494-2554`）。相邻切片对**同一气泡**可能各自返回半句原文；聚合阶段**只做去重、不做文本合并**（`AITranslator.swift:1373` 调 `deduplicatedMangaTextBlocks`，全仓无跨切片文本拼接函数）。去重策略是"每个重复组只保留一个代表、其余进 rejected"（`OCRCandidateResolver.swift:57-97`）。后果：
- 两组文本不同 → 只留一组 → **另半句永久丢失**，译文残缺；
- 因两半高度不同导致 IoU < 0.55（`OCRCandidateResolver.swift:164-192`）→ **同一气泡被保留两份**，同一句话被拆成两段各自翻译 → 观感即"译文错乱、串行"。

**② 语言校验误杀 → 静默变空（中高）**
`isCompatible` 对中文目标要求必须含汉字（`AIPageTranslation.swift:752-755`）。在 vision 非 strict 路径中，失败结果被**静默置空**（`AITranslator.swift:2676-2681 → ?? ""`），`TextBlock.translation` 为空 → `visibleTranslationBlocks` 过滤掉（`ReaderView.swift:4047-4052`）→ 该气泡译文直接消失。strict 路径则更激进：任一项不兼容即 `throw .pageLanguageMismatch`（`AIPageTranslation.swift:446-452`），整页失败；页级二次校验同样会整页抛错（`AIPageTranslation.swift:476-479`，`NLLanguageRecognizer` 在 `AIPageTranslation.swift:801-825`，存在把正确英文误判为荷兰语从而整页回退的风险）。

**③ 坐标声明严格性 → 整页失效（中）**
`visionCoordinateSpaceIsNormalized` 要求顶层显式声明 `coordinateSpace` 且每个坐标点严格落在 `[0, 1]`（`AITranslator.swift:3167-3205`；容差仅 `1.000001`）。模型输出 `1.02` 或省略声明 → `throw .invalidCoordinates` → 整页无译文。这是设计上的取舍（防像素/百分比误判，注释见 `AITranslator.swift:2736-2737`），但成本是"整页硬失败"而非"逐项降级"。

**④ 用户自定义 Prompt 覆盖默认模板（中）**
`@AppStorage("vision_translation_prompt_template")` 直接覆盖内置模板（`ReaderView.swift:3682, 5095`；`AITranslator.swift:2276-2281`）。`renderVisionPrompt` **只替换 `{targetLanguage}` 与 `{readingOrder}` 两个占位符**，且对缺失占位符无任何校验/警告。旧版本保存过的模板若不含 `{targetLanguage}`，模型无从得知目标语言 → 返回原文或错误语言，且 UI 上没有任何提示。默认模板本身包含该占位符（`AITranslator.swift:702`），故仅影响存量用户/自定义场景。

---

## 3. 双指放大后单指拖动平移：确认失效（缺陷为"未实现"）

### 3.1 根因（三条独立缺陷叠加）

**D1 — 平移手势完全不存在**
缩放容器只挂了一个手势：

```swift
// ReaderView.swift:4686-4701
private var zoomGesture: some Gesture {
    MagnificationGesture()
        .onChanged { value in scale = min(max(lastScale * value, 1), 5) }
        .onEnded { _ in ... offset = .zero }   // 结束即归零
}
```

全文件 `offset` 只有 3 处赋值，全部是 `.zero`（`ReaderView.swift:4588, 4621, 4697`），**没有任何 `DragGesture` 写入 `offset`**（`DragGesture` 仅出现在 3082 / 3279，均为翻页用途）。结论：`offset` 是死状态，单指拖动永远不会平移图片。

**D2 — 父级翻页拖拽未按缩放门控（放大时单指拖动被翻页抢占）**
水平翻页容器的 `DragGesture(minimumDistance: 28)` 挂在包住所有页面视图的外层 `ZStack` 上（`ReaderView.swift:3081-3097`），且手势类型与 `MagnificationGesture` 不同，两者可同时识别。放大后单指拖动会被这个 28pt 阈值的翻页手势接管 → **放大状态下单指拖动 = 翻页**，与用户预期（平移查看）完全相反。

对照组可以证明这是遗漏而非设计：同一文件的点击与长按手势都显式加了缩放门控 `guard scale <= 1.05 else { return }`（`ReaderView.swift:4707, 4729`），唯独外层翻页拖拽没有。

**D3 — 坐标映射层已支持缩放/平移，但调用方从未传入（覆盖层错位）**
`OCRCoordinateMapper.displayTransform` 预留了 `zoomScale` 与 `panOffset`（`OCRCoordinateMapper.swift:19-20`，内用于 `appliedZoom` 与 `center` 计算，`:48-56`），但唯一的调用点 `ReaderView.ocrDisplayTransform(in:)` 只传了 `sourcePixelSize`/`containerSize`/`fitMode`（`ReaderView.swift:4245-4249`）。全仓 `zoomScale`/`panOffset` **零调用者**。

后果：`scaleEffect(scale)` 只视觉放大图片本体（`ReaderView.swift:3728`），而气泡与调试框仍按 1× 坐标系定位（覆盖层挂在图片 `overlay` 内、随 `scaleEffect` 一起被放大，但其内部使用 `geo.size` 推导的 `imageRect` 为未缩放值）→ **放大后译文/OCR 框整体偏离原位**。这同时是第 2 节所述"翻译看起来不对"的一个独立来源。

**附带问题（P1）**：放大状态下没有边界约束，`scaleEffect` 后无 `.clipped()`（`ReaderView.swift:3728-3733` 无裁剪），放大的图片会溢出到相邻页面区域并与翻页过渡叠加；`loadImage()` 在每次图片重载时把 `scale`/`offset` 重置（`ReaderView.swift:4586-4588, 4619-4621`），但 `lastScale` 同步重置，行为一致，此处无缺陷。

### 3.2 修复方向（最小改动）

1. 在缩放容器上增补 `DragGesture`，仅在 `scale > 1.05` 时消费：`offset = clamp(baseOffset + translation, within: imageBounds)`；
2. 给外层翻页 `DragGesture` 增加 `guard scale <= 1.05` 门控（`ReaderView.swift:3082`），或改用 `simultaneousGesture` + 缩放态判定；
3. 把 `scale`/`offset` 传入 `ocrDisplayTransform`（`ReaderView.swift:4245`）的 `zoomScale` / `panOffset`，或统一改为"覆盖层不进 `scaleEffect`，只改 `imageRect`"这一条路径（推荐后者：坐标系单一来源，避免视觉变换与布局变换两套算法）；
4. 补 `.clipped()` 抑制溢出。

---

## 4. 视觉化：缺陷分布（配合上图）

见随报告产出的流程图，标注了三个议题各自命中的环节。

---

## 5. 其余维度系统审查

### P0

| # | 问题 | 位置 |
|---|---|---|
| Q1 | **`body` 内每帧重算 O(n²) 布局**：`translationLayoutItems` / `ocrLayoutItems` 由 body 直接调用（`ReaderView.swift:3722-3723`），内部对每块跑 `nonOverlappingRect`（48 候选 × 遍历 occupiedRects → O(n²)，且 `OCRBubbleLayoutEngine.swift:1065` 的 `min` 闭包对每个候选重复计算两次 `layoutScore`）＋ 每块多次 CoreText 测量。翻页与手势期间必掉帧 | `ReaderView.swift:4419-4488, 4516-4550`；`OCRBubbleLayoutEngine.swift:1035-1066` |
| Q2 | **巨型类型 / 单文件职责混杂**：`AITranslator`（2800 行）、`ReaderView` 单 struct（≈1880 行）、`ContentView`（≈2000 行）、`ComicManager`（≈2150 行） | `AITranslator.swift:634`、`ReaderView.swift:679-2557`、`ContentView.swift:220-2246`、`ComicManager.swift:88-2243` |
| Q3 | **放大镜覆盖层吞触摸**（详见 §1.2 E1） | `ReaderView.swift:4079-4097` |
| Q4 | **放大/平移失效 + 覆盖层错位**（详见 §3） | `ReaderView.swift:4686-4701, 3081-3097, 4245-4249` |

### P1

| # | 问题 | 位置 |
|---|---|---|
| Q5 | **明文备份可注入凭据**：导出侧强制"含凭据必须加密"（`SettingsBackupCodec.swift:42-47`），但导入侧 `decodePlain` → `SettingsBackupCodec.decode(data, password: nil)` 走明文分支时**不校验凭据**（`SettingsBackupCodec.swift:113-117`），随后 `applySettingsBackup` 把 `apiKey`/`baseURL` 直接写进 Keychain/Provider（`ContentView.swift:2089, 2110-2130`）→ 恶意构造的备份可把后续整页图片与密钥指向攻击者端点。两侧策略不对称 | `SettingsBackupCodec.swift:42-47 vs 113-117`；`ContentView.swift:2089, 2110-2130` |
| Q6 | **主线程同步 IO + JSON 解码**：`@MainActor` 类型的 `init` 内同步 `Data(contentsOf:)` + `JSONDecoder`，启动路径阻塞主线程（其余存储层均为 actor，合规） | `ReadingActivityStore.swift:102-116, 312-314` |
| Q7 | **HTTP 明文 + 密钥请求头**：允许 `http` 源并用请求头传凭据，但工程未配置任何 ATS 例外 → 生产环境 LAN http 源实际会被 ATS 拦截或需放宽 ATS 后才能用；一旦放宽则密钥明文上网 | `KomgaAPIClient.swift:30, 229-230`；`OPDSProvider.swift:249` |
| Q8 | **任意 URL 拉取（SSRF）**：feed 提供的绝对 URL 直连下载，只防凭据跨域外泄，不拦内网/回环地址 | `OPDSProvider.swift:405-410, 238`；`RemotePageLoader.swift:462-469`；`OPDSAuthorizationPolicy.swift:301-318` |
| Q9 | **调试日志残留泄露内容**：134 处 `print(`，仅 4 处 `#if DEBUG` 包裹；部分打印 OCR 原文与模型响应片段 | `AITranslator.swift:879, 916, 3299-3320`；`RemotePageLoader.swift:140-479`（23 处） |
| Q10 | **错误静默**：256 处 `try?`，写盘/下载失败无任何反馈 | 例：`RemotePageLoader.swift:472, 336` |
| Q11 | **`ReaderImageCache` 非 actor 持有可变共享状态**（`inFlightLoads`/`preloadQueue`），仅靠调用方约定；`BoundedHTTPResponse` 为 `@unchecked Sendable` | `ReaderView.swift:340`；`BoundedHTTPResponse.swift:76` |
| Q12 | **切片去重丢字 / 拆句**（详见 §2.3 ①） | `AITranslator.swift:1373`；`OCRCandidateResolver.swift:57-97, 164-192` |
| Q13 | **vision 链路缺视觉复核与几何 refine**（详见 §2.2） | `AITranslationPageCoordinator.swift:352-371 vs 432-454` |

### P2

| # | 问题 | 位置 |
|---|---|---|
| Q14 | **本地化 key 复用为三种语义**：`ocr.aiTranslation` 同时是 Section 标题、Toggle 标签、导航标题 | `ReaderView.swift:1260, 1296, 5517`；`zh-Hans.lproj/Localizable.strings:102` |
| Q15 | **硬编码中文未本地化**（错误提示/日志） | `AIProviderStore.swift:214-218`；`LocalWebServer.swift:198, 213, 228, 250`；`OPDSProvider.swift:178` |
| Q16 | **状态双写**：`ReaderContainerView` 与 `ReaderView` 各持一份 `@State comic`，靠 `onComicUpdate` 回写；子阅读器以 `let comic` 接收，外部更新易不同步 | `ReaderView.swift:7, 681, 23-74, 1824-1832` |
| Q17 | **调试开关影响生产路径**：`ocrShowDebugBoxes` 会切换翻译实现分支（`ReaderView.swift:4882`）；`translationDebugItems` 重复调用 `translationLayoutGeometry`（`:4391-4401`）再算一遍全部布局 | `ReaderView.swift:689, 3683, 4391-4401, 4882` |
| Q18 | **忙等 / 轮询**（250ms 轮询等） | `ReaderView.swift:1916-1918`；`OfflineTranslationBackgroundScheduler.swift:335-381`；`ICloudMetadataSyncService.swift:535` |
| Q19 | **测试覆盖缺口**：`LocalWebServer`、`KomgaAPIClient`、`RemotePageLoader`、`ReaderImageCache` 在 `mreaderTests` 中 0 命中；翻译侧缺 5 类关键用例（见下） | 见 §6.4 |

### 值得肯定的实现（不作为问题列出）

- API Key 走 Keychain（`AIProviderStore.swift:231-281`、`KomgaProvider.swift:572-620`）；
- 备份加密用 PBKDF2（100k 迭代）+ AES-GCM，且导出侧强制凭据加密、有大小上限（`SettingsBackupCodec.swift:36-176`）；
- 网络响应体有上限（`BoundedHTTPResponse.swift`、`KomgaAPIClient.swift:17-21`）；
- OCR 结果有内存 + 磁盘缓存与 LRU 淘汰（`OCRRecognitionCache.swift:86-208`）；
- OPDS 同源凭据策略（`OPDSAuthorizationPolicy.swift:301`）；
- zip 仅解压到内存且单条目限 120MB、无落盘路径 → 无 zip slip（`ComicManager.swift:204, 1484-1527, 2027`）；
- `LocalWebServer` 有 token 路径校验、文件名净化与目录穿越防护（`LocalWebServer.swift:295-310, 483-488`）；
- 翻译链路对"协议破坏"的判定较严（宁可失败不误记），是上述误杀问题的另一面，方向正确。

---

## 6. 修复建议（按优先级）

### 6.1 立即（P0）

1. **禁用放大镜**：删除 `ocrMagnificationOverlay` 的渲染调用（`ReaderView.swift:3723`），`ocr.autoMagnify` 开关默认 `false` 并从设置面移除（或移入 #if DEBUG 的调试区）。
2. **补平移手势 + 缩放门控**（§3.2 四步）。
3. **统一坐标系**：覆盖层不进 `scaleEffect`，改为把 `scale`/`offset` 传进 `displayTransform`（或反向统一），消除"视觉变换一套、布局变换另一套"。
4. **`body` 内布局计算移出**：对 `translationLayoutItems` / `ocrLayoutItems` 做记忆化，key = （缩放态、页尺寸、`textBlocks` 版本号、样式相关 AppStorage 值），彻底消除每帧 O(n²)。

### 6.2 近期（P1）

5. **vision 链路补齐交叉校验**：解析时校验 `sourceText` 与 `textBox` 的合理性（例如框内文字密度、与相邻块的阅读顺序一致性），并对低置信/冲突结果走一次 `visualVerifyOCRRegions`（复用 OCR 分支已有能力）。
6. **切片聚合改为文本合并**：跨切片同一气泡的重复候选按阅读顺序合并原文再翻译，替换"只保留一个代表"的策略（`OCRCandidateResolver.swift:57-97`）。
7. **语言校验降级为逐项**：不兼容时只让该项走兜底重译，不要静默置空（`AITranslator.swift:2676-2681`）也不要整页抛错（`AIPageTranslation.swift:476-479`）。
8. **Prompt 占位符校验**：`renderVisionPrompt` 发现模板缺 `{targetLanguage}`/`{readingOrder}` 时回退默认模板并提示用户（`AITranslator.swift:2276-2281`）。
9. **导入侧对称校验**：明文备份若"声称不含凭据却实际含 `apiKey`/`baseURL`"应拒绝导入（`SettingsBackupService.swift:13-15` 或 `SettingsBackupCodec.swift:113-117`）。
10. **`ReadingActivityStore` 改 actor 或异步加载**（`ReadingActivityStore.swift:102-116`）。
11. **日志分级**：`print` 统一替换为 `os.Logger` 并分级，OCR 原文/模型响应只在 `#if DEBUG` 输出。
12. **SSRF 防护**：对 feed 绝对 URL 增加私网/回环地址拒绝（`OPDSProvider.swift:405-410`）。
13. **修复 `isRecognizingOCR` 守卫竞态**：改用代际 `UUID` 判定，避免翻页后放大镜静默失效（若 §6.1 已移除该功能则自然消解）。

### 6.3 中期（可维护性）

14. 按职责拆分 `AITranslator`（协议/解析/提示词/校验/几何各一文件）与 `ReaderView`（页面容器、覆盖层渲染、手势、OCR 协调各一文件）。
15. 消除 `ReaderContainerView` / `ReaderView` 的 `comic` 双写，收敛为单一 Source of Truth。
16. 修正 `ocr.aiTranslation` 这类一 key 多用，补齐硬编码中文。
17. 清理 `ocrShowDebugBoxes` 对生产分支的影响，调试层只在 debug 构建编译进去。

### 6.4 需要补齐的测试

**翻译正确性**：
- 模型返回的 `textBox` 与 `sourceText` 不一致时应有明确行为（当前无逻辑、无测试）；
- 跨切片同一气泡 IoU < 0.55 时不应重复渲染、文本不应丢失；
- 中文目标下纯拉丁/象声译文（"OK!"、"SOS"）应放行而非置空；
- 页级语言二次校验不得把正确英文判为其它拉丁语言而整页回退；
- vision 实时分支应与 OCR 分支具备同等的复核契约（当前无该契约测试）。

**其他**：
- `LocalWebServer`（token/目录穿越）、`KomgaAPIClient`（ATS/凭据头）、`RemotePageLoader`（缓存与失败路径）、`ReaderImageCache`（并发与容量）均无测试；
- 备份导入的明文凭据拒绝用例；
- 缩放/平移手势的 UI 测试（`mreaderUITests` 目前无相关用例）。
