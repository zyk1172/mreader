import SwiftUI
import ImageIO
import UIKit
import Combine

struct ReaderContainerView: View {
    @State private var comic: ComicBook
    let onComicUpdate: (ComicBook) -> Void
    @State private var manager = ComicManager()
    @State private var isLoaded = false
    @State private var loadFailed = false

    init(comic: ComicBook, onComicUpdate: @escaping (ComicBook) -> Void) {
        _comic = State(initialValue: comic)
        self.onComicUpdate = onComicUpdate
    }
    
    var body: some View {
        Group {
            if isLoaded {
                ReaderView(manager: manager, comic: comic) { updatedComic in
                    comic = updatedComic
                    onComicUpdate(updatedComic)
                }
            } else if loadFailed {
                ContentUnavailableView("加载失败", systemImage: "exclamationmark.triangle")
            } else {
                ProgressView("正在解析...")
            }
        }
        .onAppear {
            guard !isLoaded && !loadFailed else { return }
            Task {
                let result: ComicManager.LoadResult?
                switch comic.sourceType {
                case .local:
                    let bookmarkData = comic.bookmarkData
                    result = await Task.detached(priority: .userInitiated) {
                        ComicManager.loadPages(bookmarkData: bookmarkData)
                    }.value
                case .komga:
                    result = await RemotePageLoader.loadPages(for: comic)
                }
                if let result {
                    manager.applyLoadedPages(result)
                    isLoaded = true
                } else {
                    loadFailed = true
                }
            }
        }
        .onDisappear { manager.stopAccessing() }
    }
}

enum ReadingMode: String, CaseIterable {
    case horizontalPage
    case verticalPage
    case continuousScroll
    case infiniteScroll
    case doublePage
}

enum ReadingDirection: String, CaseIterable {
    case leftToRight
    case rightToLeft
}

enum PageTurnAnimation: String, CaseIterable {
    case none
    case slide
    case fade
    case curl
}

enum ImageFitMode: String, CaseIterable {
    case fitScreen
    case fitWidth
    case fitHeight
    case original
}

enum ScrollSpeed: String, CaseIterable {
    case slow
    case standard
    case fast

    var screenStepRatio: CGFloat {
        switch self {
        case .slow:
            return 0.45
        case .standard:
            return 0.65
        case .fast:
            return 0.8
        }
    }
}

@MainActor
private final class ReaderImageCache {
    static let shared = ReaderImageCache()

    private let cache = NSCache<NSString, UIImage>()
    private var loadingKeys: Set<String> = []
    private var loadingCosts: [String: Int] = [:]
    private let preloadBudgetBytes = 220 * 1024 * 1024

    private init() {
        cache.countLimit = 0
        cache.totalCostLimit = 260 * 1024 * 1024
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task {
                await ReaderImageCache.clearSharedMemoryCache()
            }
        }
    }

    func cachedImage(for url: URL, maxPixelSize: CGFloat = 4096) -> UIImage? {
        cache.object(forKey: cacheKey(for: url, maxPixelSize: maxPixelSize) as NSString)
    }

    func loadImage(for url: URL, maxPixelSize: CGFloat = 4096) async -> UIImage? {
        let key = cacheKey(for: url, maxPixelSize: maxPixelSize)
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }
        let image = await Task.detached(priority: .userInitiated) {
            await decodeReaderImage(from: url, maxPixelSize: maxPixelSize)
        }.value
        if let image {
            cache.setObject(image, forKey: key as NSString, cost: image.cacheCost)
        }
        return image
    }

    func preload(_ urls: [URL], maxPixelSize: CGFloat = 4096) {
        var estimatedBytes = loadingCosts.values.reduce(0, +)
        guard estimatedBytes < preloadBudgetBytes else { return }
        let candidates = urls
            .map { url in
                (url, cacheKey(for: url, maxPixelSize: maxPixelSize), estimatedDecodedCost(for: url, maxPixelSize: maxPixelSize))
            }
            .filter { cachedImage(for: $0.0, maxPixelSize: maxPixelSize) == nil && !loadingKeys.contains($0.1) }
            .filter { _, _, size in
                let shouldStart = estimatedBytes == 0 || estimatedBytes + size <= preloadBudgetBytes
                if shouldStart {
                    estimatedBytes += size
                }
                return shouldStart
            }

        guard !candidates.isEmpty else { return }
        print("MReader decoded image preload budget=\(preloadBudgetBytes) selectedBytes=\(estimatedBytes) selected=\(candidates.count)")

        for (url, key, cost) in candidates {
            loadingKeys.insert(key)
            loadingCosts[key] = cost
            Task { @MainActor in
                let image = await Task.detached(priority: .utility) {
                    await decodeReaderImage(from: url, maxPixelSize: maxPixelSize)
                }.value
                loadingKeys.remove(key)
                loadingCosts[key] = nil
                if let image {
                    cache.setObject(image, forKey: key as NSString, cost: image.cacheCost)
                }
            }
        }
    }

    func clearMemoryCache() {
        cache.removeAllObjects()
        loadingKeys.removeAll()
        loadingCosts.removeAll()
        print("MReader decoded image cache memory cleared")
    }

    private static func clearSharedMemoryCache() {
        shared.clearMemoryCache()
    }

    private func cacheKey(for url: URL, maxPixelSize: CGFloat) -> String {
        if ComicManager.isArchivePageURL(url) {
            return "\(url.absoluteString)#px=\(Int(maxPixelSize))"
        }
        if RemotePageLoader.isRemotePageURL(url) {
            return "\(url.absoluteString)#px=\(Int(maxPixelSize))"
        }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = values?.fileSize ?? 0
        return "\(url.path)#\(size)#\(mtime)#px=\(Int(maxPixelSize))"
    }

    private func estimatedDecodedCost(for url: URL, maxPixelSize: CGFloat) -> Int {
        if RemotePageLoader.isRemotePageURL(url) {
            return Int(maxPixelSize * maxPixelSize * 0.55)
        }
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
           let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
           width > 0,
           height > 0 {
            let scale = min(1, maxPixelSize / max(width, height))
            return Int(width * scale * height * scale * 4)
        }
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return max(fileSize * 6, 12 * 1024 * 1024)
    }
}

private extension UIImage {
    var cacheCost: Int {
        guard let cgImage else { return 1 }
        return cgImage.bytesPerRow * cgImage.height
    }
}

nonisolated private func decodeReaderImage(from url: URL, maxPixelSize: CGFloat) async -> UIImage? {
    let remoteData: Data?
    if RemotePageLoader.isRemotePageURL(url) {
        remoteData = await RemotePageLoader.imageData(forRemotePageURL: url)
    } else {
        remoteData = nil
    }
    return autoreleasepool { () -> UIImage? in
        let source: CGImageSource?
        if ComicManager.isArchivePageURL(url), let data = ComicManager.imageData(forArchivePageURL: url) {
            source = CGImageSourceCreateWithData(data as CFData, nil)
        } else if let remoteData {
            source = CGImageSourceCreateWithData(remoteData as CFData, nil)
        } else {
            source = CGImageSourceCreateWithURL(url as CFURL, nil)
        }
        guard let source else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldCache: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return UIImage(cgImage: cgImage)
        }
        return UIImage(contentsOfFile: url.path)
    }
}

struct ReaderView: View {
    var manager: ComicManager
    @State private var comic: ComicBook
    let onComicUpdate: (ComicBook) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    
    @AppStorage("translation_target_language") private var translationTargetLanguage = "中文"
    @AppStorage("ocr_show_debug_boxes") private var ocrShowDebugBoxes = false
    @AppStorage("ocr_use_vision_model") private var ocrUseVisionModel = false
    @AppStorage("ai_translation_border_progress_enabled") private var aiTranslationBorderProgressEnabled = true
    @State private var currentPageIndex: Int
    @State private var showControls: Bool = false
    @State private var showComicSettings = false
    @State private var hasOpened = false
    @State private var translateRequestID = UUID()
    @State private var ocrMagnifyRequestID = UUID()
    @State private var isOCRMagnificationVisible = false
    @State private var pageTurnDirection = 1
    @State private var autoHideControlsWorkItem: DispatchWorkItem?
    @State private var didRestoreScrollPosition = false
    @State private var jumpPageText = ""
    @State private var scrollJumpRequestID = UUID()
    @State private var didRecordReaderOpen = false
    @State private var lastSavedScrollProgress: Double
    @State private var lastSavedScrollPageProgress: Double
    @State private var lastProgressPersistDate = Date.distantPast
    @State private var lastPrefetchPageIndex: Int
    @State private var isAITranslationInProgress = false

    private var readingMode: ReadingMode {
        ReadingMode(rawValue: comic.readingModeRaw) ?? .horizontalPage
    }

    private var readingDirection: ReadingDirection {
        ReadingDirection(rawValue: comic.readingDirectionRaw) ?? .leftToRight
    }

    private var pageTurnAnimation: PageTurnAnimation {
        PageTurnAnimation(rawValue: comic.pageTurnAnimationRaw) ?? .slide
    }

    private var imageFitMode: ImageFitMode {
        ImageFitMode(rawValue: comic.imageFitModeRaw) ?? .fitScreen
    }

    private var scrollSpeed: ScrollSpeed {
        ScrollSpeed(rawValue: comic.scrollSpeedRaw) ?? .standard
    }

    private var isOCRMagnificationActive: Bool {
        comic.isOCREnabled && (isOCRMagnificationVisible || comic.isAutoOCRMagnificationEnabled)
    }

    private var readingModeRaw: Binding<String> {
        Binding(
            get: { comic.readingModeRaw },
            set: { newValue in updateComic { $0.readingModeRaw = newValue } }
        )
    }

    private var readingDirectionRaw: Binding<String> {
        Binding(
            get: { comic.readingDirectionRaw },
            set: { newValue in updateComic { $0.readingDirectionRaw = newValue } }
        )
    }

    private var scrollSpeedRaw: Binding<String> {
        Binding(
            get: { comic.scrollSpeedRaw },
            set: { newValue in updateComic { $0.scrollSpeedRaw = newValue } }
        )
    }

    private var pageTurnAnimationRaw: Binding<String> {
        Binding(
            get: { comic.pageTurnAnimationRaw },
            set: { newValue in updateComic { $0.pageTurnAnimationRaw = newValue } }
        )
    }

    private var imageFitModeRaw: Binding<String> {
        Binding(
            get: { comic.imageFitModeRaw },
            set: { newValue in updateComic { $0.imageFitModeRaw = newValue } }
        )
    }

