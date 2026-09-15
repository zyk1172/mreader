# 漫画阅读器性能与布局审查

日期：2026-09-15
范围：`mreader/ContentView.swift`、`mreader/ReaderView.swift`、`mreader/GuidedPanelMotionPlanner.swift`、`mreader/GuidedPanelViewport.swift`、`mreader/MangaVisionService.swift`、`mreader/PanelDetectionService.swift`
基线：`main` @ `90b7ef6`

---

## 结论速览

| # | 现象 | 主根因 | 证据 | 优先级 |
|---|------|--------|------|--------|
| 1 | 三个主页面下方大片空白 | 内容短于视口时无填充策略；三页都没有「填满/居中/footer」处理 | `ContentView.swift:944/1221/967` | P1 |
| 2 | 分镜动画非常卡 | `c0d942f` 把相机时长整体翻倍，并把同一行移动也改成「两段串联动画」；衔接段只推进 7.5–11% 却占 31–34% 时长 | `GuidedPanelMotionPlanner.swift:39-116,131-152`；`ReaderView.swift:3457-3501` | P0 |
| 2b | 分镜进入页面时的额外卡顿 | 每页做一次**完全多余的 6144px 全量解码**（结果只用于取宽高 + 喂 640px 模型），且与 4096 缓存不互认，等于解码两遍 | `ReaderView.swift:3359` vs `522-531/5675-5677` | P0 |
| 3 | 长条漫画首开卡死 | 冷启动几何未知 → 占位高度取 `width*1.35`，真实长条约 8–15 倍 → 高度跳变引发整页重排风暴；同时并发 2 个 8192px 巨型解码 | `ReaderView.swift:3219-3224, 2229-2235, 3053-3066` | P0 |
| 3b | 长条漫画清晰度与成本双输 | 8192 是「最长边」上限，长条被压到 655px 宽（低于屏幕 1170px）却仍要产出 8192 高的位图 | `ReaderView.swift:5675-5677, 762-768` | P1 |

以下逐条展开。

---

## 问题 1：三个主页面底部的空白

### 已验证的事实

1. 三个页面的容器都是 `ScrollView`：
   - 继续阅读 `ContentView.swift:944-965`
   - 书架 `ContentView.swift:1221-1265`（`GeometryReader` + `ScrollView` + `LazyVGrid`）
   - 统计 `ContentView.swift:3136-3174`（`GeometryReader` + `ScrollView` + `LazyVGrid`）
   三者都是「内容自然高度 + 顶部对齐」，内容不足一屏时剩余高度只会是背景。
2. 我在 iPhone 模拟器（iOS 26.5，横屏 844×390，注入 41 本漫画）跑了一次 UI 探针，读取真实 frame：
   - 书架网格卡片 `frame=(65, 261, 349, 607)`，窗口高仅 390 → **内容确实延伸到了窗口底边之外**，说明 `ScrollView` 没有多留一条底部空白带，tab bar 安全区没有被重复计算。
   - 继续阅读页两张卡片 `y=90`、`y=258`，卡片高 154 → 一屏只放得下 2 张。
3. `238a7e0` 加的 `.scrollBounceBehavior(.basedOnSize)`（`StartupRootView.swift:19`）只影响**下拉回弹**，不会改变静态的空白区域。所以那条修复没解决你现在看到的现象——它解决的是「可以拖出一屏空白」。

### 真正会造成「大片空白」的三个点

- **继续阅读页天然近似空页**：`continueReadingComics` 只保留 `hasBeenOpened || readingActivity.hasActivity` 的漫画（`ContentView.swift:1194-1203`）。导入新书后这一页几乎是空的，而书架页是满的——这就是最常见的那种「底部一大片空白」。
- **卡片度量按竖屏手机写死，横屏/大窗口下每行过高**：`ShelfCardMetrics.coverHeight = cardWidth / 0.68`，`cardHeight` 再加 94pt（`ContentView.swift:2579-2585`）。手机横屏时 `cardWidth` 约 349 → 单张卡 607pt，比屏幕还高，网格一屏只出现 1 行半。
- **统计页有内容宽度上限**：`ReadingStatisticsLayout.maximumContentWidth` 为 1080/1440（`ContentView.swift:3185`），三列布局下大窗口里卡片会挤在中间，左右与下方都空。

