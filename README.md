# MReader

[![iOS CI](https://github.com/zyk1172/mreader/actions/workflows/ios-ci.yml/badge.svg)](https://github.com/zyk1172/mreader/actions/workflows/ios-ci.yml)

MReader 是一个面向 iPhone 与 iPad 的开源漫画阅读器，重点解决三件事：**漫画文件由用户自己管理、阅读体验优先、OCR/翻译能力尽量不打断阅读**。

当前项目版本为 **1.1**，最低支持 **iOS / iPadOS 26.0**。

![MReader Hero](docs/images/01-hero.png)

## 核心能力

| 类别 | 当前能力 |
| --- | --- |
| 本地漫画库 | 使用“文件”App 中用户选择的目录作为漫画根目录，保留用户原有目录结构 |
| 格式 | ZIP / CBZ、PDF、图片文件夹、图片型 EPUB |
| 远程漫画库 | Komga、OPDS |
| 离线阅读 | 支持远程漫画离线下载；Komga 按页保存，OPDS 保存远程书籍文件 |
| 阅读模式 | 水平翻页、垂直翻页、连续滚动、无限滚动、双页模式 |
| 阅读进度 | 页码、滚动位置、最近阅读时间、每本漫画独立阅读设置 |
| OCR | Apple Vision、日文竖排 Tesseract OCR、图像预处理、OCR 搜索索引与调试工具 |
| 翻译 | Apple Translation、AI 文本翻译、视觉模型翻译、翻译气泡布局 |
| AI Provider | 自定义 Provider、文本/视觉模型分离，支持 Chat Completions、Responses、Anthropic Messages 协议 |
| 后台能力 | 整本预翻译、离线翻译结果持久化、后台翻译调度 |
| 同步 | 可选 iCloud 元数据与阅读活动同步 |
| 导入 | 文件、文件夹、局域网浏览器上传 |
| 数据保护 | Keychain 保存访问密钥；设置备份支持加密导出 |
| 本地化 | 简体中文、English、日本語、한국어 |

## 设计原则

### 漫画文件属于用户

MReader 不把本地漫画重新收进一个不可见的私有“媒体库”。用户选择“文件”App 中的漫画根目录后，本地扫描、导入、重命名和删除都围绕这个目录工作。

这意味着漫画文件仍然可以直接通过“文件”App、iCloud Drive 或其他文件管理方式备份、移动和整理。App 主要保存阅读进度、索引、缩略图、OCR/翻译缓存和必要设置。

![本地漫画库](docs/images/04-local-library.png)

### 阅读体验优先

普通分页漫画、双页扫描和 Webtoon/长条漫画使用同一套书架与阅读状态模型。每本漫画可以独立保存阅读方向、阅读模式、动画、页面适配方式和最终阅读位置。

MReader 不要求用户为了适配阅读器而重新整理原有漫画目录。

### OCR 与翻译是辅助能力

OCR、Apple Translation 和 AI 翻译都建立在阅读器之外的独立运行层上。翻译结果按原文字位置覆盖显示，并尽量避免气泡之间互相遮挡；视觉识别和网络请求也不会直接耦合进页面导航逻辑。

## 书架与“继续阅读”

书架统一展示本地、Komga 与 OPDS 漫画，并保留系列层级、封面、阅读进度、页数和来源信息。

![书架网格](docs/images/02-bookshelf-ai.png)

主要能力包括：

- 网格与列表两种显示方式。
- 系列文件夹作为二级层级展示章节。
- 按来源、阅读状态、锁定状态等条件筛选。
- 漫画和系列的重命名、删除、分享、缩略图维护等管理操作。
- 批量选择与批量管理。
- 下拉刷新本地与远程漫画库。
- “继续阅读”按最近阅读时间帮助快速回到上次中断的位置。
- 阅读统计与每日阅读目标。

书架针对大漫画库做了分组优化：当前可见漫画只进行一次系列分桶，避免随着系列数量增加反复扫描整个漫画数组。

## 本地库与格式支持

MReader 会保留用户已有的目录结构。根目录中可以同时存在独立漫画文件、图片文件夹和系列目录；系列目录内部也可以继续包含章节文件或章节文件夹。

![多格式识别](docs/images/06-formats.png)

当前主要支持：

- **ZIP / CBZ**：递归识别压缩包中的图片目录，按需读取页面，不需要一次解压整本漫画。
- **PDF**：按页渲染，并在滚动模式中保存实际阅读位置。
- **图片文件夹**：按自然顺序识别常见漫画图片。
- **EPUB**：主要面向图片型漫画 EPUB。

ZIP/CBZ 会过滤 `__MACOSX`、`.DS_Store`、`Thumbs.db` 和隐藏文件，并使用自然排序避免 `10.jpg` 排到 `2.jpg` 前面。

![ZIP 递归扫描](docs/images/07-zip-recursive.png)

目前没有把 **7z、RAR、CBR** 暴露为稳定导入格式。

## Komga 与 OPDS

MReader 当前支持两类远程漫画源：**Komga** 与 **OPDS**。

### Komga

Komga 通过 HTTP API 同步书库、系列、书籍、封面与页面。远程条目会被转换为 MReader 内部统一的 `ComicBook` 模型，UI 不直接依赖 Komga 原始 JSON。

![Komga Provider](docs/images/05-komga-provider.png)

阅读过程中由 `RemotePageLoader` 管理当前页请求、预取、内存缓存与磁盘缓存，避免每次翻页都完整等待网络。

### OPDS

OPDS Provider 可以读取远程目录与出版物，并与本地、Komga 内容一起出现在书架中。支持的远程出版物可以下载到本地，之后通过离线文件继续阅读。

### 远程离线下载

远程漫画支持持久化离线内容：

- Komga：保存完整页集合并校验页面是否齐全。
- OPDS：保存对应出版物文件。
- 离线内容存放在 Application Support，并排除在系统备份之外，避免无意中把大量可重新下载内容同步到云端。

![远程缓存](docs/images/12-remote-cache.png)

## 阅读器

阅读器默认以沉浸式界面打开。工具栏可以按需显示，不长期占用漫画内容区域。

![阅读器](docs/images/03-reader-ai.png)

当前阅读模式包括：

- 水平翻页
- 垂直翻页
- 连续滚动
- 无限滚动
- 双页模式
- 左到右 / 右到左阅读方向
- 多种翻页动画与页面适配方式

![阅读设置](docs/images/08-reading-settings.png)

滚动模式会记录页码和滚动进度，退出阅读器或 App 进入后台时保存最终位置。长条漫画会预留未加载页面高度并限制异常的大跨度滚动，降低网络图片加载导致的 offset 跳动。

![连续滚动进度](docs/images/09-scroll-progress.png)

## OCR、搜索与翻译

MReader 的 OCR 流程并不直接依赖阅读器当前显示的低分辨率缩略图。需要识别时会优先取得原图或 OCR 专用高分辨率图像，并根据页面情况进行切片与预处理。

![OCR 流程](docs/images/10-ocr-pipeline.png)

当前 OCR 相关能力包括：

- Apple Vision 本地文字识别。
- Tesseract 日文竖排识别数据与专用处理流程。
- 灰度、对比度、锐化、降噪、反色与放大等预处理。
- 多候选结果合并与置信度筛选。
- 安全区、小字、网址、水印等噪声过滤。
- OCR 调试框与识别阶段诊断。
- OCR 搜索索引，可在漫画库内检索已经建立索引的文字。

### Apple Translation

支持调用 Apple Translation 作为系统翻译路径，并保留 AI Provider 作为其他翻译或兜底能力。

### AI 翻译

AI 配置已经从单一 OpenAI 兼容接口扩展为 Provider Profile。每个 Provider 可以配置自己的 Base URL、模型列表和访问密钥，并分别指定：

- **文本模型**：处理 OCR 后的文本翻译。
- **视觉模型**：处理整页视觉翻译和低置信度 OCR 的视觉复核。

当前传输层支持：

- OpenAI Chat Completions
- OpenAI Responses
- Anthropic Messages

未知模型仍可手动配置，不强制依赖内置模型名称表。

![翻译气泡](docs/images/11-translation-bubbles.png)

翻译结果会按照 OCR 几何位置生成覆盖层，并通过布局逻辑降低气泡互相覆盖的概率。

### 整本预翻译

MReader 支持把漫画页面加入后台翻译任务并持久化结果，使已经完成翻译的页面可以在之后阅读时直接使用。这里的“离线翻译”主要指**翻译结果可离线使用**；如果所选 AI Provider 本身是网络服务，首次生成翻译仍需要网络连接。

## 导入方式

### 文件与文件夹

导入内容会进入用户选择的漫画根目录，而不是复制到一个用户不可见的私有漫画目录。

### 局域网上传

开启“局域网上传”后，同一局域网中的浏览器可以向设备上传漫画文件。上传过程采用流式写入临时文件的方式，降低大文件上传时的峰值内存占用。

![网页导入](docs/images/13-web-import.png)

## iCloud、设置备份与凭据

MReader 支持可选的 iCloud 元数据同步，用于同步阅读状态和阅读活动等数据。漫画源文件是否进入 iCloud，仍由用户自己的文件存放位置决定。

设置可以导出和恢复。包含 API Key 等凭据的备份必须加密；当前加密备份使用 CryptoKit、PBKDF2-HMAC-SHA256 派生密钥和 AES-GCM 封装。

AI Provider 与远程服务的访问密钥通过 Keychain 保存，不将明文 API Key 直接写入普通设置 JSON。

## 触感反馈

MReader 使用统一的 `HapticManager` 管理触感反馈，并允许用户全局关闭。

![触感反馈](docs/images/14-haptics.png)

触感主要用于按钮、菜单、翻页、边界、成功/失败提示等离散事件；连续滚动不会因为每经过一页就持续触发震动。

## 启动与性能

当前启动流程使用独立的 `StartupRootView`。启动遮罩至少保持 **1.5 秒**，同时底层 `ContentView` 已经开始加载本地书架、远程源状态、iCloud 数据和后台维护任务，因此遮罩不是简单地让 App 空等。

遮罩期间关闭底层首屏动画与交互，避免首次加载时多轮数据更新把 SwiftUI 大标题或书架布局停在中间状态。

其他已经采用的性能策略包括：

- 书架系列单次分桶，避免每个系列重复扫描所有漫画。
- 远程页小窗口预取与分层缓存。
- 缓存统计、离线存储 reconciliation 等文件扫描放到后台任务。
- 漫画库磁盘 JSON 读写由独立 actor 负责。
- OCR 图像预处理和部分重计算任务尽量脱离主线程。

## 架构概览

![架构](docs/images/15-architecture.png)

主要模块职责：

- `ComicManager`：本地 Files 漫画库、扫描、导入、格式解析、缩略图、本地文件操作。
- `ComicLibraryStore`：书架状态、本地与远程漫画合并、阅读状态保持。
- `MediaSourceRepository`：远程媒体源状态的串行化读写与缓存。
- `KomgaProvider` / `OPDSProvider`：远程 Provider 适配。
- `RemotePageLoader` / `OfflineDownloadManager`：远程页面缓存、预取与离线内容。
- `ReaderView`：阅读交互、分页/滚动、工具栏与覆盖层。
- OCR 相关模块：预处理、候选结果、坐标转换、竖排识别、搜索索引。
- `AITranslationClient` / `AIProviderStore`：多协议 AI 请求与 Provider 配置。
- `OfflineTranslationCoordinator`：整本翻译任务与结果持久化。
- `ICloudMetadataSyncService`：可选的元数据和阅读活动同步。

## 编译与运行

### 环境

- Xcode **26.5**
- iOS / iPadOS deployment target **26.0**
- SwiftUI
- 当前 Marketing Version：**1.1**

打开项目：

```bash
open mreader.xcodeproj
```

主要依赖与系统框架：

- ZIPFoundation
- TesseractSwift / tesseract-Apple
- Vision
- Translation
- CryptoKit
- CoreImage / ImageIO
- PDFKit
- UIKit / SwiftUI

命令行构建示例：

```bash
xcodebuild \
  -project mreader.xcodeproj \
  -scheme mreader \
  -destination 'generic/platform=iOS' \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  ONLY_ACTIVE_ARCH=YES \
  build
```

## CI

仓库使用 GitHub Actions 运行 iOS CI：

- `macos-26` runner
- Xcode 26.5
- iPhone 17 / iOS 26.5 Simulator
- `SWIFT_STRICT_CONCURRENCY=complete`
- Unit tests
- UI smoke tests
- 测试结果以 `.xcresult` artifact 保存

CI 会在 Pull Request 和 `main` push 时执行，并使用 concurrency 取消同一 ref 上已经被新提交取代的旧运行。

## 当前限制

- 目前没有把 7z / RAR / CBR 作为稳定导入格式开放。
- 部分 AI 功能需要用户自行配置可访问的 Provider、API Key 和对应模型。
- “离线翻译”并不意味着所有模型都在设备本地推理；如果 Provider 是云端服务，生成阶段仍依赖网络。
- 远程媒体源当前重点支持 Komga 与 OPDS，不等同于 SMB/WebDAV 文件浏览器。

## 许可证

MReader 源代码按 [GNU General Public License version 3](LICENSE)（GPL-3.0）发布。

项目使用的 Apple 系统框架、Swift Package、OCR 模型数据以及其他第三方内容仍受其各自许可证约束。相关第三方 OCR 数据说明见 [`mreader/Resources/tessdata/THIRD_PARTY_NOTICES.md`](mreader/Resources/tessdata/THIRD_PARTY_NOTICES.md)。

---

MReader 的核心原则：**漫画文件属于用户，阅读体验优先，AI 是辅助能力，底层数据与 UI 职责尽量分离。**