    init(manager: ComicManager, comic: ComicBook, onComicUpdate: @escaping (ComicBook) -> Void) {
        self.manager = manager
        self.onComicUpdate = onComicUpdate
        _comic = State(initialValue: comic)
        let maxIndex = max(0, manager.pages.count - 1)
        _currentPageIndex = State(initialValue: min(max(comic.currentPageIndex, 0), maxIndex))
        _lastSavedScrollProgress = State(initialValue: comic.scrollProgress)
        _lastSavedScrollPageProgress = State(initialValue: comic.scrollPageProgress)
        _lastPrefetchPageIndex = State(initialValue: min(max(comic.currentPageIndex, 0), maxIndex))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if manager.pages.isEmpty {
                ContentUnavailableView("没有找到图片", systemImage: "photo.on.rectangle.angled", description: Text("请重新导入包含 JPG、PNG 或 WebP 图片的漫画文件夹。"))
                    .foregroundStyle(.white)
            } else if readingMode == .horizontalPage || readingMode == .verticalPage {
                AnimatedPageReader(
                    pages: manager.pages,
                    currentPageIndex: $currentPageIndex,
                    pageTurnDirection: $pageTurnDirection,
                    readingDirection: readingDirection,
                    readingMode: readingMode,
                    pageTurnAnimation: pageTurnAnimation,
                    imageFitMode: imageFitMode,
                    comic: comic,
                    translateRequestID: translateRequestID,
                    ocrMagnifyRequestID: ocrMagnifyRequestID,
                    isOCRMagnificationVisible: isOCRMagnificationActive,
                    targetLanguage: translationTargetLanguage,
                    onTranslationStateChange: updateAITranslationProgress,
                    onToggleControls: toggleControls
                )
                .environment(\.layoutDirection, readingDirection == .rightToLeft ? .rightToLeft : .leftToRight)
                .ignoresSafeArea()
            } else if readingMode == .doublePage {
                DoublePageReader(
                    pages: manager.pages,
                    currentPageIndex: $currentPageIndex,
                    pageTurnDirection: $pageTurnDirection,
                    readingDirection: readingDirection,
                    pageTurnAnimation: pageTurnAnimation,
                    imageFitMode: imageFitMode,
                    comic: comic,
                    translateRequestID: translateRequestID,
                    ocrMagnifyRequestID: ocrMagnifyRequestID,
                    isOCRMagnificationVisible: isOCRMagnificationActive,
                    targetLanguage: translationTargetLanguage,
                    onTranslationStateChange: updateAITranslationProgress,
                    onToggleControls: toggleControls
                )
                .environment(\.layoutDirection, readingDirection == .rightToLeft ? .rightToLeft : .leftToRight)
                .ignoresSafeArea()
            } else {
                ContinuousScrollReader(
                    pages: manager.pages,
                    currentPageIndex: $currentPageIndex,
                    readingMode: readingMode,
                    scrollSpeed: scrollSpeed,
                    comic: comic,
                    translateRequestID: translateRequestID,
                    ocrMagnifyRequestID: ocrMagnifyRequestID,
                    isOCRMagnificationVisible: isOCRMagnificationActive,
                    targetLanguage: translationTargetLanguage,
                    scrollJumpRequestID: scrollJumpRequestID,
                    scrollProgress: comic.scrollProgress,
                    scrollPageProgress: comic.scrollPageProgress,
                    onScrollPositionChange: saveScrollPosition,
                    onTranslationStateChange: updateAITranslationProgress,
                    onToggleControls: toggleControls
                )
                .ignoresSafeArea()
            }

            if isAITranslationInProgress && aiTranslationBorderProgressEnabled {
                AppleIntelligenceGlowBorder(
                    cornerRadius: 36,
                    lineWidth: 18,
                    blurRadius: 0,
                    animationDuration: 2.0,
                    colors: ColorfulTranslatedText.palette
                )
                .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            TwoFingerSwipeDownDismissView {
                dismiss()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .background(ScrollsToTopDisabledView())

            if showControls && comic.isOCREnabled {
                VStack {
                    Spacer()
                    HStack(spacing: 10) {
                        Spacer()
                        Button {
                            HapticManager.shared.play(.light)
                            isOCRMagnificationVisible.toggle()
                            if isOCRMagnificationVisible {
                                ocrMagnifyRequestID = UUID()
                            }
                            scheduleAutoHideControls()
                        } label: {
                            Image(systemName: isOCRMagnificationActive ? "text.magnifyingglass" : "text.viewfinder")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                                .overlay(
                                    Circle()
                                        .stroke(.white.opacity(0.22), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("OCR文字放大")

                        if comic.isAITranslationEnabled {
                        Button {
                            HapticManager.shared.play(.light)
                            translateRequestID = UUID()
                            scheduleAutoHideControls()
                        } label: {
                            Text("AI")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                                .overlay(
                                    Circle()
                                        .stroke(.white.opacity(0.22), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("AI翻译")
                        }
                    }
                    .padding(.trailing, 18)
                    .padding(.bottom, 18)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .bottomTrailing)))
            }
        }
        .scaleEffect(max(0.72, 1 - max(0, 0) / 900))
        .rotation3DEffect(.degrees(hasOpened ? 0 : -9), axis: (x: 0, y: 1, z: 0), perspective: 0.65)
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: hasOpened)
        .offset(y: max(0, 0))
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle("")
        .navigationBarBackButtonHidden(true) // 核心：拦截原生左侧边缘的滑动返回手势
        .defersSystemGestures(on: .horizontal) // 将水平滑动优先级完全交给翻页
        .toolbar(showControls ? .visible : .hidden, for: .navigationBar)
        .toolbarBackground(showControls ? .visible : .hidden, for: .navigationBar)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            if showControls {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        HapticManager.shared.play(.light)
                        autoHideControlsWorkItem?.cancel()
                        dismiss()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.backward")
                                .font(.system(size: 17, weight: .semibold))
                            Text("返回")
                        }
                        .foregroundColor(.white)
                        .frame(height: 40)
                    }
                }

                ToolbarItem(placement: .principal) {
                    Text(manager.pages.isEmpty ? "" : "\(currentPageIndex + 1) / \(manager.pages.count)")
                        .font(.system(.headline, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .frame(minWidth: 72)
                }

                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        HapticManager.shared.play(.light)
                        autoHideControlsWorkItem?.cancel()
                        showComicSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 40, height: 36)
                            .foregroundColor(.white)
                    }
                }
            }
        }
        .sheet(isPresented: $showComicSettings) {
            comicSettingsSheet
        }
        .onAppear {
            hasOpened = true
            recordReaderOpenIfNeeded()
            preloadPages(around: currentPageIndex)
        }
        .onDisappear {
            autoHideControlsWorkItem?.cancel()
            RemotePagePrefetcher.shared.cancelAll()
            persistReadingProgress(pageIndex: currentPageIndex, reason: "readerDisappear", force: true)
        }
        .statusBar(hidden: !showControls)
        .onChange(of: currentPageIndex) { oldValue, newValue in
            let clampedValue = min(max(newValue, 0), max(0, manager.pages.count - 1))
            if clampedValue != newValue {
                currentPageIndex = clampedValue
                return
            }
            if newValue != oldValue {
                pageTurnDirection = newValue > oldValue ? 1 : -1
            }
            persistReadingProgress(pageIndex: clampedValue, reason: "currentPageIndexChanged", force: true)
            preloadPages(around: clampedValue)
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .background || newPhase == .inactive else { return }
            persistReadingProgress(pageIndex: currentPageIndex, reason: "scenePhase-\(newPhase)", force: true)
        }
    }

    private var bottomControlBar: some View {
        VStack(spacing: 14) {
            HStack(spacing: 18) {
                Button(action: previousPage) {
                    Image(systemName: readingDirection == .rightToLeft ? "chevron.right" : "chevron.left")
                        .frame(width: 36, height: 36)
                }
                .disabled(currentPageIndex <= 0)

                Spacer()

                Text("\(currentPageIndex + 1) / \(manager.pages.count)")
                    .font(.system(.headline, design: .rounded))
                    .monospacedDigit()

                Spacer()

                Button(action: nextPage) {
                    Image(systemName: readingDirection == .rightToLeft ? "chevron.left" : "chevron.right")
                        .frame(width: 36, height: 36)
                }
                .disabled(currentPageIndex >= max(0, manager.pages.count - 1))
            }

            let sliderBinding = Binding<Double>(get: { Double(currentPageIndex) }, set: { currentPageIndex = Int($0) })
            Slider(value: sliderBinding, in: 0...Double(max(0, manager.pages.count - 1)), step: 1.0).tint(.white)
                .environment(\.layoutDirection, readingDirection == .rightToLeft ? .rightToLeft : .leftToRight)

            HStack {
                Picker("阅读模式", selection: readingModeRaw) {
                    Label("翻页", systemImage: "book").tag(ReadingMode.horizontalPage.rawValue)
                    Label("滚动", systemImage: "scroll").tag(ReadingMode.continuousScroll.rawValue)
                }
                .pickerStyle(.segmented)

                Picker("阅读方向", selection: readingDirectionRaw) {
                    Image(systemName: "arrow.left").tag(ReadingDirection.rightToLeft.rawValue)
                    Image(systemName: "arrow.right").tag(ReadingDirection.leftToRight.rawValue)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .background(.ultraThinMaterial).environment(\.colorScheme, .dark)
    }

    private var comicSettingsSheet: some View {
        NavigationStack {
            Form {
                Section(header: Text("本漫画翻译")) {
                    Toggle("OCR 文字识别", isOn: Binding(
                        get: { comic.isOCREnabled },
                        set: { newValue in updateComic { $0.isOCREnabled = newValue } }
                    ))

                    Toggle("自动文字放大", isOn: Binding(
                        get: { comic.isAutoOCRMagnificationEnabled },
                        set: { newValue in updateComic { $0.isAutoOCRMagnificationEnabled = newValue } }
                    ))
                    .disabled(!comic.isOCREnabled)

                    HStack {
                        Text("放大文字大小")
                        Slider(value: Binding(
                            get: { normalizedOCRTextScale(comic.ocrTextScale) },
                            set: { newValue in updateComic { $0.ocrTextScale = newValue } }
                        ), in: 0...1, step: 0.02)
                        Text(ocrTextSizeLabel)
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                    .disabled(!comic.isOCREnabled)

                    HStack {
                        Text("忽略边缘区域")
                        Slider(value: Binding(
                            get: { comic.ocrSafeAreaInset },
                            set: { newValue in updateComic { $0.ocrSafeAreaInset = newValue } }
                        ), in: 0...0.2, step: 0.01)
                        Text("\(Int(comic.ocrSafeAreaInset * 100))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .disabled(!comic.isOCREnabled)

                    Toggle("AI 翻译", isOn: Binding(
                        get: { comic.isAITranslationEnabled },
                        set: { newValue in updateComic { $0.isAITranslationEnabled = newValue } }
                    ))

                    Toggle("自动翻译当前页", isOn: Binding(
                        get: { comic.isAutoTranslationEnabled },
                        set: { newValue in updateComic { $0.isAutoTranslationEnabled = newValue } }
                    ))
                    .disabled(!comic.isOCREnabled || !comic.isAITranslationEnabled)

                    Toggle("AI 翻译边框进度", isOn: $aiTranslationBorderProgressEnabled)
                        .disabled(!comic.isAITranslationEnabled)

                    Picker("翻译为", selection: $translationTargetLanguage) {
                        Text("中文").tag("中文")
                        Text("英文").tag("英文")
                        Text("日文").tag("日文")
                        Text("韩文").tag("韩文")
                        Text("简体中文").tag("简体中文")
                        Text("繁体中文").tag("繁体中文")
                    }
                }

                Section(header: Text("OCR 过滤"), footer: Text("网页地址、广告标注、页边极小字会被忽略，不送去 OCR 放大或 AI 翻译。")) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("不处理小字大小")
                            Slider(value: Binding(
                                get: { comic.ocrMinimumTextHeight },
                                set: { newValue in updateComic { $0.ocrMinimumTextHeight = newValue } }
                            ), in: 0.006...0.035, step: 0.001)
                        }

                        HStack(alignment: .center, spacing: 12) {
                            Text("示例文字")
                                .font(.system(size: ocrMinimumPreviewFontSize, weight: .semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Color.secondary.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                            VStack(alignment: .leading, spacing: 2) {
                                Text("当前阈值 \(Int(comic.ocrMinimumTextHeight * 1000))")
                                    .font(.caption.monospacedDigit())
                                Text("比示例更小的字不处理")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(!comic.isOCREnabled)
                }

                Section(header: Text("OCR 调试"), footer: Text("视觉模型会把当前裁剪区域或切片发送到第三方 OpenAI 兼容接口。默认仍使用本地 Apple Vision OCR。")) {
                    Toggle("显示 OCR 调试框", isOn: $ocrShowDebugBoxes)
                        .disabled(!comic.isOCREnabled)
                    Toggle("视觉模型识别/翻译", isOn: $ocrUseVisionModel)
                        .disabled(!comic.isOCREnabled)
                    if ocrUseVisionModel {
                        Text("当前版本不会默认上传整页图片。后续接入视觉模型时，应优先上传气泡裁剪区域或页面切片。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section(header: Text("跳转")) {
                    HStack {
                        TextField("页码", text: $jumpPageText)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                        Button("跳转") {
                            jumpToPage()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Text("当前 \(currentPageIndex + 1) / \(manager.pages.count)")
                        .foregroundStyle(.secondary)
                }

                Section(header: Text("阅读")) {
                    Picker("阅读模式", selection: readingModeRaw) {
                        Label("水平翻页", systemImage: "book").tag(ReadingMode.horizontalPage.rawValue)
                        Label("垂直翻页", systemImage: "arrow.up.and.down").tag(ReadingMode.verticalPage.rawValue)
                        Label("连续滚动", systemImage: "scroll").tag(ReadingMode.continuousScroll.rawValue)
                        Label("无限滚动", systemImage: "infinity").tag(ReadingMode.infiniteScroll.rawValue)
                        Label("双页模式", systemImage: "book.pages").tag(ReadingMode.doublePage.rawValue)
                    }

                    Picker("阅读方向", selection: readingDirectionRaw) {
                        Label("从左到右", systemImage: "arrow.right").tag(ReadingDirection.leftToRight.rawValue)
                        Label("从右到左", systemImage: "arrow.left").tag(ReadingDirection.rightToLeft.rawValue)
                    }

                    Picker("翻页动画", selection: pageTurnAnimationRaw) {
                        Label("无动画", systemImage: "circle.slash").tag(PageTurnAnimation.none.rawValue)
                        Label("滑动", systemImage: "rectangle.portrait.on.rectangle.portrait").tag(PageTurnAnimation.slide.rawValue)
                        Label("淡入淡出", systemImage: "square.stack.3d.up").tag(PageTurnAnimation.fade.rawValue)
                        Label("卷曲", systemImage: "book.pages").tag(PageTurnAnimation.curl.rawValue)
                    }

                    Picker("图片适配", selection: imageFitModeRaw) {
                        Label("适应屏幕", systemImage: "rectangle.inset.filled").tag(ImageFitMode.fitScreen.rawValue)
                        Label("适应宽度", systemImage: "arrow.left.and.right").tag(ImageFitMode.fitWidth.rawValue)
                        Label("适应高度", systemImage: "arrow.up.and.down").tag(ImageFitMode.fitHeight.rawValue)
                        Label("原始尺寸", systemImage: "1.magnifyingglass").tag(ImageFitMode.original.rawValue)
                    }

                    Picker("滚动速度", selection: scrollSpeedRaw) {
                        Label("慢", systemImage: "tortoise").tag(ScrollSpeed.slow.rawValue)
                        Label("标准", systemImage: "circle").tag(ScrollSpeed.standard.rawValue)
                        Label("快", systemImage: "hare").tag(ScrollSpeed.fast.rawValue)
                    }
                }
            }
            .navigationTitle(comic.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("完成") { showComicSettings = false }
            }
        }
    }

    private func updateComic(_ mutate: (inout ComicBook) -> Void) {
        HapticManager.shared.play(.light)
        mutate(&comic)
        if !comic.isOCREnabled {
            comic.isAutoOCRMagnificationEnabled = false
            isOCRMagnificationVisible = false
        }
        if !comic.isOCREnabled || !comic.isAITranslationEnabled {
            comic.isAutoTranslationEnabled = false
        }
        onComicUpdate(comic)
    }

    private var ocrMinimumPreviewFontSize: CGFloat {
        min(max(CGFloat(comic.ocrMinimumTextHeight) * 900, 8), 32)
    }

    private var ocrTextSizeLabel: String {
        switch normalizedOCRTextScale(comic.ocrTextScale) {
        case ..<0.2:
            return "小"
        case ..<0.55:
            return "标准"
        case ..<0.82:
            return "大"
        default:
            return "特大"
        }
    }

    private func normalizedOCRTextScale(_ rawValue: Double) -> Double {
        if rawValue > 1 {
            return min(max((rawValue - 0.8) / 2.4, 0), 1)
        }
        return min(max(rawValue, 0), 1)
    }

    private func jumpToPage() {
        let pageNumber = Int(jumpPageText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        guard pageNumber > 0 else {
            HapticManager.shared.play(.warning)
            return
        }
        let targetIndex = min(max(pageNumber - 1, 0), max(0, manager.pages.count - 1))
        HapticManager.shared.play(.medium)
        currentPageIndex = targetIndex
        lastSavedScrollProgress = 0
        lastSavedScrollPageProgress = 0
        persistReadingProgress(pageIndex: targetIndex, scrollProgress: 0, scrollPageProgress: 0, reason: "jumpToPage", force: true)
        scrollJumpRequestID = UUID()
        jumpPageText = ""
        showComicSettings = false
    }

    private func recordReaderOpenIfNeeded() {
        guard !didRecordReaderOpen else { return }
        didRecordReaderOpen = true
        let clampedValue = min(max(currentPageIndex, 0), max(0, manager.pages.count - 1))
        print("MReader progress open comic=\(comic.id) restoredPage=\(clampedValue) storedPage=\(comic.currentPageIndex) mode=\(comic.readingModeRaw)")
        persistReadingProgress(pageIndex: clampedValue, reason: "readerOpen", force: true)
    }

    private func saveScrollPosition(pageIndex: Int, progress: Double, pageProgress: Double) {
        persistReadingProgress(pageIndex: pageIndex, scrollProgress: progress, scrollPageProgress: pageProgress, reason: "scrollVisiblePage", force: false)
    }

    private func updateAITranslationProgress(_ isInProgress: Bool) {
        guard isAITranslationInProgress != isInProgress else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            isAITranslationInProgress = isInProgress
        }
    }

    private func persistReadingProgress(pageIndex: Int, scrollProgress: Double? = nil, scrollPageProgress: Double? = nil, reason: String, force: Bool) {
        let clampedPageIndex = min(max(pageIndex, 0), max(0, manager.pages.count - 1))
        let clampedProgress = min(max(scrollProgress ?? comic.scrollProgress, 0), 1)
        let clampedPageProgress = min(max(scrollPageProgress ?? comic.scrollPageProgress, 0), 1)
        let now = Date()
        if !force {
            guard now.timeIntervalSince(lastProgressPersistDate) >= 0.7 else { return }
        }
        guard force ||
                clampedPageIndex != comic.currentPageIndex ||
                abs(clampedProgress - lastSavedScrollProgress) > 0.003 ||
                abs(clampedPageProgress - lastSavedScrollPageProgress) > 0.01 else { return }

        lastProgressPersistDate = now
        currentPageIndex = clampedPageIndex
        lastSavedScrollProgress = clampedProgress
        lastSavedScrollPageProgress = clampedPageProgress
        comic.currentPageIndex = clampedPageIndex
        comic.scrollProgress = clampedProgress
        comic.scrollPageProgress = clampedPageProgress
        comic.lastReadAt = Date()
        print("MReader progress persist reason=\(reason) comic=\(comic.id) page=\(clampedPageIndex) global=\(String(format: "%.4f", clampedProgress)) pageProgress=\(String(format: "%.4f", clampedPageProgress))")
        onComicUpdate(comic)
    }

    private func preloadPages(around index: Int) {
        guard !manager.pages.isEmpty else { return }
        if comic.sourceType == .komga {
            let scrollDirection = index >= lastPrefetchPageIndex ? 1 : -1
            lastPrefetchPageIndex = index
            RemotePagePrefetcher.shared.updateWindow(
                currentPageIndex: index,
                pages: manager.pages,
                readingDirection: readingDirection,
                readingMode: readingMode,
                scrollDirection: scrollDirection
            )
            return
        }
        let preferredIndices = [index, index + 1, index + 2, index + 3, index - 1, index - 2]
        let urls = preferredIndices.compactMap { pageIndex -> URL? in
            guard manager.pages.indices.contains(pageIndex) else { return nil }
            return manager.pages[pageIndex].url
        }
        ReaderImageCache.shared.preload(urls, maxPixelSize: readingMode == .continuousScroll || readingMode == .infiniteScroll ? 8192 : 4096)
    }

    private func previousPage() {
        guard currentPageIndex > 0 else {
            HapticManager.shared.play(.warning)
            return
        }
        HapticManager.shared.play(.light)
        pageTurnDirection = -1
        currentPageIndex = max(0, currentPageIndex - 1)
    }

    private func nextPage() {
        guard currentPageIndex < max(0, manager.pages.count - 1) else {
            HapticManager.shared.play(.warning)
            return
        }
        HapticManager.shared.play(.light)
        pageTurnDirection = 1
        currentPageIndex = min(max(0, manager.pages.count - 1), currentPageIndex + 1)
    }
    
    private func toggleControls() {
        HapticManager.shared.play(.light)
        if showControls {
            hideControls()
        } else {
            withAnimation(.easeInOut(duration: 0.18)) {
                showControls = true
            }
            scheduleAutoHideControls()
        }
    }

    private func scheduleAutoHideControls() {
        autoHideControlsWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            hideControls()
        }
        autoHideControlsWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2, execute: workItem)
    }

    private func hideControls() {
        autoHideControlsWorkItem?.cancel()
        autoHideControlsWorkItem = nil
        withAnimation(.easeInOut(duration: 0.18)) {
            showControls = false
        }
    }

}

// MARK: - 支持 AI 的图片加载器
private struct PageFramePreferenceKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]

    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newValue in newValue })
    }
}

private struct ScrollViewportSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

private struct ScrollViewAccessor: UIViewRepresentable {
    let onResolve: (UIScrollView) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        DispatchQueue.main.async {
            if let scrollView = view.enclosingScrollView {
                context.coordinator.attach(to: scrollView)
                onResolve(scrollView)
            }
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            if let scrollView = uiView.enclosingScrollView {
                context.coordinator.attach(to: scrollView)
                onResolve(scrollView)
            }
        }
    }

    final class Coordinator {
        weak var scrollView: UIScrollView?

        func attach(to scrollView: UIScrollView) {
            scrollView.scrollsToTop = false
            guard self.scrollView !== scrollView else { return }
            self.scrollView = scrollView
        }
    }
}

private struct ScrollsToTopDisabledView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        DispatchQueue.main.async {
            context.coordinator.disableScrollsToTop(from: view.window)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.disableScrollsToTop(from: uiView.window)
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.restore()
    }

    final class Coordinator {
        private var originalStates: [ObjectIdentifier: (scrollView: WeakScrollView, scrollsToTop: Bool)] = [:]

        func disableScrollsToTop(from window: UIWindow?) {
            guard let window else { return }
            let scrollViews = window.allScrollViews
            let liveIDs = Set(scrollViews.map(ObjectIdentifier.init))
            originalStates = originalStates.filter { id, state in
                guard let scrollView = state.scrollView.value else { return false }
                return liveIDs.contains(id) && scrollView.window === window
            }
            for scrollView in scrollViews {
                let id = ObjectIdentifier(scrollView)
                if originalStates[id] == nil {
                    originalStates[id] = (WeakScrollView(scrollView), scrollView.scrollsToTop)
                }
                scrollView.scrollsToTop = false
            }
        }

        func restore() {
            for (_, state) in originalStates {
                state.scrollView.value?.scrollsToTop = state.scrollsToTop
            }
            originalStates.removeAll()
        }
    }

    final class WeakScrollView {
        weak var value: UIScrollView?

        init(_ value: UIScrollView) {
            self.value = value
        }
    }
}

private extension UIView {
    var enclosingScrollView: UIScrollView? {
        if let scrollView = self as? UIScrollView {
            return scrollView
        }
        return superview?.enclosingScrollView
    }

    var allScrollViews: [UIScrollView] {
        var result: [UIScrollView] = []
        if let scrollView = self as? UIScrollView {
            result.append(scrollView)
        }
        for subview in subviews {
            result.append(contentsOf: subview.allScrollViews)
        }
        return result
    }
}

struct ContinuousScrollReader: View {
    let pages: [ComicPage]
    @Binding var currentPageIndex: Int
    let readingMode: ReadingMode
    let scrollSpeed: ScrollSpeed
    let comic: ComicBook
    let translateRequestID: UUID
    let ocrMagnifyRequestID: UUID
    let isOCRMagnificationVisible: Bool
    let targetLanguage: String
    let scrollJumpRequestID: UUID
    let scrollProgress: Double
    let scrollPageProgress: Double
    let onScrollPositionChange: (Int, Double, Double) -> Void
    let onTranslationStateChange: (Bool) -> Void
    let onToggleControls: () -> Void

    @State private var scrollView: UIScrollView?
    @State private var pageFrames: [Int: CGRect] = [:]
    @State private var pageContentFrames: [Int: CGRect] = [:]
    @State private var viewportSize: CGSize = .zero
    @State private var didRestorePosition = false
    @State private var lastStepTime = Date.distantPast
    @State private var lastScrollPositionNotifyDate = Date.distantPast
    @State private var visiblePageUpdateWorkItem: DispatchWorkItem?
    @State private var lastStableContentOffsetY: CGFloat = 0
    @State private var allowTopOffsetUntil = Date.distantPast

    var body: some View {
        GeometryReader { viewportProxy in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(pages) { page in
                            LocalImageView(
                                url: page.url,
                                isOCREnabled: comic.isOCREnabled,
                                isAITranslationEnabled: comic.isAITranslationEnabled,
                                isAutoTranslationEnabled: comic.isAutoTranslationEnabled && page.index == currentPageIndex,
                                translateRequestID: translateRequestID,
                                ocrMagnifyRequestID: ocrMagnifyRequestID,
                                isOCRMagnificationVisible: isOCRMagnificationVisible && page.index == currentPageIndex,
                                ocrTextScale: comic.ocrTextScale,
                                ocrSafeAreaInset: comic.ocrSafeAreaInset,
                                ocrMinimumTextHeight: comic.ocrMinimumTextHeight,
                                isRightToLeftReading: comic.readingDirectionRaw == ReadingDirection.rightToLeft.rawValue,
                                targetLanguage: targetLanguage,
                                imageFitMode: .fitWidth,
                                placeholderHeight: max(viewportProxy.size.height, viewportProxy.size.width * 1.35),
                                showsLoadingIndicator: page.index == currentPageIndex,
                                onTranslationStateChange: page.index == currentPageIndex ? onTranslationStateChange : { _ in },
                                onPreviousPage: { stepScroll(-1) },
                                onNextPage: { stepScroll(1) },
                                onToggleControls: onToggleControls
                            )
                            .frame(maxWidth: .infinity)
                            .id(page.index)
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: PageFramePreferenceKey.self,
                                        value: [page.index: geo.frame(in: .named("readerScroll"))]
                                    )
                                }
                            )
                        }
                    }
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: ScrollViewportSizePreferenceKey.self,
                                value: viewportProxy.size == .zero ? geo.size : viewportProxy.size
                            )
                        }
                    )
                }
                .coordinateSpace(name: "readerScroll")
                .background(ScrollViewAccessor(
                    onResolve: { resolvedScrollView in
                        if scrollView !== resolvedScrollView {
                            scrollView = resolvedScrollView
                        }
                    }
                ))
                .onAppear {
                    viewportSize = viewportProxy.size
                    restoreScrollPosition(proxy, animated: false)
                }
                .onChange(of: readingMode) { _, _ in
                    restoreScrollPosition(proxy, animated: false)
                }
                .onChange(of: scrollJumpRequestID) { _, _ in
                    restoreScrollPosition(proxy, animated: true)
                }
                .onPreferenceChange(ScrollViewportSizePreferenceKey.self) { size in
                    guard size != .zero else { return }
                    viewportSize = size
                    scheduleVisiblePageUpdate(delay: 0.02)
                }
                .onPreferenceChange(PageFramePreferenceKey.self) { frames in
                    pageFrames = frames
                    scheduleVisiblePageUpdate(delay: 0.08)
                }
                .onDisappear {
                    updateCurrentPageFromVisibleFrames()
                }
            }
        }
    }

    private func stepScroll(_ direction: Int) {
        guard let scrollView else { return }
        let now = Date()
        guard now.timeIntervalSince(lastStepTime) > 0.24 else { return }
        lastStepTime = now

        HapticManager.shared.play(.light)
        let visibleHeight = max(scrollView.bounds.height - scrollView.adjustedContentInset.top - scrollView.adjustedContentInset.bottom, 1)
        let distance = min(visibleHeight * scrollSpeed.screenStepRatio, visibleHeight * 0.8)
        let maxOffsetY = max(-scrollView.adjustedContentInset.top, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
        let minOffsetY = -scrollView.adjustedContentInset.top
        let targetY = min(max(scrollView.contentOffset.y + CGFloat(direction) * distance, minOffsetY), maxOffsetY)

        UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
            scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: targetY), animated: false)
        } completion: { _ in
            updateCurrentPageFromVisibleFrames()
        }
    }

    private func restoreScrollPosition(_ proxy: ScrollViewProxy, animated: Bool) {
        guard readingMode == .continuousScroll || readingMode == .infiniteScroll else { return }
        let targetIndex = min(max(currentPageIndex, 0), max(0, pages.count - 1))
        didRestorePosition = false
        allowTopOffsetUntil = Date().addingTimeInterval(0.8)
        let savedProgress = min(max(scrollProgress, 0), 1)
        let savedPageProgress = min(max(scrollPageProgress, 0), 1)
        DispatchQueue.main.async {
            let animation = animated ? Animation.easeInOut(duration: 0.3) : nil
            withAnimation(animation) {
                proxy.scrollTo(targetIndex, anchor: .top)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                if let scrollView {
                    let maxOffsetY = max(-scrollView.adjustedContentInset.top, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
                    let minOffsetY = -scrollView.adjustedContentInset.top
                    let targetFrame = pageFrames[targetIndex]
                    if let frame = targetFrame, frame.height > 1 {
                        let pageOffset = min(max(frame.height * savedPageProgress, 0), max(frame.height - 1, 0))
                        let targetY = min(max(scrollView.contentOffset.y + frame.minY + pageOffset, minOffsetY), maxOffsetY)
                        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: targetY), animated: animated)
                    } else if savedProgress > 0.001 {
                        let targetY = minOffsetY + (maxOffsetY - minOffsetY) * savedProgress
                        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: targetY), animated: false)
                    }
                    lastStableContentOffsetY = scrollView.contentOffset.y
                }
                didRestorePosition = true
                scheduleVisiblePageUpdate(delay: 0.05)
            }
        }
    }

    private func scheduleVisiblePageUpdate(delay: TimeInterval = 0.12) {
        visiblePageUpdateWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            updateCurrentPageFromVisibleFrames()
        }
        visiblePageUpdateWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func updateCurrentPageFromVisibleFrames() {
        updateCurrentPageFromViewport(frames: pageFrames, viewportSize: viewportSize)
    }

    private func updateCurrentPageFromViewport(frames: [Int: CGRect], viewportSize: CGSize) {
        guard didRestorePosition, !frames.isEmpty else { return }
        let visibleSize: CGSize
        if viewportSize != .zero {
            visibleSize = viewportSize
        } else if let scrollView {
            visibleSize = scrollView.bounds.size
        } else {
            return
        }

        if restoreUnexpectedScrollToTopIfNeeded(visibleHeight: visibleSize.height) {
            return
        }

        let viewport = CGRect(origin: .zero, size: visibleSize)
        let viewportCenterY = viewport.midY
        var visible = frames.compactMap { index, frame -> (Int, CGFloat, CGFloat)? in
            let overlap = frame.intersection(viewport)
            guard !overlap.isNull, overlap.height > 1 else { return nil }
            let centerDistance = abs(frame.midY - viewportCenterY)
            return (index, overlap.height, centerDistance)
        }
        if visible.isEmpty {
            visible = frames.map { index, frame in
                (index, CGFloat(0), abs(frame.midY - viewportCenterY))
            }
        }
        guard let best = visible.max(by: {
            if abs($0.1 - $1.1) > 1 {
                return $0.1 < $1.1
            }
            return $0.2 > $1.2
        }) else { return }
        let didChangePage = currentPageIndex != best.0
        if didChangePage {
            print("MReader scroll currentPageIndex update old=\(currentPageIndex) new=\(best.0) frames=\(frames.count)")
            currentPageIndex = best.0
        }

        let progress: CGFloat
        if let scrollView {
            let maxOffsetY = max(-scrollView.adjustedContentInset.top, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
            let minOffsetY = -scrollView.adjustedContentInset.top
            let denominator = max(maxOffsetY - minOffsetY, 1)
            progress = min(max((scrollView.contentOffset.y - minOffsetY) / denominator, 0), 1)
            if scrollView.contentOffset.y > minOffsetY + 8 {
                lastStableContentOffsetY = scrollView.contentOffset.y
            }
        } else {
            progress = CGFloat(best.0) / CGFloat(max(pages.count - 1, 1))
        }
        let activeFrame = frames[best.0]
        let pageProgress: CGFloat
        if let activeFrame, activeFrame.height > 1 {
            pageProgress = min(max(-activeFrame.minY / max(activeFrame.height, 1), 0), 1)
        } else {
            pageProgress = 0
        }
        let shouldNotifyProgress = didChangePage || Date().timeIntervalSince(lastScrollPositionNotifyDate) > 1.0
        if shouldNotifyProgress {
            lastScrollPositionNotifyDate = Date()
            onScrollPositionChange(best.0, Double(progress), Double(pageProgress))
        }
    }

    private func restoreUnexpectedScrollToTopIfNeeded(visibleHeight: CGFloat) -> Bool {
        guard let scrollView, currentPageIndex > 0 else { return false }
        guard Date() > allowTopOffsetUntil else { return false }
        let minOffsetY = -scrollView.adjustedContentInset.top
        let currentY = scrollView.contentOffset.y
        let hadMeaningfulPosition = lastStableContentOffsetY > minOffsetY + max(visibleHeight * 0.45, 160)
        let jumpedToTop = currentY <= minOffsetY + 2
        guard hadMeaningfulPosition, jumpedToTop else { return false }

        let maxOffsetY = max(minOffsetY, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
        let restoreY = min(max(lastStableContentOffsetY, minOffsetY), maxOffsetY)
        print("MReader scroll prevented unexpected top jump page=\(currentPageIndex) restoreY=\(Int(restoreY))")
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: restoreY), animated: false)
        scheduleVisiblePageUpdate(delay: 0.04)
        return true
    }
}