### 建议

1. 给三个 `ScrollView` 的内容加「最小填充高度」，让短页不再露出空白：
   ```swift
   // 继续阅读 / 书架 / 统计 统一
   ScrollView { content.frame(minHeight: proxy.size.height, alignment: .top) }
   ```
   或者在短页时切换为 `ContentUnavailableView` 风格的引导文案（「还没有开始阅读的漫画，去书架挑一本」），比空白更有信息量。
2. 继续阅读页在 `continueReadingComics.isEmpty` 时显式走空状态，而不是渲染一个空 `LazyVStack`。
3. `ShelfCardMetrics` 改成按视口高度反推列数/卡宽，或在横屏下强制 3–4 列，避免单行超过一屏。
4. 需要你确认：你看到空白的设备与方向（iPhone 竖屏？iPad？Mac 上「Designed for iPad」窗口？）。如果是 Mac 大窗口，第 2、3 点是主因；如果只在继续阅读页，就是第 1 点。

---

## 问题 2：分镜动画为什么「非常卡」

### 主因：相机动画被拆成两段，且时长翻倍（`c0d942f`）

改动前 → 改动后：

| kind | 旧 duration | 新 duration | 旧分两段？ | 新分两段？ |
|------|------------|------------|-----------|-----------|
| sameRow | 0.52–0.62 | **1.20–1.32** | 否（单段） | 是（0.34 / 0.66） |
| nearby | 0.58–0.70 | **1.30–1.42** | 否 | 是 |
| nextRow | 0.66–0.78 | **1.40–1.54** | 是 | 是 |
| farJump | 0.76–0.88 | **1.54–1.68** | 是 | 是 |
| pageBoundary | 0.90 | **1.55** | 是 | 是 |
| focusEntry | 0.58 | **0.92** | — | — |

更关键的是衔接段的几何设计（`GuidedPanelMotionPlanner.swift:131-152`）：

```
progress = clamp(0.075 + distance * 0.035, 0.075, 0.11)
```

即第一段（占 31–34% 时长）只朝目标前进 **7.5–11%**，肉眼几乎不动；第二段（占 66–69% 时长）要吃掉剩下 **约 90%** 的距离，且用的是 `.timingCurve(0.20, 0.62, 0.34, 1.0)`（起步就吃掉 62% 进度）。合起来就是「先爬一下 → 再猛冲一下 → 收尾」，主观感受就是顿挫。

`ReaderView.swift:3483-3500` 的实现方式又放大了这个问题：

```swift
withAnimation(.easeOut(duration: profile.bridgeDuration)) { cameraFocusOverride = bridgeRect }
panelMotionTask = Task { @MainActor in
    try? await Task.sleep(for: .seconds(profile.bridgeDuration))   // ← 主线程上的定时机
    withAnimation(cameraAnimation(for: profile, duration: profile.settleDuration)) { ... }
```

- 主线程 `Task.sleep` 到点才启动第二段。主线程一旦忙（图片解码落地、`pageFrames` 重算、Core ML 收尾），唤醒就会晚，画面在半路停住再跳 —— 这正是「卡」的观感。
- 两段动画是两次独立 transaction，中间存在速度/缩放不连续（衔接矩形与目标矩形尺寸不同 → scale 在第二阶段发生跳变）。
- 整个过程 `isPanelTransitioning = true`（`ReaderView.swift:3478/3499`），1.2–1.7s 内所有翻页与点击被 gate 掉（`3433/3445`），体感更「黏」。

**修复建议（按性价比排序）**

1. 回到单段动画：删掉 `sameRow` 的 bridge（`GuidedPanelMotionPlanner.swift:71-81`），把 `usesContextBridge` 收窄到真正的大跳（farJump / pageBoundary）才有意义。
2. 时长砍回 0.45–0.75s 区间；`farJump` 用慢起快收的曲线补「距离感」，而不是靠延长总时长。
3. 若一定要保留两段，把衔接点的 `progress` 提到 **0.45–0.6**，让两段速度连续。
4. 别用 `Task.sleep` 串两段：改成单段动画 + `Animation.timingCurve`，或直接在目标 `CGRect` 上做插值（`AnimatablePair`/`GeometryEffect`），由 SwiftUI 一次算完。