struct AnimatedPageReader: View {
    let pages: [ComicPage]
    @Binding var currentPageIndex: Int
    @Binding var pageTurnDirection: Int
    let readingDirection: ReadingDirection
    let readingMode: ReadingMode
    let pageTurnAnimation: PageTurnAnimation
    let imageFitMode: ImageFitMode
    let comic: ComicBook
    let translateRequestID: UUID
    let ocrMagnifyRequestID: UUID
    let isOCRMagnificationVisible: Bool
    let targetLanguage: String
    let onTranslationStateChange: (Bool) -> Void
    let onToggleControls: () -> Void

    @GestureState private var dragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let isRTL = readingDirection == .rightToLeft

            ZStack {
                if pages.indices.contains(currentPageIndex) {
                    pageView(index: currentPageIndex)
                        .id(pages[currentPageIndex].id)
                        .transition(transition)
                        .rotation3DEffect(
                            .degrees(pageTurnAnimation == .curl ? Double(dragOffset / -18) : 0),
                            axis: (x: readingMode == .verticalPage ? 1 : 0, y: readingMode == .verticalPage ? 0 : 1, z: 0),
                            anchor: dragOffset < 0 ? .leading : .trailing,
                            perspective: 0.75
                        )
                        .offset(pageOffset)
                        .animation(pageTurnAnimation == .none ? nil : .easeInOut(duration: 0.24), value: currentPageIndex)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 28)
                    .updating($dragOffset) { value, state, _ in
                        state = readingMode == .verticalPage ? value.translation.height : value.translation.width
                    }
                    .onEnded { value in
                        let axisLength = readingMode == .verticalPage ? geo.size.height : geo.size.width
                        let threshold = max(axisLength * 0.2, 72)
                        let rawDelta = readingMode == .verticalPage ? value.translation.height : value.translation.width
                        let logicalDelta = readingMode == .verticalPage ? rawDelta : (isRTL ? rawDelta : -rawDelta)
                        if logicalDelta > threshold {
                            nextPage()
                        } else if logicalDelta < -threshold {
                            previousPage()
                        }
                    }
            )
        }
    }

    private var transition: AnyTransition {
        switch pageTurnAnimation {
        case .none:
            return .identity
        case .slide:
            return directionalSlideTransition
        case .curl:
            return .asymmetric(
                insertion: .scale(scale: 0.96).combined(with: .opacity),
                removal: .scale(scale: 1.04).combined(with: .opacity)
            )
        case .fade:
            return .opacity
        }
    }

    private var directionalSlideTransition: AnyTransition {
        let isForward = pageTurnDirection >= 0
        if readingMode == .verticalPage {
            return .asymmetric(
                insertion: .move(edge: isForward ? .bottom : .top),
                removal: .move(edge: isForward ? .top : .bottom)
            )
        }

        let forwardInsertion: Edge = readingDirection == .rightToLeft ? .leading : .trailing
        let forwardRemoval: Edge = readingDirection == .rightToLeft ? .trailing : .leading
        return .asymmetric(
            insertion: .move(edge: isForward ? forwardInsertion : forwardRemoval),
            removal: .move(edge: isForward ? forwardRemoval : forwardInsertion)
        )
    }

    private var pageOffset: CGSize {
        guard pageTurnAnimation == .slide || pageTurnAnimation == .curl else { return .zero }
        if readingMode == .verticalPage {
            return CGSize(width: 0, height: dragOffset * 0.18)
        }
        return CGSize(width: dragOffset * 0.18, height: 0)
    }

    private func pageView(index: Int) -> some View {
        LocalImageView(
            url: pages[index].url,
            isOCREnabled: comic.isOCREnabled,
            isAITranslationEnabled: comic.isAITranslationEnabled,
            isAutoTranslationEnabled: comic.isAutoTranslationEnabled,
            translateRequestID: translateRequestID,
            ocrMagnifyRequestID: ocrMagnifyRequestID,
                            isOCRMagnificationVisible: isOCRMagnificationVisible,
                            ocrTextScale: comic.ocrTextScale,
                            ocrSafeAreaInset: comic.ocrSafeAreaInset,
                            ocrMinimumTextHeight: comic.ocrMinimumTextHeight,
                            isRightToLeftReading: readingDirection == .rightToLeft,
            targetLanguage: targetLanguage,
            imageFitMode: imageFitMode,
            onTranslationStateChange: onTranslationStateChange,
            onPreviousPage: previousPage,
            onNextPage: nextPage,
            onToggleControls: onToggleControls
        )
    }

    private func previousPage() {
        guard currentPageIndex > 0 else {
            HapticManager.shared.play(.warning)
            return
        }
        HapticManager.shared.play(.light)
        pageTurnDirection = -1
        currentPageIndex = max(0, currentPageIndex - 1)
    }

    private func nextPage() {
        guard currentPageIndex < max(0, pages.count - 1) else {
            HapticManager.shared.play(.warning)
            return
        }
        HapticManager.shared.play(.light)
        pageTurnDirection = 1
        currentPageIndex = min(max(0, pages.count - 1), currentPageIndex + 1)
    }
}