### 次因 A：分镜每页都做一次多余的 6144px 全量解码

`ReaderView.swift:3359`：

```swift
guard let image = await ReaderImageCache.shared.loadImage(for: pageURL, maxPixelSize: 6144)
```

这行拿到的图只用于两件事：取 `sourceSize` 宽高、丢给 `PanelDetectionService`。而后者内部会 `analysisCGImage(maximumDimension: 640)` 再降采样（`PanelDetectionService.swift:476, 612-638`），`detectedContentBounds` 更是只采样到 192 宽（`:641-660`）。**6144px 完全没有被用到**。

同时缓存分层不互认（`ReaderView.swift:522-531`）：

```swift
private let resolutionTiers: [CGFloat] = [4096, 6144, 8192]
func cachedImage(for url: URL, maxPixelSize: CGFloat = 4096) -> UIImage? {
    for tier in resolutionTiers where tier >= maxPixelSize { ... }
}
```

`loadImage(6144)` 只匹配 `>= 6144` 的档位，**找不到 4096 的条目**。而 `LocalImageView` 在分镜模式用 `.fitScreen` → `preferredDecodeMaxPixelSize = 4096`（`:5675-5677`），`preloadPages` 也是 4096（`:2232`）。结论：分镜模式每一页都要先解一遍 4096 显示用图，再解一遍 6144 只用来读宽高的图 —— 双倍 ImageIO 工作量、双倍内存（约 24MB + 55MB）。

**修复**：
- 用 `PageGeometryStore.shared.size(for:)` 或 `ComicManager.imagePixelSizeForArchivePageURL` 取宽高，不要为了取宽高解码整页；
- 检测统一喂 640px 缩略图（`MangaVisionService.loadAnalysisImage` 已经能做到）；
- 顺手把 `resolutionTiers` 的匹配改成「向下就近取档」，让 8192/4096 互相复用。

### 次因 B：分镜相机把大位图交给 SwiftUI 的 `scaleEffect` + `clipped`

`GuidedPanelReader` 把整个 `LocalImageView`（内含 `Image` + 覆盖层 + 自身 `.scaleEffect(scale).offset(offset).clipped()`，`ReaderView.swift:4414-4417`）再套一层 `.scaleEffect(camera.scale).offset(camera.offset)`，最外再 `.clipped()`（`:3322-3323, 3346`），且这段内容位于 `GeometryReader` 内、每次 `panelIndex`/`cameraFocusOverride` 变化都会重建整个 `LocalImageView`（含 ~25 个闭包参数、十几个 `.onChange`、手势构造）。

- 每次状态变更都要重建这个超大 view 的 body。
- 4.8x 放大 + 双层裁切会在合成阶段产生额外离屏。

**修复**：把图片与相机的变换下沉到 UIKit 层（`UIImageView` + `CATransform3D`，用 `CAMediaTimingFunction` 驱动），SwiftUI 只负责发指令。这样相机移动完全不走 SwiftUI 的 body 求值，动画由 render server 负责，是解决「大图 + 相机动画掉帧」最稳的做法。

---

## 问题 3：长条漫画刚打开时卡得要死

### 主因 A：占位高度严重低估，导致高度跳变 → 整页重排风暴

`ReaderView.swift:3219-3224`：

```swift
private func placeholderHeight(for url: URL, viewport: CGSize) -> CGFloat {
    if let size = PageGeometryStore.shared.size(for: url), size.width > 1 {
        return max(viewport.height, viewport.width * size.height / size.width)
    }
    return max(viewport.height, viewport.width * 1.35)   // ← 长条的兜底值
}
```

`PageGeometryStore` 只在**解码完成后**（`:784`）或阅读预设采样时（`:308`）写入。而预设采样只取一个内页（`ReadingPresetSamplePagePolicy.pageIndices` 返回 `[2]`，`:277-285`），**第 0/1 页永远没有几何**。所以冷启动时：