struct DoublePageReader: View {
    let pages: [ComicPage]
    @Binding var currentPageIndex: Int
    @Binding var pageTurnDirection: Int
    let readingDirection: ReadingDirection
    let pageTurnAnimation: PageTurnAnimation
    let imageFitMode: ImageFitMode
    let comic: ComicBook
    let translateRequestID: UUID
    let ocrMagnifyRequestID: UUID
    let isOCRMagnificationVisible: Bool
    let targetLanguage: String
    let onTranslationStateChange: (Bool) -> Void
    let onToggleControls: () -> Void

    @GestureState private var dragOffset: CGFloat = 0

    private var leftPageIndex: Int {
        currentPageIndex - currentPageIndex % 2
    }

    private var rightPageIndex: Int {
        leftPageIndex + 1
    }

    var body: some View {
        GeometryReader { geo in
            let isRTL = readingDirection == .rightToLeft
            HStack(spacing: 0) {
                let pair = isRTL ? [rightPageIndex, leftPageIndex] : [leftPageIndex, rightPageIndex]
                ForEach(pair, id: \.self) { index in
                    if pages.indices.contains(index) {
                        pageView(index: index)
                            .frame(width: geo.size.width / 2, height: geo.size.height)
                    } else {
                        Color.black.frame(width: geo.size.width / 2, height: geo.size.height)
                    }
                }
            }
            .id(leftPageIndex)
            .transition(doublePageTransition)
            .offset(x: (pageTurnAnimation == .slide || pageTurnAnimation == .curl) ? dragOffset * 0.16 : 0)
            .animation(pageTurnAnimation == .none ? nil : .easeInOut(duration: 0.24), value: leftPageIndex)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 28)
                    .updating($dragOffset) { value, state, _ in
                        state = value.translation.width
                    }
                    .onEnded { value in
                        let threshold = max(geo.size.width * 0.2, 72)
                        let logicalDelta = isRTL ? value.translation.width : -value.translation.width
                        if logicalDelta > threshold {
                            nextSpread()
                        } else if logicalDelta < -threshold {
                            previousSpread()
                        }
                    }
            )
            .simultaneousGesture(
                SpatialTapGesture()
                    .onEnded { value in
                        handleTap(at: value.location, in: geo.size)
                    }
            )
        }
    }

    private func pageView(index: Int) -> some View {
        LocalImageView(
            url: pages[index].url,
            isOCREnabled: comic.isOCREnabled,
            isAITranslationEnabled: comic.isAITranslationEnabled,
            isAutoTranslationEnabled: comic.isAutoTranslationEnabled,
            translateRequestID: translateRequestID,
            ocrMagnifyRequestID: ocrMagnifyRequestID,
            isOCRMagnificationVisible: isOCRMagnificationVisible,
            ocrTextScale: comic.ocrTextScale,
            ocrSafeAreaInset: comic.ocrSafeAreaInset,
            ocrMinimumTextHeight: comic.ocrMinimumTextHeight,
            isRightToLeftReading: readingDirection == .rightToLeft,
            targetLanguage: targetLanguage,
            imageFitMode: imageFitMode,
            onTranslationStateChange: onTranslationStateChange,
            onPreviousPage: {},
            onNextPage: {},
            onToggleControls: onToggleControls
        )
    }

    private func handleTap(at location: CGPoint, in size: CGSize) {
        let edgeWidth = size.width * 0.28
        let centerWidth = size.width * 0.22
        let centerMinX = (size.width - centerWidth) / 2
        let centerMaxX = centerMinX + centerWidth
        if location.x >= centerMinX && location.x <= centerMaxX {
            onToggleControls()
            return
        }
        if location.x < edgeWidth {
            readingDirection == .rightToLeft ? nextSpread() : previousSpread()
        } else if location.x > size.width - edgeWidth {
            readingDirection == .rightToLeft ? previousSpread() : nextSpread()
        } else {
            onToggleControls()
        }
    }

    private var doublePageTransition: AnyTransition {
        switch pageTurnAnimation {
        case .fade:
            return .opacity
        case .slide:
            let isForward = pageTurnDirection >= 0
            let forwardInsertion: Edge = readingDirection == .rightToLeft ? .leading : .trailing
            let forwardRemoval: Edge = readingDirection == .rightToLeft ? .trailing : .leading
            return .asymmetric(
                insertion: .move(edge: isForward ? forwardInsertion : forwardRemoval),
                removal: .move(edge: isForward ? forwardRemoval : forwardInsertion)
            )
        case .curl:
            return .asymmetric(
                insertion: .scale(scale: 0.96).combined(with: .opacity),
                removal: .scale(scale: 1.04).combined(with: .opacity)
            )
        case .none:
            return .identity
        }
    }

    private func previousSpread() {
        guard leftPageIndex > 0 else {
            HapticManager.shared.play(.warning)
            return
        }
        HapticManager.shared.play(.light)
        pageTurnDirection = -1
        currentPageIndex = max(0, leftPageIndex - 2)
    }

    private func nextSpread() {
        guard leftPageIndex + 2 <= max(0, pages.count - 1) else {
            HapticManager.shared.play(.warning)
            return
        }
        HapticManager.shared.play(.light)
        pageTurnDirection = 1
        currentPageIndex = min(max(0, pages.count - 1), leftPageIndex + 2)
    }
}