- 真实长条比例常见 8–15 → 真实高度 ≈ `width * 8~15`；
- 占位按 `width * 1.35` → **低估 6–11 倍**。

`LazyVStack` 里第 0 页高度从 1.35 倍跳到 10 倍，后面所有页的位置全部失效 → 重排；随后第 1、2 页陆续落地又重排。这才是「刚打开卡得要死」的主因。

### 主因 B：占位/帧字典写进 `@State`，滚动与重排都会重算整个 reader

`ReaderView.swift:3053-3066`：

```swift
.onPreferenceChange(PageFramePreferenceKey.self) { frames in
    guard pageFrames != frames else { return }
    lastPageFrameCommitDate = now
    pageFrames = frames                     // ← @State
    scheduleVisiblePageUpdate(delay: 0.04)
}
```

`PageFramePreferenceKey` 的值来自每页 `background` 里的 `GeometryReader`（`:3006-3015`），**随滚动位置实时变化**。写进 `@State` 会让 `ContinuousScrollReader` 整体 body 失效（节流到 80ms，即 12 次/秒），每次都要重建可见页的 `LocalImageView`（又是那个超大 body）。滚动时持续掉帧、首开时叠加跳变更明显。

另有 KVO 侧的同源开销：`ScrollViewAccessor` 观察 `UIScrollView.contentOffset`（`:2835`）→ `scheduleVisiblePageUpdate(delay: 0.04)`。

**修复**：把 `pageFrames`/`pageHeights` 换成非观察状态（`final class PageFrameStore` 放进 `@State`，或直接用 `UIScrollView.contentOffset`/`visibleCells` 驱动），让滚动位置变化**不触发任何 SwiftUI body 求值**。`updateCurrentPageFromViewport` 也应直接在 scrollView 回调里算完，只把最终 `currentPageIndex` 回写。

### 主因 C：8192px 巨型解码并发跑

`ReaderView.swift:2229-2235`：

```swift
ReaderImageCache.shared.preload(urls, maxPixelSize: isContinuous ? 8192 : 4096,
                                maximumConcurrent: isContinuous ? 1 : 2,
                                delay: isContinuous ? 0.45 : 0.15)
```

配合 `decodeReaderImage`（`:762-768`）的 `kCGImageSourceShouldCacheImmediately: true` —— 强制同步完成解码。冷启动时「当前页 8192 解码」+「邻页 8192 预解码」同时进行（`ReaderImageDecodeLimiter` 允许 2 个并发，`:443`），对内存带宽的争抢正好落在用户开始滚动的那一刻。

### 主因 D：8192 这个「最长边」口径对长条是错的

`Image(uiImage:).resizable().scaledToFit()` + `.fitWidth` 时，真正需要的是**宽度**对齐屏幕像素宽（iPhone 约 1179–1290px）。但 `kCGImageSourceThumbnailMaxPixelSize` 约束的是最长边：

- 1600×20000 的长条，`maxPixelSize: 8192` → 缩放比 0.4096 → 输出 **655×8192**；
- 显示时按 390pt 宽 × 3 = 1170px 渲染 → **清晰度只有屏幕的 56%**；
- 同时仍然要产出 8192 高的位图，解码缓冲约 21–37MB。

**成本拉满、清晰度打折**，是最不划算的组合。

**修复**：
- 解码尺寸按渲染宽度反推，而不是固定 8192：`maxPixelSize = max(screenWidthPx, ...) / (sourceWidth / sourceLongSide)`；
- 对「超长条」（`height/width > 4`）改成**纵向分片**：按片解码、每片一个视图（项目里已有 `VisionSliceMerger`/`OCRPreprocessor` 的分片先例），单片纹理高度可控，内存与卡顿都能压住；
- 顺手把 `estimatedDecodedCost` 与 `image.cacheCost` 统一（前者算预算用 `maxPixelSize²*0.55`，后者入缓存用 `bytesPerRow*height`，`:705-738`；长条下两者差约 1.8 倍，预取预算判断会失真）。

---

## 建议的落地顺序