struct TwoFingerSwipeDownDismissView: UIViewRepresentable {
    let onSwipe: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSwipe: onSwipe)
    }

    func makeUIView(context: Context) -> UIView {
        let view = WindowGestureInstallView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onSwipe = onSwipe
        (uiView as? WindowGestureInstallView)?.coordinator = context.coordinator
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onSwipe: () -> Void
        let recognizer = UIPanGestureRecognizer()
        private var hasTriggered = false

        init(onSwipe: @escaping () -> Void) {
            self.onSwipe = onSwipe
            super.init()
            recognizer.minimumNumberOfTouches = 2
            recognizer.maximumNumberOfTouches = 2
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            recognizer.addTarget(self, action: #selector(handlePan(_:)))
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let translation = recognizer.translation(in: view)
            let velocity = recognizer.velocity(in: view)
            switch recognizer.state {
            case .began:
                hasTriggered = false
            case .changed, .ended:
                guard !hasTriggered else { return }
                let isDownward = translation.y > 110 && velocity.y > 220
                let isMostlyVertical = abs(translation.x) < translation.y * 0.65
                if isDownward && isMostlyVertical {
                    hasTriggered = true
                    HapticManager.shared.play(.medium)
                    onSwipe()
                }
            case .cancelled, .failed:
                hasTriggered = false
            default:
                break
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }

    final class WindowGestureInstallView: UIView {
        weak var coordinator: Coordinator? {
            didSet {
                installRecognizerIfNeeded()
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            installRecognizerIfNeeded()
        }

        private func installRecognizerIfNeeded() {
            guard let window, let coordinator else { return }
            if coordinator.recognizer.view !== window {
                coordinator.recognizer.view?.removeGestureRecognizer(coordinator.recognizer)
                window.addGestureRecognizer(coordinator.recognizer)
            }
        }

        deinit {
            if let recognizer = coordinator?.recognizer {
                recognizer.view?.removeGestureRecognizer(recognizer)
            }
        }
    }
}

struct LocalImageView: View {
    let url: URL
    let isOCREnabled: Bool
    let isAITranslationEnabled: Bool
    let isAutoTranslationEnabled: Bool
    let translateRequestID: UUID
    let ocrMagnifyRequestID: UUID
    let isOCRMagnificationVisible: Bool
    let ocrTextScale: Double
    let ocrSafeAreaInset: Double
    let ocrMinimumTextHeight: Double
    let isRightToLeftReading: Bool
    let targetLanguage: String
    let imageFitMode: ImageFitMode
    var placeholderHeight: CGFloat? = nil
    var showsLoadingIndicator: Bool = true
    var onTranslationStateChange: (Bool) -> Void = { _ in }
    let onPreviousPage: () -> Void
    let onNextPage: () -> Void
    let onToggleControls: () -> Void
    @State private var uiImage: UIImage? = nil
    @State private var isLoadingImage = true
    @State private var loadFailed = false
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var pendingSingleTapWorkItem: DispatchWorkItem?
    @State private var lastDoubleTapTime = Date.distantPast
    @State private var viewportWidth: CGFloat = 0
    
    // AI 相关的状态
    @State private var textBlocks: [TextBlock] = []
    @State private var ocrTextBlocks: [TextBlock] = []
    @State private var debugTextBlocks: [TextBlock] = []
    @State private var recognizedBlocksCache: [TextBlock]?
    @State private var recognizedBlocksCacheKey: String?
    @State private var isTranslating = false
    @State private var isRecognizingOCR = false
    @State private var translationTask: Task<Void, Never>?
    @AppStorage("openai_api_key") private var apiKey = ""
    @AppStorage("openai_base_url") private var baseURL = "https://api.openai.com/v1"
    @AppStorage("openai_model") private var modelName = "gpt-4o-mini"
    @AppStorage("translation_prompt_template") private var translationPromptTemplate = AITranslator.defaultTranslationPromptTemplate
    @AppStorage("ocr_show_debug_boxes") private var ocrShowDebugBoxes = false
    @AppStorage("ocr_use_vision_model") private var ocrUseVisionModel = false

    private var canTranslate: Bool {
        isOCREnabled && isAITranslationEnabled
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let uiImage = uiImage {
                // 1. 底图与翻译文本覆盖层
                fittedImage(uiImage)
                    // 核心逻辑：直接在图片上层按比例渲染文本气泡
                    .overlay(
                        GeometryReader { geo in
                            ZStack {
                                translationOverlay(in: geo.size)
                                ocrMagnificationOverlay(in: geo.size)
                                ocrDebugOverlay(in: geo.size)
                            }
                        }
                    )
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(zoomGesture)
                    .simultaneousGesture(doubleTapGesture)
                    .simultaneousGesture(tapPageGesture)
                    .simultaneousGesture(longPressTranslationGesture)
                    .frame(height: displayHeight(for: uiImage))

            } else if isLoadingImage {
                if showsLoadingIndicator {
                    ProgressView().tint(.white).controlSize(.regular)
                } else {
                    Color.clear
                }
            } else if loadFailed {
                ContentUnavailableView("图片加载失败", systemImage: "exclamationmark.triangle", description: Text(url.lastPathComponent))
                    .foregroundStyle(.white)
            }
        }
        .frame(height: reservedDisplayHeight)
        .frame(maxWidth: .infinity, minHeight: imageFitMode == .fitWidth ? nil : 0, maxHeight: imageFitMode == .fitWidth ? nil : .infinity)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { viewportWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, newValue in
                        viewportWidth = newValue
                    }
            }
        }
        .task(id: url) { await loadImage() }
        .onDisappear {
            translationTask?.cancel()
            translationTask = nil
            if isTranslating {
                isTranslating = false
                onTranslationStateChange(false)
            }
        }
        .onChange(of: translateRequestID) { _, _ in
            startTranslation()
        }
        .onChange(of: ocrMagnifyRequestID) { _, _ in
            startOCRMagnification()
        }
        .onChange(of: isOCRMagnificationVisible) { _, newValue in
            if newValue {
                startOCRMagnification()
            } else {
                ocrTextBlocks.removeAll()
            }
        }
        .onChange(of: isAutoTranslationEnabled) { _, newValue in
            guard newValue else { return }
            startTranslation()
        }
        .onChange(of: isOCREnabled) { _, newValue in
            if !newValue {
                ocrTextBlocks.removeAll()
            }
        }
        .onChange(of: canTranslate) { _, newValue in
            if !newValue {
                textBlocks.removeAll()
            }
        }
    }

    @ViewBuilder
    private func fittedImage(_ image: UIImage) -> some View {
        switch imageFitMode {
        case .fitScreen:
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
        case .fitWidth:
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
        case .fitHeight:
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: .infinity)
        case .original:
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        }
    }

    private func displayHeight(for image: UIImage) -> CGFloat? {
        guard imageFitMode == .fitWidth, viewportWidth > 1, image.size.width > 0 else { return nil }
        return max(1, viewportWidth * image.size.height / image.size.width)
    }

    private var reservedDisplayHeight: CGFloat? {
        if let uiImage {
            return displayHeight(for: uiImage)
        }
        guard imageFitMode == .fitWidth else { return nil }
        return placeholderHeight
    }

    @ViewBuilder
    private func translationOverlay(in size: CGSize) -> some View {
        if canTranslate {
            let items = translationLayoutItems(in: size)
            ForEach(items) { item in
                ColorfulTranslatedText(
                    text: item.block.translation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                    fontSize: translationFontSize(for: item.block, in: size)
                )
                .frame(width: item.rect.width)
                .position(x: item.rect.midX, y: item.rect.midY)
            }
        }
    }

    private var visibleTranslationBlocks: [TextBlock] {
        let candidates = textBlocks.filter {
            ($0.translation ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        return AITranslator.deduplicatedMangaTextBlocks(
            candidates,
            isRightToLeft: isRightToLeftReading
        )
    }

    @ViewBuilder
    private func ocrMagnificationOverlay(in size: CGSize) -> some View {
        if isOCRMagnificationVisible {
            ForEach(ocrTextBlocks) { block in
                let rect = ocrBubbleRect(for: block, in: size)
                Text(block.text)
                    .font(.system(size: ocrFontSize(for: block, in: size), weight: .semibold))
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.55)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.92))
                    .foregroundColor(.black)
                    .cornerRadius(6)
                    .frame(width: rect.size.width)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
    }

    @ViewBuilder
    private func ocrDebugOverlay(in size: CGSize) -> some View {
        if ocrShowDebugBoxes, isOCREnabled {
            ForEach(debugTextBlocks) { block in
                let rect = CGRect(
                    x: block.boundingBox.minX * size.width,
                    y: block.boundingBox.minY * size.height,
                    width: max(block.boundingBox.width * size.width, 12),
                    height: max(block.boundingBox.height * size.height, 10)
                )
                let color = block.isFiltered ? Color.red : Color.green
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .stroke(color, lineWidth: 1.2)
                    Text(debugLabel(for: block))
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .lineLimit(3)
                        .padding(2)
                        .background(color.opacity(0.84))
                        .foregroundStyle(.white)
                }
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
            }
        }
    }

    private func debugLabel(for block: TextBlock) -> String {
        let confidence = Int((block.confidence * 100).rounded())
        if block.isFiltered {
            return "\(confidence)% \(block.filterReason ?? "过滤")\n\(block.text)"
        }
        return "\(confidence)% \(block.ocrSource)\n\(block.text)"
    }

    private func overlayRect(for block: TextBlock, in size: CGSize, scaleMultiplier: CGFloat) -> CGRect {
        let width = max(block.boundingBox.width * size.width * scaleMultiplier, 44)
        let height = max(block.boundingBox.height * size.height * scaleMultiplier, 24)
        let x = block.boundingBox.midX * size.width
        let y = block.boundingBox.midY * size.height
        return CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height)
    }

    private func translationBubbleRect(for block: TextBlock, in size: CGSize) -> CGRect {
        let magnificationScale: CGFloat = isOCRMagnificationVisible ? 1.18 : 1
        let original = overlayRect(for: block, in: size, scaleMultiplier: magnificationScale)
        let safeMargin: CGFloat = 12
        let maxWidth = max(96, min(size.width - safeMargin * 2, isOCRMagnificationVisible ? 230 : 190))
        let widthMultiplier: CGFloat = isOCRMagnificationVisible ? 1.32 : 1.08
        let width = min(max(original.width * widthMultiplier, 70), maxWidth)
        let height = min(max(original.height * 1.16, 24), 56)
        let x = min(max(original.midX, safeMargin + width / 2), size.width - safeMargin - width / 2)
        let y = min(max(original.midY, safeMargin + height / 2), size.height - safeMargin - height / 2)
        return CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height)
    }

    private func translationLayoutItems(in size: CGSize) -> [TranslationLayoutItem] {
        var occupiedRects: [CGRect] = []
        var items: [TranslationLayoutItem] = []
        for block in visibleTranslationBlocks {
            let original = translationBubbleRect(for: block, in: size)
            let anchor = CGPoint(
                x: block.boundingBox.midX * size.width,
                y: block.boundingBox.midY * size.height
            )
            let rect = nonOverlappingTranslationRect(original, anchor: anchor, occupiedRects: occupiedRects, in: size)
            occupiedRects.append(rect.insetBy(dx: -4, dy: -4))
            items.append(TranslationLayoutItem(block: block, rect: rect))
        }
        return items
    }

    private func nonOverlappingTranslationRect(_ original: CGRect, anchor: CGPoint, occupiedRects: [CGRect], in size: CGSize) -> CGRect {
        guard !occupiedRects.contains(where: { $0.intersects(original) }) else {
            let safeMargin: CGFloat = 12
            let stepY = max(original.height * 0.85, 22)
            let stepX = max(original.width * 0.45, 32)
            var candidates = [original]
            for distance in 1...5 {
                let dy = CGFloat(distance) * stepY
                let dx = CGFloat(distance) * stepX
                candidates.append(original.offsetBy(dx: 0, dy: -dy))
                candidates.append(original.offsetBy(dx: 0, dy: dy))
                candidates.append(original.offsetBy(dx: -dx, dy: 0))
                candidates.append(original.offsetBy(dx: dx, dy: 0))
                candidates.append(original.offsetBy(dx: -dx * 0.65, dy: -dy * 0.65))
                candidates.append(original.offsetBy(dx: dx * 0.65, dy: -dy * 0.65))
                candidates.append(original.offsetBy(dx: -dx * 0.65, dy: dy * 0.65))
                candidates.append(original.offsetBy(dx: dx * 0.65, dy: dy * 0.65))
            }

            return candidates
                .map { clampedTranslationRect($0, safeMargin: safeMargin, in: size) }
                .min { lhs, rhs in
                    translationLayoutScore(lhs, anchor: anchor, occupiedRects: occupiedRects) <
                        translationLayoutScore(rhs, anchor: anchor, occupiedRects: occupiedRects)
                } ?? original
        }
        return original
    }

    private func clampedTranslationRect(_ rect: CGRect, safeMargin: CGFloat, in size: CGSize) -> CGRect {
        let x = min(max(rect.midX, safeMargin + rect.width / 2), size.width - safeMargin - rect.width / 2)
        let y = min(max(rect.midY, safeMargin + rect.height / 2), size.height - safeMargin - rect.height / 2)
        return CGRect(x: x - rect.width / 2, y: y - rect.height / 2, width: rect.width, height: rect.height)
    }

    private func translationLayoutScore(_ rect: CGRect, anchor: CGPoint, occupiedRects: [CGRect]) -> CGFloat {
        let overlapPenalty = occupiedRects.reduce(CGFloat.zero) { partial, occupied in
            let overlap = rect.intersection(occupied)
            guard !overlap.isNull else { return partial }
            return partial + overlap.width * overlap.height * 90
        }
        let distance = hypot(rect.midX - anchor.x, rect.midY - anchor.y)
        return distance + overlapPenalty
    }

    private func ocrBubbleRect(for block: TextBlock, in size: CGSize) -> CGRect {
        let rectScale = 1 + (ocrTextSizeFactor - 1) * 0.28
        let original = overlayRect(for: block, in: size, scaleMultiplier: rectScale)
        let safeMargin: CGFloat = 12
        let maxWidth = max(100, size.width - safeMargin * 2)
        let width = min(max(original.width, 72), maxWidth)
        let x = min(max(original.midX, safeMargin + width / 2), size.width - safeMargin - width / 2)
        let y = min(max(original.midY, safeMargin + 18), size.height - safeMargin - 18)
        return CGRect(x: x - width / 2, y: y - 18, width: width, height: 36)
    }

    private func loadImage() async {
        await MainActor.run {
            translationTask?.cancel()
            translationTask = nil
            if isTranslating {
                isTranslating = false
                onTranslationStateChange(false)
            }
        }
        let maxPixelSize = preferredDecodeMaxPixelSize
        if let cachedImage = ReaderImageCache.shared.cachedImage(for: url, maxPixelSize: maxPixelSize) {
            await MainActor.run {
                isLoadingImage = false
                loadFailed = false
                uiImage = cachedImage
                textBlocks.removeAll()
                ocrTextBlocks.removeAll()
                debugTextBlocks.removeAll()
                recognizedBlocksCache = nil
                recognizedBlocksCacheKey = nil
                scale = 1
                lastScale = 1
                offset = .zero
                pendingSingleTapWorkItem?.cancel()
                pendingSingleTapWorkItem = nil
            }
            if isAutoTranslationEnabled {
                await MainActor.run { startTranslation() }
            }
            if isOCRMagnificationVisible {
                await MainActor.run { startOCRMagnification() }
            }
            return
        }

        await MainActor.run {
            isLoadingImage = true
            loadFailed = false
            uiImage = nil
            textBlocks.removeAll()
            ocrTextBlocks.removeAll()
            debugTextBlocks.removeAll()
            recognizedBlocksCache = nil
            recognizedBlocksCacheKey = nil
            scale = 1
            lastScale = 1
            offset = .zero
            pendingSingleTapWorkItem?.cancel()
            pendingSingleTapWorkItem = nil
        }

        let loadedImage = await ReaderImageCache.shared.loadImage(for: url, maxPixelSize: maxPixelSize)
        await MainActor.run {
            self.uiImage = loadedImage
            self.loadFailed = loadedImage == nil
            self.isLoadingImage = false
        }
        if isAutoTranslationEnabled {
            await MainActor.run { startTranslation() }
        }
        if isOCRMagnificationVisible {
            await MainActor.run { startOCRMagnification() }
        }
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = min(max(lastScale * value, 1), 5)
            }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1.02 {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                        scale = 1
                        lastScale = 1
                        offset = .zero
                    }
                }
            }
    }

    private var doubleTapGesture: some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { value in
                pendingSingleTapWorkItem?.cancel()
                pendingSingleTapWorkItem = nil
                lastDoubleTapTime = Date()
                withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                    if scale > 1.1 {
                        scale = 1
                        lastScale = 1
                        offset = .zero
                    } else {
                        scale = 2.5
                        lastScale = 2.5
                        offset = CGSize(width: -value.location.x * 0.35, height: -value.location.y * 0.18)
                    }
                }
            }
    }

    private var tapPageGesture: some Gesture {
        SpatialTapGesture(count: 1, coordinateSpace: .local)
            .onEnded { value in
                guard scale <= 1.05 else { return }
                guard Date().timeIntervalSince(lastDoubleTapTime) > 0.28 else { return }

                pendingSingleTapWorkItem?.cancel()
                let tapLocation = value.location
                let workItem = DispatchWorkItem {
                    guard Date().timeIntervalSince(lastDoubleTapTime) > 0.28 else { return }
                    let width = max(viewportWidth, 1)
                    if tapLocation.x < width / 3.0 {
                        onPreviousPage()
                    } else if tapLocation.x > width * 2.0 / 3.0 {
                        onNextPage()
                    } else {
                        onToggleControls()
                    }
                }
                pendingSingleTapWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
            }
    }

    private var longPressTranslationGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.55, maximumDistance: 18)
            .onEnded { _ in
                guard canTranslate, scale <= 1.05 else { return }
                pendingSingleTapWorkItem?.cancel()
                pendingSingleTapWorkItem = nil
                HapticManager.shared.play(.medium)
                startTranslation()
            }
    }

    private func ocrFontSize(for block: TextBlock, in size: CGSize) -> CGFloat {
        let boxWidth = max(block.boundingBox.width * size.width, 1)
        let boxHeight = max(block.boundingBox.height * size.height, 1)
        let characterCount = max(block.text.filter { !$0.isWhitespace && !$0.isNewline }.count, 1)
        let isVerticalText = boxHeight > boxWidth * 1.35

        let estimatedOriginalFontSize: CGFloat
        if isVerticalText {
            let perCharacterHeight = boxHeight / CGFloat(characterCount)
            let verticalEstimate = min(boxWidth * 0.82, perCharacterHeight * 1.05)
            estimatedOriginalFontSize = max(verticalEstimate, min(boxWidth, boxHeight) * 0.46)
        } else {
            let averageCharacterWidth = boxWidth / CGFloat(characterCount)
            let widthBasedEstimate = averageCharacterWidth * 1.45
            let horizontalEstimate = min(boxHeight * 0.62, widthBasedEstimate)
            estimatedOriginalFontSize = max(horizontalEstimate, boxHeight * 0.48)
        }

        let scaled = max(estimatedOriginalFontSize, 7) * ocrTextSizeFactor
        return min(max(scaled, 9), 22)
    }

    private func translationFontSize(for block: TextBlock, in size: CGSize) -> CGFloat {
        let blockHeight = max(block.boundingBox.height * size.height, 10)
        let baseSize = min(max(blockHeight * 0.36, 9), 13)
        guard isOCRMagnificationVisible else { return baseSize }
        let magnified = baseSize * min(max(ocrTextSizeFactor, 1), 1.22)
        return min(max(magnified, 9), 15)
    }

    private var ocrTextSizeFactor: CGFloat {
        let normalized: Double
        if ocrTextScale > 1 {
            normalized = min(max((ocrTextScale - 0.8) / 2.4, 0), 1)
        } else {
            normalized = min(max(ocrTextScale, 0), 1)
        }
        return 0.92 + CGFloat(normalized) * 0.44
    }

    private func preparedTextBlocks(from blocks: [TextBlock]) -> [TextBlock] {
        let annotated = AITranslator.annotatedMangaTextBlocks(
            blocks,
            safeAreaInset: ocrSafeAreaInset,
            minimumTextHeight: ocrMinimumTextHeight,
            isRightToLeft: isRightToLeftReading
        )
        if ocrShowDebugBoxes {
            debugTextBlocks = annotated
        }
        let filtered = annotated.filter { !$0.isFiltered }
        return AITranslator.groupedMangaTextBlocks(filtered, isRightToLeft: isRightToLeftReading)
    }

    private var preferredDecodeMaxPixelSize: CGFloat {
        imageFitMode == .fitWidth ? 8192 : 4096
    }

    private func startOCRMagnification() {
        guard isOCREnabled, isOCRMagnificationVisible, !isRecognizingOCR, let image = uiImage else { return }
        isRecognizingOCR = true

        Task {
            do {
                let recognizedBlocks = try await recognizedTextBlocks(for: image)
                let blocks = preparedTextBlocks(from: recognizedBlocks)
                await MainActor.run {
                    self.ocrTextBlocks = blocks
                    self.isRecognizingOCR = false
                }
            } catch {
                await MainActor.run {
                    self.ocrTextBlocks.removeAll()
                    self.isRecognizingOCR = false
                }
            }
        }
    }
    
    // 触发 AI 流程
    private func startTranslation() {
        translationTask?.cancel()
        guard canTranslate, let image = uiImage else { return }
        let pageURL = url
        isTranslating = true
        onTranslationStateChange(true)
        
        translationTask = Task {
            do {
                let recognizedBlocks = try await recognizedTextBlocks(for: image)
                try Task.checkCancellation()
                let blocks = preparedTextBlocks(from: recognizedBlocks)
                await MainActor.run { self.textBlocks = blocks } // 先显示个框（可选）
                
                let maxConcurrentTranslations = 3
                var nextIndex = 0
                while nextIndex < blocks.count {
                    try Task.checkCancellation()
                    let batchEnd = min(nextIndex + maxConcurrentTranslations, blocks.count)
                    await withTaskGroup(of: (Int, String).self) { group in
                        for i in nextIndex..<batchEnd {
                            let text = blocks[i].text
                            let key = apiKey
                            let base = baseURL
                            let model = modelName
                            let target = targetLanguage
                            let prompt = translationPromptTemplate
                            group.addTask {
                                guard !Task.isCancelled else { return (i, "") }
                                let translated = try? await AITranslator.translate(text: text, apiKey: key, baseURL: base, model: model, targetLanguage: target, promptTemplate: prompt)
                                return (i, translated ?? "翻译失败")
                            }
                        }

                        for await (index, translatedText) in group {
                            guard !Task.isCancelled else { return }
                            await MainActor.run {
                                guard !Task.isCancelled else { return }
                                guard self.url == pageURL else { return }
                                guard textBlocks.indices.contains(index) else { return }
                                guard !translatedText.isEmpty else { return }
                                textBlocks[index].translation = translatedText
                            }
                        }
                    }
                    nextIndex = batchEnd
                }
            } catch {
                if !Task.isCancelled {
                    print("翻译异常: \(error)")
                }
            }
            await MainActor.run {
                self.isTranslating = false
                self.onTranslationStateChange(false)
                self.translationTask = nil
            }
        }
    }

    private func recognizedTextBlocks(for image: UIImage) async throws -> [TextBlock] {
        let key = "\(url.absoluteString)#rtl=\(isRightToLeftReading)#min=\(ocrMinimumTextHeight)"
        if recognizedBlocksCacheKey == key, let recognizedBlocksCache {
            return recognizedBlocksCache
        }
        if ocrUseVisionModel {
            print("MReader OCR visual model enabled but image upload is not automatic; using local Vision OCR.")
        }
        let ocrImage = await OCRPreprocessor.highResolutionImage(from: url, fallback: image) ?? image
        let blocks = try await AITranslator.recognizeText(in: ocrImage, isRightToLeft: isRightToLeftReading, minimumTextHeight: ocrMinimumTextHeight)
        await MainActor.run {
            self.recognizedBlocksCacheKey = key
            self.recognizedBlocksCache = blocks
        }
        return blocks
    }
}

private struct TranslationLayoutItem: Identifiable {
    let block: TextBlock
    let rect: CGRect

    var id: UUID { block.id }
}

private struct ColorfulTranslatedText: View {
    let text: String
    let fontSize: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: fontSize, weight: .semibold))
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.center)
            .foregroundStyle(colorGradient)
            .shadow(color: .white.opacity(0.45), radius: 0.8, x: 0, y: 0)
            .shadow(color: .black.opacity(0.5), radius: 1.8, x: 0, y: 1)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.95),
                                Color(red: 0.86, green: 0.94, blue: 1.0).opacity(0.93),
                                Color(red: 1.0, green: 0.88, blue: 0.96).opacity(0.93)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(colorGradient.opacity(0.86), lineWidth: 1)
                    }
            }
    }

    private var colorGradient: LinearGradient {
        LinearGradient(
            colors: Self.palette,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static let palette: [Color] = [
        Color(red: 0.18, green: 0.56, blue: 0.95),
        Color(red: 0.42, green: 0.34, blue: 0.92),
        Color(red: 0.68, green: 0.30, blue: 0.88),
        Color(red: 0.88, green: 0.32, blue: 0.68),
        Color(red: 0.20, green: 0.72, blue: 0.78),
        Color(red: 0.30, green: 0.66, blue: 0.90),
        Color(red: 0.90, green: 0.56, blue: 0.30).opacity(0.62)
    ]
}

private struct AppleIntelligenceGlowBorder: View {
    let cornerRadius: CGFloat
    let lineWidth: CGFloat
    let blurRadius: CGFloat
    let animationDuration: TimeInterval
    let colors: [Color]

    var body: some View {
        TimelineView(.animation) { context in
            let duration = max(animationDuration, 0.1)
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: duration) / duration
            GeometryReader { proxy in
                let bandWidth = max(lineWidth, 1)
                let screenCornerRadius = adaptiveScreenCornerRadius(for: proxy.size)
                let outerCornerRadius = screenCornerRadius > 0 ? screenCornerRadius : cornerRadius
                let layerCount = 36
                let layerWidth = bandWidth / CGFloat(layerCount)
                let outwardExpansion = max(layerWidth * 1.5, 1)
                let drawingSize = CGSize(
                    width: proxy.size.width + outwardExpansion * 2,
                    height: proxy.size.height + outwardExpansion * 2
                )
                ZStack {
                    ForEach(0..<layerCount, id: \.self) { index in
                        let progress = CGFloat(index) / CGFloat(max(layerCount - 1, 1))
                        let opacity = 1.0 - Double(progress) * 0.94
                        RoundedRectangle(
                            cornerRadius: max(outerCornerRadius - CGFloat(index) * layerWidth, 0),
                            style: .continuous
                        )
                        .inset(by: outwardExpansion + CGFloat(index) * layerWidth)
                        .strokeBorder(
                            flowingGradient(phase: phase + Double(index) * 0.004),
                            lineWidth: max(layerWidth + 0.12, 0.55),
                            antialiased: true
                        )
                        .opacity(opacity)
                    }

                    RoundedRectangle(cornerRadius: outerCornerRadius, style: .continuous)
                        .inset(by: outwardExpansion)
                        .strokeBorder(flowingGradient(phase: phase), lineWidth: max(layerWidth * 2.2, 1.2), antialiased: true)
                        .opacity(1)
                        .brightness(0.16)
                }
                .frame(width: drawingSize.width, height: drawingSize.height)
                .offset(x: -outwardExpansion, y: -outwardExpansion)
            }
            .drawingGroup()
        }
    }

    private func flowingGradient(phase: Double) -> AngularGradient {
        let palette = colors.isEmpty ? ColorfulTranslatedText.palette : colors
        let normalizedPhase = phase.truncatingRemainder(dividingBy: 1)
        let gradientColors = palette + palette.prefix(2)
        return AngularGradient(
            colors: gradientColors,
            center: .center,
            angle: .degrees(normalizedPhase * 360)
        )
    }

    private func adaptiveScreenCornerRadius(for size: CGSize) -> CGFloat {
        let modelIdentifier = Self.deviceModelIdentifier
        if UIDevice.current.userInterfaceIdiom == .pad {
            if let exactRadius = Self.iPadCornerRadiusByIdentifier[modelIdentifier] {
                return exactRadius
            }
            let screen = Self.normalizedScreenSize(for: size)
            if screen.minSide >= 740 && screen.minSide <= 770 && screen.maxSide >= 1000 && screen.maxSide <= 1040 {
                return 22
            }
            return min(max(min(size.width, size.height) * 0.035, 20), 30)
        }
        if Self.squareScreenIPhoneIdentifiers.contains(modelIdentifier) {
            return 0
        }
        if let exactRadius = Self.iPhoneCornerRadiusByIdentifier[modelIdentifier] {
            return exactRadius
        }
        let screen = Self.normalizedScreenSize(for: size)
        if screen.minSide >= 400 && screen.minSide <= 405 && screen.maxSide >= 870 && screen.maxSide <= 878 {
            return 62
        }
        if screen.minSide >= 410 && screen.minSide <= 416 && screen.maxSide >= 890 && screen.maxSide <= 900 {
            return 46
        }
        let shortSide = min(size.width, size.height)
        guard shortSide > 0 else { return cornerRadius }
        switch shortSide {
        case ..<380:
            return 39
        case ..<395:
            return 47
        case ..<430:
            return 55
        default:
            return 62
        }
    }

    private static func normalizedScreenSize(for size: CGSize) -> (minSide: CGFloat, maxSide: CGFloat) {
        let width = min(size.width, size.height)
        let height = max(size.width, size.height)
        return (width, height)
    }

    private static var deviceModelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) { machinePointer in
                String(cString: machinePointer)
            }
        }
    }

    private static let squareScreenIPhoneIdentifiers: Set<String> = [
        "iPhone10,1", "iPhone10,4",
        "iPhone12,8",
        "iPhone14,6"
    ]

    private static let iPhoneCornerRadiusByIdentifier: [String: CGFloat] = [
        "iPhone10,3": 39,
        "iPhone10,6": 39,
        "iPhone11,2": 39,
        "iPhone11,4": 41,
        "iPhone11,6": 41,
        "iPhone11,8": 39,
        "iPhone12,1": 46,
        "iPhone12,3": 39,
        "iPhone12,5": 41,
        "iPhone13,1": 44,
        "iPhone13,2": 47,
        "iPhone13,3": 47,
        "iPhone13,4": 53,
        "iPhone14,2": 55,
        "iPhone14,3": 55,
        "iPhone14,4": 44,
        "iPhone14,5": 47,
        "iPhone14,7": 47,
        "iPhone14,8": 53,
        "iPhone15,2": 55,
        "iPhone15,3": 55,
        "iPhone15,4": 55,
        "iPhone15,5": 55,
        "iPhone16,1": 55,
        "iPhone16,2": 55,
        "iPhone17,1": 62,
        "iPhone17,2": 66,
        "iPhone17,3": 62,
        "iPhone17,4": 62,
        "iPhone17,5": 62,
        "iPhone18,1": 62,
        "iPhone18,2": 62,
        "iPhone18,3": 58,
        "iPhone18,4": 58
    ]

    private static let iPadCornerRadiusByIdentifier: [String: CGFloat] = [
        "iPad14,1": 22,
        "iPad14,2": 22,
        "iPad16,1": 22,
        "iPad16,2": 22
    ]
}