| 顺序 | 动作 | 预期收益 | 改动面 |
|------|------|----------|--------|
| 1 | 分镜相机恢复单段动画 + 时长砍回 0.45–0.75s | 直接消除「卡」的主观感受 | `GuidedPanelMotionPlanner.swift` |
| 2 | 分镜去掉 6144 解码，宽高走 `PageGeometryStore` | 每页省一次全量解码 | `ReaderView.swift:3359` |
| 3 | `pageFrames`/`pageHeights` 移出 `@State` | 滚动/重排不再触发 body 求值 | `ReaderView.swift:3053-3066` |
| 4 | 长条占位高度用「先读宽高再布局」，并把兜底比例按 4–6 倍起 | 消除高度跳变风暴 | `ReaderView.swift:3219-3224` |
| 5 | 长条解码尺寸按宽度反推 + 超长条分片 | 首开成本与清晰度同时改善 | `ReaderView.swift:740-787, 5675-5677` |

---

## 修复记录（分支 `fix/reader-jank-and-shelf-blank-space`）

### 已修复

| 项 | 改动 | 文件 |
|----|------|------|
| 分镜动画 | `sameRow` / `nearby` 恢复单段；时长 1.20–1.68s → 0.42–0.78s；`pageBoundary` 1.55s → 0.56s；桥接推进量 7.5–11% → 12–20%；`sameRow`/`nearby`/`focusEntry` 改用标准 `easeOut`（原先曲线在 34% 处就吃完全程，剩余时间是空转） | `GuidedPanelMotionPlanner.swift`、`ReaderView.swift` |
| 重复解码 | 分镜检测不再请求 6144 档，改用与显示层相同的 4096 档常量；`sourceSize` 优先取 `PageGeometryStore`；`PanelDetectionService` 的指纹不再包含解码尺寸，避免换档就失效 | `ReaderView.swift`、`PanelDetectionService.swift` |
| 滚动状态 | `pageHeights`/`pageFrames` 从 `@State` 移到非观察容器 `ReaderScrollPageMetricsStore`，滚动不再触发 reader body 重建 | `ReaderView.swift` |
| 长条首开 | 新增 `PageGeometryStore.preloadSizes`：首屏前用 150ms 预算只读图片头部登记前 12 页真实宽高比（本地源）；占位高度增加「就近页比例」兜底，不再直接落到 1.35 | `ReaderView.swift` |
| 主页空白 | 继续阅读页在无在读漫画时给出显式空状态（可跳转书架）；手机横屏/宽窗口按「卡高不超过容器高 78%」反推列数，避免 2 列做出比屏幕还高的卡片 | `ContentView.swift`、5 个 `Localizable.strings` |

### 已验证

- `.scrollBounceBehavior(.basedOnSize)`（`StartupRootView.swift:19`）**确实生效**：模拟器上拖动继续阅读页，卡片位移 0pt。所以空白与回弹无关，属于「内容不满一屏」。
- 单元测试 396 项通过（含新增的分镜时长契约、网格列数契约）。
- UI 冒烟测试全部通过。

### 未修复（建议单独排期）

1. **长条解码清晰度**：8192 是「最长边」口径，20:1 的长条会被压到约 655px 宽（低于屏幕 1170px）。真正的解法是纵向分片解码，属于独立改动。
2. **预取内存估算口径**：`estimatedDecodedCost`（`maxPixelSize²×0.55`）与入缓存的 `image.cacheCost`（实际像素字节数）不一致，长条下相差约 1.8 倍。需要实机内存数据后再调，避免反向引入内存压力。
3. **继续阅读页的部分填充**：内容确实短于一屏时，剩余区域仍然是背景色。是否要在短页上做填充式布局（居中 / footer）需要先确定目标设备与观感。

| 6 | 三个主页短内容填充/空状态 | 消除底部空白 | `ContentView.swift:944/1221/3136` |

---

## 附：需要你确认的信息

1. 出现底部空白时用的是哪台设备、什么方向？空白是「内容不满一屏」还是「即使内容超出一屏也固定空一条」？
2. 分镜的「卡」是**掉帧**（画面不流畅）还是**节奏顿挫**（先慢后猛、中途停一下）？后者可以直接按第 1 条修掉。
3. 长条漫画首开卡顿发生在本地文件夹、CBZ 还是远程源？三者的解码路径不同，修复优先级也不同。
