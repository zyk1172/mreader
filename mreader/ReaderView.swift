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
                case .opds:
                    result = await OPDSProvider.loadPages(for: comic)
                }
                if let result {
                    if comic.sourceType == .komga,
                       let remotePage = try? await KomgaProvider.remoteReadProgress(for: comic),
                       remotePage > comic.currentPageIndex {
                        let maxIndex = max(0, result.pages.count - 1)
                        comic.currentPageIndex = min(remotePage, maxIndex)
                        onComicUpdate(comic)
                    }
                    if comic.sourceType == .opds, comic.totalPages != result.pages.count {
                        comic.totalPages = result.pages.count
                        comic.remotePageCount = result.pages.count
                        comic.currentPageIndex = min(comic.currentPageIndex, max(0, result.pages.count - 1))
                        onComicUpdate(comic)
                    }
                    manager.applyLoadedPages(result)
                    isLoaded = true
                } else {
                    loadFailed = true
                }
            }
        }
        .onDisappear {
            // ReaderView 必须先用仍然存在的页面数保存进度，再释放安全作用域和页面。
            DispatchQueue.main.async {
                manager.stopAccessing()
            }
        }
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

private struct InitialReadingPreset {
    let readingMode: ReadingMode
    let pageTurnAnimation: PageTurnAnimation
    let imageFitMode: ImageFitMode
    let reason: String

    static let longStrip = InitialReadingPreset(
        readingMode: .continuousScroll,
        pageTurnAnimation: .none,
        imageFitMode: .fitWidth,
        reason: "long-strip"
    )

    static let normalPage = InitialReadingPreset(
        readingMode: .horizontalPage,
        pageTurnAnimation: .slide,
        imageFitMode: .fitScreen,
        reason: "normal-page"
    )
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

nonisolated private func imagePixelSize(from data: Data) -> CGSize? {
    guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
        return nil
    }
    return imagePixelSize(from: source)
}

nonisolated private func imagePixelSize(from url: URL) -> CGSize? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
        return nil
    }
    return imagePixelSize(from: source)
}

nonisolated private func imagePixelSize(from source: CGImageSource) -> CGSize? {
    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
          let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
          width > 0,
          height > 0 else {
        return nil
    }
    return CGSize(width: width, height: height)
}

struct ReaderView: View {
    var manager: ComicManager
    @State private var comic: ComicBook
    let onComicUpdate: (ComicBook) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    
    @AppStorage("translation_target_language") private var translationTargetLanguage = "中文"
    @AppStorage("ocr_show_debug_boxes") private var ocrShowDebugBoxes = false
    @AppStorage("ai_translation_border_progress_enabled") private var aiTranslationBorderProgressEnabled = true
    @AppStorage("translation_color_style") private var translationColorStyleRaw = TranslationColorStyle.contrast.rawValue
    @State private var currentPageIndex: Int
    @State private var showControls: Bool = false
    @State private var showComicSettings = false
    @State private var translateRequestID = UUID()
    @State private var ocrMagnifyRequestID = UUID()
    @State private var isOCRMagnificationVisible = false
    @State private var pageTurnDirection = 1
    @State private var didRestoreScrollPosition = false
    @State private var jumpPageText = ""
    @State private var scrollJumpRequestID = UUID()
    @State private var didRecordReaderOpen = false
    @State private var lastSavedScrollProgress: Double
    @State private var lastSavedScrollPageProgress: Double
    @State private var lastProgressPersistDate = Date.distantPast
    @State private var lastPrefetchPageIndex: Int
    @State private var isAITranslationInProgress = false
    @State private var activityLastRecordedAt = Date()
    @State private var activityLastPageIndex: Int
    @State private var dismissGestureProgress: CGFloat = 0
    @State private var isDismissAnimating = false
    @State private var lastReaderInteractionAt = Date()
    @State private var isBurnInProtectionLocked = false
    @AppStorage("burn_in_protection_enabled") private var isBurnInProtectionEnabled = true

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

    private var aiTranslationMode: AITranslationMode {
        comic.aiTranslationMode
    }

    private var isOCRMagnificationActive: Bool {
        comic.isOCREnabled && (isOCRMagnificationVisible || comic.isAutoOCRMagnificationEnabled)
    }

    private var readingModeRaw: Binding<String> {
        Binding(
            get: { comic.readingModeRaw },
            set: { newValue in updateComic { $0.readingModeRaw = newValue; $0.hasInitializedReadingPreset = true } }
        )
    }

    private var readingDirectionRaw: Binding<String> {
        Binding(
            get: { comic.readingDirectionRaw },
            set: { newValue in updateComic { $0.readingDirectionRaw = newValue; $0.hasInitializedReadingPreset = true } }
        )
    }

    private var scrollSpeedRaw: Binding<String> {
        Binding(
            get: { comic.scrollSpeedRaw },
            set: { newValue in updateComic { $0.scrollSpeedRaw = newValue; $0.hasInitializedReadingPreset = true } }
        )
    }

    private var pageTurnAnimationRaw: Binding<String> {
        Binding(
            get: { comic.pageTurnAnimationRaw },
            set: { newValue in updateComic { $0.pageTurnAnimationRaw = newValue; $0.hasInitializedReadingPreset = true } }
        )
    }

    private var imageFitModeRaw: Binding<String> {
        Binding(
            get: { comic.imageFitModeRaw },
            set: { newValue in updateComic { $0.imageFitModeRaw = newValue; $0.hasInitializedReadingPreset = true } }
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
        _activityLastPageIndex = State(initialValue: min(max(comic.currentPageIndex, 0), maxIndex))
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
                    areControlsVisible: showControls,
                    onShowControls: showControlsIfNeeded,
                    onHideControls: hideControls
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
                    areControlsVisible: showControls,
                    onShowControls: showControlsIfNeeded,
                    onHideControls: hideControls
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
                    areControlsVisible: showControls,
                    onShowControls: showControlsIfNeeded,
                    onHideControls: hideControls
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

            TwoFingerSwipeDownDismissView(
                onProgress: { progress in
                    guard !isDismissAnimating else { return }
                    dismissGestureProgress = progress
                    recordReaderInteraction()
                },
                onCancel: {
                    guard !isDismissAnimating else { return }
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
                        dismissGestureProgress = 0
                    }
                },
                onSwipe: completeTwoFingerDismiss
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .background(ScrollsToTopDisabledView())

            ReaderControlsDoubleTapOverlay(isEnabled: !showComicSettings) {
                toggleControls()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()

            ReaderPageTapOverlay(
                isEnabled: (readingMode == .horizontalPage || readingMode == .verticalPage || readingMode == .doublePage) && !showControls && !showComicSettings,
                onPreviousPage: previousContainerPage,
                onNextPage: nextContainerPage,
                onLongPress: {
                    guard comic.isAITranslationEnabled else { return }
                    HapticManager.shared.play(.medium)
                    translateRequestID = UUID()
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()

            if showControls {
                GeometryReader { proxy in
                    VStack(spacing: 0) {
                        readerTopControlBar
                            .padding(.top, proxy.safeAreaInsets.top + 4)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 8)
                            .background(.ultraThinMaterial)
                        Spacer(minLength: 0)
                    }
                    .ignoresSafeArea(edges: .top)
                }
                .transition(.opacity)
                .zIndex(20)
            }

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

            if isBurnInProtectionLocked {
                Color.black
                    .ignoresSafeArea()
                    .overlay {
                        VStack(spacing: 14) {
                            Image(systemName: "lock.display")
                                .font(.system(size: 38, weight: .medium))
                            Text("屏幕保护已启用")
                                .font(.headline)
                            Text("页面静止超过 4 小时。轻点屏幕继续阅读。")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(28)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        isBurnInProtectionLocked = false
                        recordReaderInteraction()
                    }
                    .zIndex(100)
            }
        }
        .scaleEffect(max(0.72, 1 - dismissGestureProgress * 0.22))
        .offset(y: dismissGestureProgress * 190)
        .opacity(max(0.08, 1 - dismissGestureProgress * 0.88))
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle("")
        .navigationBarBackButtonHidden(true) // 核心：拦截原生左侧边缘的滑动返回手势
        .defersSystemGestures(on: .horizontal) // 将水平滑动优先级完全交给翻页
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showComicSettings) {
            comicSettingsSheet
        }
        .onAppear {
            recordReaderInteraction()
            applyEPUBPresetBeforeFirstOpen()
            Task {
                await initializeReadingPresetIfNeeded()
            }
            recordReaderOpenIfNeeded()
            preloadPages(around: currentPageIndex)
        }
        .onDisappear {
            RemotePagePrefetcher.shared.cancelAll()
            recordReadingActivity()
            persistReadingProgress(pageIndex: currentPageIndex, reason: "readerDisappear", force: true)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { break }
                recordReadingActivity()
                checkBurnInProtection()
            }
        }
        .statusBar(hidden: true)
        .onChange(of: currentPageIndex) { oldValue, newValue in
            let clampedValue = min(max(newValue, 0), max(0, manager.pages.count - 1))
            if clampedValue != newValue {
                currentPageIndex = clampedValue
                return
            }
            if newValue != oldValue {
                pageTurnDirection = newValue > oldValue ? 1 : -1
                recordReadingActivity()
                recordReaderInteraction()
            }
            let isScrollingMode = readingMode == .continuousScroll || readingMode == .infiniteScroll
            persistReadingProgress(pageIndex: clampedValue, reason: "currentPageIndexChanged", force: !isScrollingMode)
            preloadPages(around: clampedValue)
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .background || newPhase == .inactive else { return }
            recordReadingActivity()
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

    private var readerTopControlBar: some View {
        HStack(spacing: 12) {
            Button {
                HapticManager.shared.play(.light)
                dismiss()
            } label: {
                Label("返回", systemImage: "chevron.backward")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 72, minHeight: 40, alignment: .leading)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 4)

            Text(manager.pages.isEmpty ? "" : "\(currentPageIndex + 1) / \(manager.pages.count)")
                .font(.system(.headline, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(minWidth: 76, minHeight: 40)

            Spacer(minLength: 4)

            Button {
                HapticManager.shared.play(.light)
                showComicSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("阅读设置")
        }
        .contentShape(Rectangle())
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

                    Picker("翻译模式", selection: Binding(
                        get: { comic.aiTranslationMode },
                        set: { newValue in
                            updateComic {
                                $0.aiTranslationModeRaw = newValue.rawValue
                                if newValue == .ocr {
                                    $0.isOCREnabled = true
                                }
                            }
                        }
                    )) {
                        Text("OCR 文本").tag(AITranslationMode.ocr)
                        Text("视觉图片").tag(AITranslationMode.vision)
                    }
                    .pickerStyle(.segmented)
                    .disabled(!comic.isAITranslationEnabled)

                    Toggle("自动翻译当前页", isOn: Binding(
                        get: { comic.isAutoTranslationEnabled },
                        set: { newValue in updateComic { $0.isAutoTranslationEnabled = newValue } }
                    ))
                    .disabled(!comic.isAITranslationEnabled || (aiTranslationMode == .ocr && !comic.isOCREnabled))

                    Toggle("AI 翻译边框进度", isOn: $aiTranslationBorderProgressEnabled)
                        .disabled(!comic.isAITranslationEnabled)

                    Picker("翻译文字配色", selection: $translationColorStyleRaw) {
                        ForEach(TranslationColorStyle.allCases, id: \.rawValue) { style in
                            Text(style.title).tag(style.rawValue)
                        }
                    }
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
                            ), in: 0.002...0.035, step: 0.001)
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

                Section(header: Text("OCR 调试"), footer: Text("视觉图片识别翻译会把当前页或兜底切片发送到第三方 OpenAI 兼容接口。")) {
                    Toggle("显示 OCR 调试框", isOn: $ocrShowDebugBoxes)
                        .disabled(!comic.isOCREnabled)
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

    private func initializeReadingPresetIfNeeded() async {
        guard !comic.hasInitializedReadingPreset else { return }
        guard comic.currentPageIndex == 0 else {
            await MainActor.run {
                comic.hasInitializedReadingPreset = true
                onComicUpdate(comic)
            }
            return
        }

        let preset = await detectInitialReadingPreset()
        await MainActor.run {
            guard !comic.hasInitializedReadingPreset, comic.currentPageIndex == 0 else { return }
            comic.readingModeRaw = preset.readingMode.rawValue
            comic.pageTurnAnimationRaw = preset.pageTurnAnimation.rawValue
            comic.imageFitModeRaw = preset.imageFitMode.rawValue
            comic.isAutoOCRMagnificationEnabled = false
            comic.isAutoTranslationEnabled = false
            comic.hasInitializedReadingPreset = true
            print("MReader initial preset comic=\(comic.id) mode=\(comic.readingModeRaw) animation=\(comic.pageTurnAnimationRaw) fit=\(comic.imageFitModeRaw) reason=\(preset.reason)")
            onComicUpdate(comic)
        }
    }

    private func applyEPUBPresetBeforeFirstOpen() {
        guard isEPUBComic, !comic.hasBeenOpened else { return }
        comic.readingModeRaw = ReadingMode.horizontalPage.rawValue
        comic.pageTurnAnimationRaw = PageTurnAnimation.curl.rawValue
        comic.imageFitModeRaw = ImageFitMode.fitScreen.rawValue
        comic.hasInitializedReadingPreset = true
        onComicUpdate(comic)
    }

    private func detectInitialReadingPreset() async -> InitialReadingPreset {
        if isEPUBComic {
            return InitialReadingPreset(
                readingMode: .horizontalPage,
                pageTurnAnimation: .curl,
                imageFitMode: .fitScreen,
                reason: "epub"
            )
        }
        if isPDFComic {
            return InitialReadingPreset(
                readingMode: InitialReadingPreset.longStrip.readingMode,
                pageTurnAnimation: InitialReadingPreset.longStrip.pageTurnAnimation,
                imageFitMode: InitialReadingPreset.longStrip.imageFitMode,
                reason: "pdf"
            )
        }
        let sampleIndices = readingPresetSamplePageIndices(totalPages: manager.pages.count)
        guard !sampleIndices.isEmpty else {
            print("MReader initial preset fallback: no sample pages for comic=\(comic.id)")
            return InitialReadingPreset.normalPage
        }
        var ratios: [CGFloat] = []
        for index in sampleIndices {
            guard manager.pages.indices.contains(index),
                  let size = await pagePixelSize(for: manager.pages[index].url) else {
                print("MReader initial preset sample skipped comic=\(comic.id) page=\(index + 1)")
                continue
            }
            ratios.append(size.height / max(size.width, 1))
        }
        guard let medianRatio = medianRatio(ratios) else {
            print("MReader initial preset fallback: cannot read sample page sizes comic=\(comic.id) samples=\(sampleIndices.map { $0 + 1 })")
            return InitialReadingPreset.normalPage
        }
        if medianRatio > 1.8 {
            return InitialReadingPreset(
                readingMode: .continuousScroll,
                pageTurnAnimation: .none,
                imageFitMode: .fitWidth,
                reason: String(format: "median ratio %.3f pages %@", medianRatio, sampleIndices.map { "\($0 + 1)" }.joined(separator: ","))
            )
        }
        return InitialReadingPreset(
            readingMode: .horizontalPage,
            pageTurnAnimation: .slide,
            imageFitMode: .fitScreen,
            reason: String(format: "median ratio %.3f pages %@", medianRatio, sampleIndices.map { "\($0 + 1)" }.joined(separator: ","))
        )
    }

    private func readingPresetSamplePageIndices(totalPages: Int) -> [Int] {
        guard totalPages > 0 else { return [] }
        let preferred = (2..<min(totalPages, 5)).map { $0 }
        if !preferred.isEmpty {
            return preferred
        }
        return Array(0..<totalPages)
    }

    private func medianRatio(_ ratios: [CGFloat]) -> CGFloat? {
        guard !ratios.isEmpty else { return nil }
        let sortedRatios = ratios.sorted()
        let middle = sortedRatios.count / 2
        if sortedRatios.count.isMultiple(of: 2) {
            return (sortedRatios[middle - 1] + sortedRatios[middle]) / 2
        }
        return sortedRatios[middle]
    }

    private var isEPUBComic: Bool {
        hasDocumentExtension("epub")
    }

    private var isPDFComic: Bool {
        hasDocumentExtension("pdf")
    }

    private func hasDocumentExtension(_ expectedExtension: String) -> Bool {
        let rawValues = [comic.libraryPath, comic.chapterPath, comic.sourceURL]
        if rawValues.contains(where: { path in
            guard let path else { return false }
            if let url = URL(string: path), url.scheme != nil {
                return url.pathExtension.lowercased() == expectedExtension
            }
            return URL(fileURLWithPath: path).pathExtension.lowercased() == expectedExtension
        }) {
            return true
        }
        let chapterType = comic.chapterTypeRaw?.lowercased()
        return chapterType == expectedExtension
    }

    private func pagePixelSize(for url: URL) async -> CGSize? {
        if RemotePageLoader.isRemotePageURL(url) {
            guard let data = await RemotePageLoader.imageData(forRemotePageURL: url) else { return nil }
            return imagePixelSize(from: data)
        }
        if ComicManager.isArchivePageURL(url), let data = ComicManager.imageData(forArchivePageURL: url) {
            return imagePixelSize(from: data)
        }
        return await Task.detached(priority: .utility) {
            imagePixelSize(from: url)
        }.value
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
        min(max(CGFloat(comic.ocrMinimumTextHeight) * 900, 2), 32)
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
        comic.hasBeenOpened = true
        activityLastRecordedAt = Date()
        activityLastPageIndex = currentPageIndex
        let clampedValue = min(max(currentPageIndex, 0), max(0, manager.pages.count - 1))
        print("MReader progress open comic=\(comic.id) restoredPage=\(clampedValue) storedPage=\(comic.currentPageIndex) mode=\(comic.readingModeRaw)")
        persistReadingProgress(pageIndex: clampedValue, reason: "readerOpen", force: true)
    }

    private func saveScrollPosition(pageIndex: Int, progress: Double, pageProgress: Double) {
        if pageIndex != currentPageIndex ||
            abs(progress - lastSavedScrollProgress) > 0.001 ||
            abs(pageProgress - lastSavedScrollPageProgress) > 0.004 {
            recordReaderInteraction()
        }
        persistReadingProgress(pageIndex: pageIndex, scrollProgress: progress, scrollPageProgress: pageProgress, reason: "scrollVisiblePage", force: false)
    }

    private func updateAITranslationProgress(_ isInProgress: Bool) {
        guard isAITranslationInProgress != isInProgress else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            isAITranslationInProgress = isInProgress
        }
    }

    private func persistReadingProgress(pageIndex: Int, scrollProgress: Double? = nil, scrollPageProgress: Double? = nil, reason: String, force: Bool) {
        let clampedPageIndex = ReaderProgressPolicy.clampedPageIndex(
            pageIndex,
            loadedPageCount: manager.pages.count,
            declaredPageCount: comic.totalPages
        )
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
        comic.hasBeenOpened = true
        comic.scrollProgress = clampedProgress
        comic.scrollPageProgress = clampedPageProgress
        comic.lastReadAt = Date()
        print("MReader progress persist reason=\(reason) comic=\(comic.id) page=\(clampedPageIndex) global=\(String(format: "%.4f", clampedProgress)) pageProgress=\(String(format: "%.4f", clampedPageProgress))")
        onComicUpdate(comic)
    }

    private func recordReadingActivity() {
        let now = Date()
        let pageIndex = min(max(currentPageIndex, 0), max(0, manager.pages.count - 1))
        ReadingActivityStore.shared.record(
            comicID: comic.id,
            previousDate: activityLastRecordedAt,
            now: now,
            previousPageIndex: activityLastPageIndex,
            currentPageIndex: pageIndex,
            completed: comic.hasBeenOpened && pageIndex >= max(0, manager.pages.count - 1)
        )
        activityLastRecordedAt = now
        activityLastPageIndex = pageIndex
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

    private func previousContainerPage() {
        if readingMode == .doublePage {
            let leftPageIndex = currentPageIndex - currentPageIndex % 2
            guard leftPageIndex > 0 else {
                HapticManager.shared.play(.warning)
                return
            }
            HapticManager.shared.play(.light)
            pageTurnDirection = -1
            currentPageIndex = max(0, leftPageIndex - 2)
        } else {
            previousPage()
        }
    }

    private func nextContainerPage() {
        if readingMode == .doublePage {
            let leftPageIndex = currentPageIndex - currentPageIndex % 2
            guard leftPageIndex + 2 <= max(0, manager.pages.count - 1) else {
                HapticManager.shared.play(.warning)
                return
            }
            HapticManager.shared.play(.light)
            pageTurnDirection = 1
            currentPageIndex = min(max(0, manager.pages.count - 1), leftPageIndex + 2)
        } else {
            nextPage()
        }
    }
    
    private func toggleControls() {
        if showControls {
            HapticManager.shared.play(.light)
            hideControls()
        } else {
            showControlsIfNeeded()
        }
    }

    private func showControlsIfNeeded() {
        recordReaderInteraction()
        HapticManager.shared.play(.light)
        if !showControls {
            withAnimation(.easeInOut(duration: 0.18)) {
                showControls = true
            }
        }
    }

    private func hideControls() {
        recordReaderInteraction()
        withAnimation(.easeInOut(duration: 0.18)) {
            showControls = false
        }
    }

    private func recordReaderInteraction() {
        lastReaderInteractionAt = Date()
    }

    private func checkBurnInProtection(now: Date = Date()) {
        guard isBurnInProtectionEnabled,
              !isBurnInProtectionLocked,
              now.timeIntervalSince(lastReaderInteractionAt) >= BurnInProtectionPolicy.timeout else { return }
        recordReadingActivity()
        persistReadingProgress(pageIndex: currentPageIndex, reason: "burnInProtection", force: true)
        UIApplication.shared.isIdleTimerDisabled = false
        HapticManager.shared.play(.warning)
        isBurnInProtectionLocked = true
    }

    private func completeTwoFingerDismiss() {
        guard !isDismissAnimating else { return }
        isDismissAnimating = true
        HapticManager.shared.play(.medium)
        recordReadingActivity()
        persistReadingProgress(pageIndex: currentPageIndex, reason: "twoFingerDismiss", force: true)
        withAnimation(.easeIn(duration: 0.24)) {
            dismissGestureProgress = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            dismiss()
        }
    }

}

nonisolated enum BurnInProtectionPolicy {
    static let timeout: TimeInterval = 4 * 60 * 60
}

nonisolated enum ReaderProgressPolicy {
    static func clampedPageIndex(_ pageIndex: Int, loadedPageCount: Int, declaredPageCount: Int) -> Int {
        let pageCount = max(loadedPageCount, declaredPageCount)
        return min(max(pageIndex, 0), max(0, pageCount - 1))
    }
}

// MARK: - 支持 AI 的图片加载器
private struct ReaderControlsDoubleTapOverlay: View {
    let isEnabled: Bool
    let onToggle: () -> Void

    var body: some View {
        ReaderControlsDoubleTapRecognizer(isEnabled: isEnabled, onToggle: onToggle)
    }
}

private struct ReaderControlsDoubleTapRecognizer: UIViewRepresentable {
    let isEnabled: Bool
    let onToggle: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isEnabled: isEnabled, onToggle: onToggle)
    }

    func makeUIView(context: Context) -> UIView {
        let view = InstallingView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.onToggle = onToggle
        context.coordinator.attach(to: uiView.window)
    }

    final class InstallingView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.attach(to: window)
        }

        deinit {
            coordinator?.detach()
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var isEnabled: Bool
        var onToggle: () -> Void
        private weak var hostView: UIView?
        private var recognizer: UITapGestureRecognizer?

        init(isEnabled: Bool, onToggle: @escaping () -> Void) {
            self.isEnabled = isEnabled
            self.onToggle = onToggle
        }

        func attach(to view: UIView?) {
            if hostView == nil && view == nil {
                return
            }
            if let hostView, let view, hostView === view {
                return
            }
            detach()
            guard let view else { return }
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
            recognizer.numberOfTapsRequired = 2
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            view.addGestureRecognizer(recognizer)
            self.hostView = view
            self.recognizer = recognizer
        }

        func detach() {
            if let recognizer {
                recognizer.view?.removeGestureRecognizer(recognizer)
            }
            recognizer = nil
            hostView = nil
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            onToggle()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard isEnabled, let view = gestureRecognizer.view else { return false }
            guard !ReaderGestureTouchFilter.isInteractiveTouch(touch) else { return false }
            let location = touch.location(in: view)
            let bounds = view.bounds
            guard bounds.width > 1, bounds.height > 1 else { return false }
            return location.x >= bounds.width * 0.35 &&
                location.x <= bounds.width * 0.65 &&
                location.y >= bounds.height * 0.25 &&
                location.y <= bounds.height * 0.75
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

private struct ReaderPageTapOverlay: View {
    let isEnabled: Bool
    let onPreviousPage: () -> Void
    let onNextPage: () -> Void
    let onLongPress: () -> Void

    var body: some View {
        ReaderPageTapRecognizer(
            isEnabled: isEnabled,
            onPreviousPage: onPreviousPage,
            onNextPage: onNextPage,
            onLongPress: onLongPress
        )
    }
}

private struct ReaderPageTapRecognizer: UIViewRepresentable {
    let isEnabled: Bool
    let onPreviousPage: () -> Void
    let onNextPage: () -> Void
    let onLongPress: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isEnabled: isEnabled,
            onPreviousPage: onPreviousPage,
            onNextPage: onNextPage,
            onLongPress: onLongPress
        )
    }

    func makeUIView(context: Context) -> UIView {
        let view = InstallingView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.onPreviousPage = onPreviousPage
        context.coordinator.onNextPage = onNextPage
        context.coordinator.onLongPress = onLongPress
        context.coordinator.attach(to: uiView.window)
    }

    final class InstallingView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.attach(to: window)
        }

        deinit {
            coordinator?.detach()
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var isEnabled: Bool
        var onPreviousPage: () -> Void
        var onNextPage: () -> Void
        var onLongPress: () -> Void
        private weak var hostView: UIView?
        private var recognizer: UITapGestureRecognizer?
        private var longPressRecognizer: UILongPressGestureRecognizer?

        init(isEnabled: Bool, onPreviousPage: @escaping () -> Void, onNextPage: @escaping () -> Void, onLongPress: @escaping () -> Void) {
            self.isEnabled = isEnabled
            self.onPreviousPage = onPreviousPage
            self.onNextPage = onNextPage
            self.onLongPress = onLongPress
        }

        func attach(to view: UIView?) {
            if hostView == nil && view == nil {
                return
            }
            if let hostView, let view, hostView === view {
                return
            }
            detach()
            guard let view else { return }
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            recognizer.numberOfTapsRequired = 1
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
            longPress.minimumPressDuration = 0.55
            longPress.allowableMovement = 18
            longPress.cancelsTouchesInView = false
            longPress.delegate = self
            recognizer.require(toFail: longPress)
            view.addGestureRecognizer(recognizer)
            view.addGestureRecognizer(longPress)
            self.hostView = view
            self.recognizer = recognizer
            self.longPressRecognizer = longPress
        }

        func detach() {
            if let recognizer {
                recognizer.view?.removeGestureRecognizer(recognizer)
            }
            if let longPressRecognizer {
                longPressRecognizer.view?.removeGestureRecognizer(longPressRecognizer)
            }
            recognizer = nil
            longPressRecognizer = nil
            hostView = nil
        }

        @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began else { return }
            onLongPress()
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            let location = recognizer.location(in: view)
            let xRatio = location.x / max(view.bounds.width, 1)
            if xRatio < 0.35 {
                onPreviousPage()
            } else if xRatio > 0.65 {
                onNextPage()
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard isEnabled, let view = gestureRecognizer.view else { return false }
            guard !ReaderGestureTouchFilter.isInteractiveTouch(touch) else { return false }
            let location = touch.location(in: view)
            let bounds = view.bounds
            guard bounds.width > 1, bounds.height > 1 else { return false }
            if gestureRecognizer is UILongPressGestureRecognizer {
                return true
            }
            let xRatio = location.x / bounds.width
            return xRatio < 0.35 || xRatio > 0.65
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

private enum ReaderGestureTouchFilter {
    static func isInteractiveTouch(_ touch: UITouch) -> Bool {
        var view = touch.view
        while let current = view {
            if current is UIControl ||
                current is UINavigationBar ||
                current is UIToolbar ||
                current is UITextField ||
                current is UITextView {
                return true
            }
            let typeName = String(describing: type(of: current))
            if typeName.contains("NavigationBar") ||
                typeName.contains("Toolbar") ||
                typeName.contains("TextField") {
                return true
            }
            view = current.superview
        }
        return false
    }
}

private struct PageHeightPreferenceKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]

    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newValue in newValue })
    }
}

nonisolated enum ReaderVisiblePageDetector {
    static func visiblePageIndex(frames: [Int: CGRect], viewport: CGRect) -> Int? {
        guard !frames.isEmpty, viewport.width > 0, viewport.height > 0 else { return nil }
        let viewportCenterY = viewport.midY
        let candidates = frames.compactMap { index, frame -> (index: Int, visibleArea: CGFloat, centerDistance: CGFloat)? in
            let intersection = frame.intersection(viewport)
            guard !intersection.isNull, intersection.width > 1, intersection.height > 1 else { return nil }
            return (
                index: index,
                visibleArea: intersection.width * intersection.height,
                centerDistance: abs(frame.midY - viewportCenterY)
            )
        }
        return candidates.max { lhs, rhs in
            if abs(lhs.visibleArea - rhs.visibleArea) > 1 {
                return lhs.visibleArea < rhs.visibleArea
            }
            if abs(lhs.centerDistance - rhs.centerDistance) > 0.5 {
                return lhs.centerDistance > rhs.centerDistance
            }
            return lhs.index > rhs.index
        }?.index
    }
}

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
    let onScroll: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScroll: onScroll)
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
                context.coordinator.onScroll = onScroll
                context.coordinator.attach(to: scrollView)
                onResolve(scrollView)
            }
        }
    }

    final class Coordinator {
        var onScroll: () -> Void
        weak var scrollView: UIScrollView?
        private var contentOffsetObservation: NSKeyValueObservation?

        init(onScroll: @escaping () -> Void) {
            self.onScroll = onScroll
        }

        func attach(to scrollView: UIScrollView) {
            scrollView.scrollsToTop = false
            guard self.scrollView !== scrollView else { return }
            self.scrollView = scrollView
            contentOffsetObservation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async {
                    self?.onScroll()
                }
            }
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
    private static let coordinateSpaceName = "mreader.readerScroll"

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
    let areControlsVisible: Bool
    let onShowControls: () -> Void
    let onHideControls: () -> Void

    @State private var scrollView: UIScrollView?
    @State private var pageHeights: [Int: CGFloat] = [:]
    @State private var pageFrames: [Int: CGRect] = [:]
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
                                aiTranslationModeRaw: comic.aiTranslationModeRaw,
                                translateRequestID: translateRequestID,
                                ocrMagnifyRequestID: ocrMagnifyRequestID,
                                isOCRMagnificationVisible: isOCRMagnificationVisible && page.index == currentPageIndex,
                                ocrTextScale: comic.ocrTextScale,
                                ocrSafeAreaInset: comic.ocrSafeAreaInset,
                                ocrMinimumTextHeight: comic.ocrMinimumTextHeight,
                                isRightToLeftReading: comic.readingDirectionRaw == ReadingDirection.rightToLeft.rawValue,
                                targetLanguage: targetLanguage,
                                imageFitMode: .fitWidth,
                                visionViewportAspect: max(viewportProxy.size.height / max(viewportProxy.size.width, 1), 1.25),
                                placeholderHeight: max(viewportProxy.size.height, viewportProxy.size.width * 1.35),
                                showsLoadingIndicator: page.index == currentPageIndex,
                                isPageTapGestureEnabled: !areControlsVisible,
                                onTranslationStateChange: page.index == currentPageIndex ? onTranslationStateChange : { _ in },
                                onPreviousPage: { stepScroll(-1) },
                                onNextPage: { stepScroll(1) },
                                areControlsVisible: areControlsVisible,
                                onShowControls: onShowControls,
                                onHideControls: onHideControls
                            )
                            .frame(maxWidth: .infinity)
                            .id(page.index)
                            .background(
                                GeometryReader { geo in
                                    Color.clear
                                        .preference(key: PageHeightPreferenceKey.self, value: [page.index: max(geo.size.height, 1)])
                                        .preference(
                                            key: PageFramePreferenceKey.self,
                                            value: [page.index: geo.frame(in: .named(Self.coordinateSpaceName))]
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
                .coordinateSpace(name: Self.coordinateSpaceName)
                .background(ScrollViewAccessor(
                    onResolve: { resolvedScrollView in
                        if scrollView !== resolvedScrollView {
                            scrollView = resolvedScrollView
                        }
                    },
                    onScroll: {
                        scheduleVisiblePageUpdate(delay: 0.04)
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
                .onPreferenceChange(PageHeightPreferenceKey.self) { heights in
                    pageHeights = heights
                }
                .onPreferenceChange(PageFramePreferenceKey.self) { frames in
                    pageFrames = frames
                    scheduleVisiblePageUpdate(delay: 0.04)
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
                    let targetPageHeight = estimatedPageHeight(for: targetIndex)
                    if targetPageHeight > 1 {
                        let pageOffset = min(max(targetPageHeight * savedPageProgress, 0), max(targetPageHeight - 1, 0))
                        let targetY = min(max(minOffsetY + pageTop(for: targetIndex) + pageOffset, minOffsetY), maxOffsetY)
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

    private func estimatedPageHeight(for index: Int) -> CGFloat {
        pageHeights[index] ?? max(viewportSize.height, scrollView?.bounds.height ?? 1, 1)
    }

    private func pageTop(for index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        return (0..<index).reduce(CGFloat.zero) { partial, pageIndex in
            partial + estimatedPageHeight(for: pageIndex)
        }
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
        guard let visiblePageIndex = ReaderVisiblePageDetector.visiblePageIndex(frames: frames, viewport: viewport) else { return }
        if visiblePageIndex == 0,
           currentPageIndex > 0,
           let scrollView {
            let minOffsetY = -scrollView.adjustedContentInset.top
            let isStillBelowTop = scrollView.contentOffset.y > minOffsetY + max(visibleSize.height * 0.42, 140)
            if isStillBelowTop {
                print(
                    "MReader scroll ignored stale page-zero frame current=\(currentPageIndex) " +
                    "offsetY=\(Int(scrollView.contentOffset.y)) frames=\(frames.count)"
                )
                scheduleVisiblePageUpdate(delay: 0.06)
                return
            }
        }
        let didChangePage = currentPageIndex != visiblePageIndex
        if didChangePage {
            print("MReader scroll currentPageIndex update old=\(currentPageIndex) new=\(visiblePageIndex) frames=\(frames.count)")
            currentPageIndex = visiblePageIndex
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
            progress = CGFloat(visiblePageIndex) / CGFloat(max(pages.count - 1, 1))
        }
        let activeFrame = frames[visiblePageIndex]
        let pageProgress: CGFloat
        if let activeFrame, activeFrame.height > 1 {
            pageProgress = min(max(-activeFrame.minY / max(activeFrame.height, 1), 0), 1)
        } else {
            pageProgress = 0
        }
        let shouldNotifyProgress = didChangePage || Date().timeIntervalSince(lastScrollPositionNotifyDate) > 1.0
        if shouldNotifyProgress {
            lastScrollPositionNotifyDate = Date()
            onScrollPositionChange(visiblePageIndex, Double(progress), Double(pageProgress))
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
    let areControlsVisible: Bool
    let onShowControls: () -> Void
    let onHideControls: () -> Void

    @GestureState private var dragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let isRTL = readingDirection == .rightToLeft

            ZStack {
                if pageTurnAnimation == .curl,
                   let revealedPageIndex = revealedPageIndex(isRTL: isRTL),
                   pages.indices.contains(revealedPageIndex) {
                    pageView(index: revealedPageIndex)
                        .id("revealed-\(pages[revealedPageIndex].id)")
                }

                if pages.indices.contains(currentPageIndex) {
                    pageView(index: currentPageIndex)
                        .id(pages[currentPageIndex].id)
                        .transition(transition)
                        .modifier(
                            InteractiveBookPageCurlModifier(
                                dragOffset: pageTurnAnimation == .curl ? dragOffset : 0,
                                pageExtent: readingMode == .verticalPage ? geo.size.height : geo.size.width,
                                isVertical: readingMode == .verticalPage
                            )
                        )
                        .offset(pageOffset)
                        .animation(pageChangeAnimation, value: currentPageIndex)
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
                insertion: .modifier(
                    active: PageCurlTransitionModifier(
                        angle: pageTurnDirection >= 0 ? 68 : -68,
                        opacity: 0.08,
                        isVertical: readingMode == .verticalPage
                    ),
                    identity: PageCurlTransitionModifier(angle: 0, opacity: 1, isVertical: readingMode == .verticalPage)
                ),
                removal: .modifier(
                    active: PageCurlTransitionModifier(
                        angle: pageTurnDirection >= 0 ? -68 : 68,
                        opacity: 0.08,
                        isVertical: readingMode == .verticalPage
                    ),
                    identity: PageCurlTransitionModifier(angle: 0, opacity: 1, isVertical: readingMode == .verticalPage)
                )
            )
        case .fade:
            return .opacity.combined(with: .scale(scale: 0.975))
        }
    }

    private var pageChangeAnimation: Animation? {
        switch pageTurnAnimation {
        case .none:
            return nil
        case .slide:
            return .easeOut(duration: 0.28)
        case .fade:
            return .easeInOut(duration: 0.34)
        case .curl:
            return .spring(response: 0.44, dampingFraction: 0.84)
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
        guard pageTurnAnimation == .slide else { return .zero }
        if readingMode == .verticalPage {
            return CGSize(width: 0, height: dragOffset * 0.18)
        }
        return CGSize(width: dragOffset * 0.18, height: 0)
    }

    private func revealedPageIndex(isRTL: Bool) -> Int? {
        guard abs(dragOffset) > 2 else { return nil }
        if readingMode == .verticalPage {
            return currentPageIndex + (dragOffset < 0 ? 1 : -1)
        }
        let isForwardDrag = isRTL ? dragOffset > 0 : dragOffset < 0
        return currentPageIndex + (isForwardDrag ? 1 : -1)
    }

    private func pageView(index: Int) -> some View {
        LocalImageView(
            url: pages[index].url,
            isOCREnabled: comic.isOCREnabled,
            isAITranslationEnabled: comic.isAITranslationEnabled,
            isAutoTranslationEnabled: comic.isAutoTranslationEnabled,
            aiTranslationModeRaw: comic.aiTranslationModeRaw,
            translateRequestID: translateRequestID,
            ocrMagnifyRequestID: ocrMagnifyRequestID,
            isOCRMagnificationVisible: isOCRMagnificationVisible,
            ocrTextScale: comic.ocrTextScale,
            ocrSafeAreaInset: comic.ocrSafeAreaInset,
            ocrMinimumTextHeight: comic.ocrMinimumTextHeight,
            isRightToLeftReading: readingDirection == .rightToLeft,
            targetLanguage: targetLanguage,
            imageFitMode: imageFitMode,
            isPageTapGestureEnabled: false,
            isLongPressTranslationEnabled: areControlsVisible,
            onTranslationStateChange: onTranslationStateChange,
            onPreviousPage: previousPage,
            onNextPage: nextPage,
            areControlsVisible: areControlsVisible,
            onShowControls: onShowControls,
            onHideControls: onHideControls
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
    let areControlsVisible: Bool
    let onShowControls: () -> Void
    let onHideControls: () -> Void

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
            .animation(pageChangeAnimation, value: leftPageIndex)
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
        }
    }

    private func pageView(index: Int) -> some View {
        LocalImageView(
            url: pages[index].url,
            isOCREnabled: comic.isOCREnabled,
            isAITranslationEnabled: comic.isAITranslationEnabled,
            isAutoTranslationEnabled: comic.isAutoTranslationEnabled,
            aiTranslationModeRaw: comic.aiTranslationModeRaw,
            translateRequestID: translateRequestID,
            ocrMagnifyRequestID: ocrMagnifyRequestID,
            isOCRMagnificationVisible: isOCRMagnificationVisible,
            ocrTextScale: comic.ocrTextScale,
            ocrSafeAreaInset: comic.ocrSafeAreaInset,
            ocrMinimumTextHeight: comic.ocrMinimumTextHeight,
            isRightToLeftReading: readingDirection == .rightToLeft,
            targetLanguage: targetLanguage,
            imageFitMode: imageFitMode,
            isPageTapGestureEnabled: false,
            isLongPressTranslationEnabled: areControlsVisible,
            onTranslationStateChange: onTranslationStateChange,
            onPreviousPage: {},
            onNextPage: {},
            areControlsVisible: areControlsVisible,
            onShowControls: onShowControls,
            onHideControls: onHideControls
        )
    }

    private var doublePageTransition: AnyTransition {
        switch pageTurnAnimation {
        case .fade:
            return .opacity.combined(with: .scale(scale: 0.975))
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
                insertion: .modifier(
                    active: PageCurlTransitionModifier(angle: pageTurnDirection >= 0 ? 68 : -68, opacity: 0.08, isVertical: false),
                    identity: PageCurlTransitionModifier(angle: 0, opacity: 1, isVertical: false)
                ),
                removal: .modifier(
                    active: PageCurlTransitionModifier(angle: pageTurnDirection >= 0 ? -68 : 68, opacity: 0.08, isVertical: false),
                    identity: PageCurlTransitionModifier(angle: 0, opacity: 1, isVertical: false)
                )
            )
        case .none:
            return .identity
        }
    }

    private var pageChangeAnimation: Animation? {
        switch pageTurnAnimation {
        case .none:
            return nil
        case .slide:
            return .easeOut(duration: 0.28)
        case .fade:
            return .easeInOut(duration: 0.34)
        case .curl:
            return .spring(response: 0.44, dampingFraction: 0.84)
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

private struct PageCurlTransitionModifier: AnimatableModifier {
    var angle: Double
    var opacity: Double
    let isVertical: Bool

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(angle, opacity) }
        set {
            angle = newValue.first
            opacity = newValue.second
        }
    }

    func body(content: Content) -> some View {
        let progress = min(abs(angle) / 90, 1)
        content
            .overlay {
                LinearGradient(
                    colors: [
                        .clear,
                        .black.opacity(0.08 + progress * 0.18),
                        .white.opacity(progress * 0.22)
                    ],
                    startPoint: isVertical ? .top : (angle >= 0 ? .leading : .trailing),
                    endPoint: isVertical ? .bottom : (angle >= 0 ? .trailing : .leading)
                )
                .allowsHitTesting(false)
            }
            .rotation3DEffect(
                .degrees(angle),
                axis: isVertical ? (x: 1, y: 0, z: 0) : (x: 0, y: 1, z: 0),
                anchor: angle >= 0 ? (isVertical ? .top : .leading) : (isVertical ? .bottom : .trailing),
                perspective: 0.58
            )
            .scaleEffect(0.985 + opacity * 0.015)
            .opacity(opacity)
            .shadow(
                color: .black.opacity(0.52 * progress),
                radius: 10 + progress * 20,
                x: isVertical ? 0 : (angle >= 0 ? -14 : 14),
                y: isVertical ? (angle >= 0 ? -14 : 14) : 0
            )
    }
}

private struct InteractiveBookPageCurlModifier: ViewModifier {
    let dragOffset: CGFloat
    let pageExtent: CGFloat
    let isVertical: Bool

    func body(content: Content) -> some View {
        let extent = max(pageExtent, 1)
        let progress = min(abs(dragOffset) / extent, 1)
        let direction: CGFloat = dragOffset < 0 ? -1 : 1
        let angle = Double(direction * progress * 86)
        let anchor: UnitPoint = isVertical
            ? (direction < 0 ? .top : .bottom)
            : (direction < 0 ? .leading : .trailing)

        content
            .overlay {
                if progress > 0 {
                    ZStack {
                        Color.white.opacity(progress * 0.10)
                        LinearGradient(
                            colors: [
                                .clear,
                                .black.opacity(progress * 0.30),
                                .white.opacity(progress * 0.34),
                                .clear
                            ],
                            startPoint: foldStart(direction: direction),
                            endPoint: foldEnd(direction: direction)
                        )
                    }
                    .allowsHitTesting(false)
                }
            }
            .rotation3DEffect(
                .degrees(angle),
                axis: isVertical ? (x: 1, y: 0, z: 0) : (x: 0, y: 1, z: 0),
                anchor: anchor,
                perspective: 0.52
            )
            .offset(
                x: isVertical ? 0 : direction * extent * progress * 0.12,
                y: isVertical ? direction * extent * progress * 0.12 : 0
            )
            .shadow(
                color: .black.opacity(progress * 0.62),
                radius: 8 + progress * 26,
                x: isVertical ? 0 : -direction * (8 + progress * 18),
                y: isVertical ? -direction * (8 + progress * 18) : 0
            )
    }

    private func foldStart(direction: CGFloat) -> UnitPoint {
        if isVertical {
            return direction < 0 ? .bottom : .top
        }
        return direction < 0 ? .trailing : .leading
    }

    private func foldEnd(direction: CGFloat) -> UnitPoint {
        if isVertical {
            return direction < 0 ? .top : .bottom
        }
        return direction < 0 ? .leading : .trailing
    }
}

struct TwoFingerSwipeDownDismissView: UIViewRepresentable {
    let onProgress: (CGFloat) -> Void
    let onCancel: () -> Void
    let onSwipe: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onProgress: onProgress, onCancel: onCancel, onSwipe: onSwipe)
    }

    func makeUIView(context: Context) -> UIView {
        let view = WindowGestureInstallView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onProgress = onProgress
        context.coordinator.onCancel = onCancel
        context.coordinator.onSwipe = onSwipe
        (uiView as? WindowGestureInstallView)?.coordinator = context.coordinator
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onProgress: (CGFloat) -> Void
        var onCancel: () -> Void
        var onSwipe: () -> Void
        let recognizer = UIPanGestureRecognizer()
        private var hasTriggered = false

        init(
            onProgress: @escaping (CGFloat) -> Void,
            onCancel: @escaping () -> Void,
            onSwipe: @escaping () -> Void
        ) {
            self.onProgress = onProgress
            self.onCancel = onCancel
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
            case .changed:
                let isMostlyVertical = translation.y > 0 && abs(translation.x) < max(translation.y * 0.8, 40)
                onProgress(isMostlyVertical ? min(max(translation.y / 320, 0), 1) : 0)
                guard !hasTriggered else { return }
                let isDownward = translation.y > 110 && velocity.y > 220
                if isDownward && isMostlyVertical {
                    hasTriggered = true
                    onSwipe()
                }
            case .ended:
                guard !hasTriggered else { return }
                let isMostlyVertical = translation.y > 0 && abs(translation.x) < max(translation.y * 0.8, 40)
                let shouldDismiss = isMostlyVertical && (translation.y > 160 || velocity.y > 720)
                if shouldDismiss {
                    hasTriggered = true
                    onSwipe()
                } else {
                    onCancel()
                }
            case .cancelled, .failed:
                hasTriggered = false
                onCancel()
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
    let aiTranslationModeRaw: String
    let translateRequestID: UUID
    let ocrMagnifyRequestID: UUID
    let isOCRMagnificationVisible: Bool
    let ocrTextScale: Double
    let ocrSafeAreaInset: Double
    let ocrMinimumTextHeight: Double
    let isRightToLeftReading: Bool
    let targetLanguage: String
    let imageFitMode: ImageFitMode
    var visionViewportAspect: CGFloat? = nil
    var placeholderHeight: CGFloat? = nil
    var showsLoadingIndicator: Bool = true
    var isPageTapGestureEnabled: Bool = true
    var isLongPressTranslationEnabled: Bool = true
    var onTranslationStateChange: (Bool) -> Void = { _ in }
    let onPreviousPage: () -> Void
    let onNextPage: () -> Void
    let areControlsVisible: Bool
    let onShowControls: () -> Void
    let onHideControls: () -> Void
    @State private var uiImage: UIImage? = nil
    @State private var isLoadingImage = true
    @State private var loadFailed = false
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var pendingSingleTapWorkItem: DispatchWorkItem?
    @State private var lastDoubleTapTime = Date.distantPast
    @State private var viewportWidth: CGFloat = 0
    @State private var viewportSize: CGSize = .zero
    
    // AI 相关的状态
    @State private var textBlocks: [TextBlock] = []
    @State private var ocrTextBlocks: [TextBlock] = []
    @State private var debugTextBlocks: [TextBlock] = []
    @State private var recognizedBlocksCache: [TextBlock]?
    @State private var recognizedBlocksCacheKey: String?
    @State private var isTranslating = false
    @State private var isRecognizingOCR = false
    @State private var translationErrorMessage: String?
    @State private var translationTask: Task<Void, Never>?
    @AppStorage("openai_api_key") private var apiKey = ""
    @AppStorage("openai_base_url") private var baseURL = "https://api.openai.com/v1"
    @AppStorage("openai_model") private var modelName = "gpt-4o-mini"
    @AppStorage("ai_model_pool") private var modelPoolText = ""
    @AppStorage("ai_model_pool_enabled") private var isModelPoolEnabled = true
    @AppStorage("translation_prompt_template") private var translationPromptTemplate = AITranslator.defaultTranslationPromptTemplate
    @AppStorage("vision_translation_prompt_template") private var visionTranslationPromptTemplate = AITranslator.defaultVisionTranslationPromptTemplate
    @AppStorage("ocr_show_debug_boxes") private var ocrShowDebugBoxes = false
    @AppStorage("translation_color_style") private var translationColorStyleRaw = TranslationColorStyle.contrast.rawValue

    private var aiTranslationMode: AITranslationMode {
        AITranslationMode(rawValue: aiTranslationModeRaw) ?? .ocr
    }

    private var canTranslate: Bool {
        isAITranslationEnabled && (aiTranslationMode == .vision || isOCREnabled)
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
        .overlay(alignment: .bottom) {
            if let translationErrorMessage {
                Text(translationErrorMessage)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.62), in: Capsule())
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
        .frame(height: reservedDisplayHeight)
        .frame(maxWidth: .infinity, minHeight: imageFitMode == .fitWidth ? nil : 0, maxHeight: imageFitMode == .fitWidth ? nil : .infinity)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        viewportWidth = proxy.size.width
                        viewportSize = proxy.size
                    }
                    .onChange(of: proxy.size) { _, newValue in
                        viewportWidth = newValue.width
                        viewportSize = newValue
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
                    segments: item.blocks.compactMap {
                        let value = ($0.translation ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        return value.isEmpty ? nil : value
                    },
                    fontSize: translationFontSize(for: item.blocks, in: item.rect),
                    style: TranslationColorStyle(rawValue: translationColorStyleRaw) ?? .contrast
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
            ForEach(ocrLayoutItems(in: size)) { item in
                let text = item.blocks.map(\.text).joined(separator: "\n\n")
                Text(text)
                    .font(.system(size: uniformOCRFontSize, weight: .semibold))
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.92))
                    .foregroundColor(.black)
                    .cornerRadius(6)
                    .frame(width: item.rect.size.width)
                    .position(x: item.rect.midX, y: item.rect.midY)
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
        let maxWidth = max(96, min(size.width - safeMargin * 2, isOCRMagnificationVisible ? 260 : 230))
        let widthMultiplier: CGFloat = isOCRMagnificationVisible ? 1.32 : 1.08
        let translatedText = (block.translation ?? block.text).trimmingCharacters(in: .whitespacesAndNewlines)
        let characterCount = max(translatedText.count, 1)
        let contentDrivenWidth = min(max(CGFloat(sqrt(Double(characterCount))) * 25, 84), maxWidth)
        let width = min(max(original.width * widthMultiplier, contentDrivenWidth), maxWidth)
        let estimatedCharactersPerLine = max(Int((width - 12) / 13), 1)
        let estimatedLineCount = max(1, Int(ceil(Double(characterCount) / Double(estimatedCharactersPerLine))))
        let contentDrivenHeight = CGFloat(estimatedLineCount) * 21 + 10
        let maxHeight = max(56, min(size.height * 0.38, 168))
        let height = min(max(original.height * 1.2, contentDrivenHeight, 34), maxHeight)
        let x = min(max(original.midX, safeMargin + width / 2), size.width - safeMargin - width / 2)
        let y = min(max(original.midY, safeMargin + height / 2), size.height - safeMargin - height / 2)
        return CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height)
    }

    private func translationLayoutItems(in size: CGSize) -> [TranslationLayoutItem] {
        let initialItems = visibleTranslationBlocks.map { block in
            TranslationLayoutItem(blocks: [block], rect: translationBubbleRect(for: block, in: size))
        }
        var denseGroups: [TranslationLayoutItem] = []
        for item in initialItems {
            if let index = denseGroups.firstIndex(where: { existing in
                existing.rect.insetBy(dx: -8, dy: -8).intersects(item.rect) &&
                existing.blocks.count < 4
            }) {
                let mergedBlocks = denseGroups[index].blocks + item.blocks
                var mergedRect = denseGroups[index].rect.union(item.rect)
                mergedRect.size.height = min(max(mergedRect.height, CGFloat(mergedBlocks.count) * 30), 150)
                mergedRect.size.width = min(max(mergedRect.width, 96), max(size.width - 24, 96))
                denseGroups[index] = TranslationLayoutItem(blocks: mergedBlocks, rect: clampedTranslationRect(mergedRect, safeMargin: 12, in: size))
            } else {
                denseGroups.append(item)
            }
        }

        var occupiedRects: [CGRect] = []
        var items: [TranslationLayoutItem] = []
        for item in denseGroups {
            let original = item.rect
            let sourceRect = item.blocks.reduce(CGRect.null) { $0.union($1.boundingBox) }
            let anchor = CGPoint(
                x: sourceRect.midX * size.width,
                y: sourceRect.midY * size.height
            )
            let rect = nonOverlappingTranslationRect(original, anchor: anchor, occupiedRects: occupiedRects, in: size)
            occupiedRects.append(rect.insetBy(dx: -4, dy: -4))
            items.append(TranslationLayoutItem(blocks: item.blocks, rect: rect))
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
        let characterCount = max(block.text.count, 1)
        let charactersPerLine = max(Int(width / max(uniformOCRFontSize * 0.72, 1)), 1)
        let lineCount = max(1, Int(ceil(Double(characterCount) / Double(charactersPerLine))))
        let height = min(max(CGFloat(lineCount) * uniformOCRFontSize * 1.3 + 8, 34), 140)
        let x = min(max(original.midX, safeMargin + width / 2), size.width - safeMargin - width / 2)
        let y = min(max(original.midY, safeMargin + height / 2), size.height - safeMargin - height / 2)
        return CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height)
    }

    private func ocrLayoutItems(in size: CGSize) -> [TranslationLayoutItem] {
        var occupiedRects: [CGRect] = []
        var items: [TranslationLayoutItem] = []
        for block in ocrTextBlocks {
            let original = ocrBubbleRect(for: block, in: size)
            let anchor = CGPoint(x: block.boundingBox.midX * size.width, y: block.boundingBox.midY * size.height)
            let rect = nonOverlappingTranslationRect(original, anchor: anchor, occupiedRects: occupiedRects, in: size)
            occupiedRects.append(rect.insetBy(dx: -4, dy: -4))
            items.append(TranslationLayoutItem(blocks: [block], rect: rect))
        }
        return items
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
                translationErrorMessage = nil
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
            translationErrorMessage = nil
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

    private var tapPageGesture: some Gesture {
        SpatialTapGesture(count: 1, coordinateSpace: .local)
            .onEnded { value in
                guard isPageTapGestureEnabled else { return }
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
                    }
                }
                pendingSingleTapWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
            }
    }

    private var longPressTranslationGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.55, maximumDistance: 18)
            .onEnded { _ in
                guard isLongPressTranslationEnabled, canTranslate, scale <= 1.05 else { return }
                pendingSingleTapWorkItem?.cancel()
                pendingSingleTapWorkItem = nil
                HapticManager.shared.play(.medium)
                startTranslation()
            }
    }

    private var uniformOCRFontSize: CGFloat {
        11 + CGFloat(normalizedOCRScale) * 8
    }

    private func translationFontSize(for blocks: [TextBlock], in bubbleRect: CGRect) -> CGFloat {
        let segments = blocks.compactMap { block -> String? in
            let text = (block.translation ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        guard !segments.isEmpty else { return 12 }
        let availableWidth = max(bubbleRect.width - 14, 24)
        let availableHeight = max(bubbleRect.height - 10, 20)
        let requestedMaximum: CGFloat = isOCRMagnificationVisible ? 28 : 25
        var lower: CGFloat = 11
        var upper = requestedMaximum
        for _ in 0..<8 {
            let candidate = (lower + upper) / 2
            if translationTextFits(
                segments,
                fontSize: candidate,
                width: availableWidth,
                height: availableHeight
            ) {
                lower = candidate
            } else {
                upper = candidate
            }
        }
        return min(max(lower, 11), requestedMaximum)
    }

    private func translationTextFits(_ segments: [String], fontSize: CGFloat, width: CGFloat, height: CGFloat) -> Bool {
        let charactersPerLine = max(Int(width / max(fontSize * 0.86, 1)), 1)
        let lines = segments.reduce(0) { partial, segment in
            let explicitLines = segment.split(separator: "\n", omittingEmptySubsequences: false)
            let segmentLines = explicitLines.reduce(0) { lineTotal, line in
                lineTotal + max(1, Int(ceil(Double(max(line.count, 1)) / Double(charactersPerLine))))
            }
            return partial + segmentLines
        }
        let segmentSpacing = CGFloat(max(segments.count - 1, 0)) * 7
        let requiredHeight = CGFloat(max(lines, 1)) * fontSize * 1.24 + segmentSpacing
        return requiredHeight <= height
    }

    private var ocrTextSizeFactor: CGFloat {
        0.92 + CGFloat(normalizedOCRScale) * 0.44
    }

    private var normalizedOCRScale: Double {
        if ocrTextScale > 1 {
            return min(max((ocrTextScale - 0.8) / 2.4, 0), 1)
        }
        return min(max(ocrTextScale, 0), 1)
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
        translationErrorMessage = nil
        isTranslating = true
        onTranslationStateChange(true)
        
        translationTask = Task {
            do {
                switch aiTranslationMode {
                case .ocr:
                    try await startOCRTextTranslation(image: image, pageURL: pageURL)
                case .vision:
                    try await startVisionImageTranslation(image: image, pageURL: pageURL)
                }
            } catch {
                if !Task.isCancelled {
                    print("翻译异常: \(error)")
                    await MainActor.run {
                        self.translationErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        HapticManager.shared.play(.error)
                    }
                }
            }
            await MainActor.run {
                if !Task.isCancelled && self.translationErrorMessage == nil {
                    HapticManager.shared.play(.success)
                }
                self.isTranslating = false
                self.onTranslationStateChange(false)
                self.translationTask = nil
            }
        }
    }

    private func startOCRTextTranslation(image: UIImage, pageURL: URL) async throws {
        let recognizedBlocks = try await recognizedTextBlocks(for: image)
        try Task.checkCancellation()
        let blocks = preparedTextBlocks(from: recognizedBlocks)
        await MainActor.run { self.textBlocks = blocks }
        guard !blocks.isEmpty else { return }

        let requestAPIKey = apiKey
        let requestBaseURL = baseURL
        let requestModelName = modelName
        let requestModelPoolText = modelPoolText
        let requestIsModelPoolEnabled = isModelPoolEnabled
        let requestTargetLanguage = targetLanguage
        let requestPromptTemplate = translationPromptTemplate
        let maximumConcurrentRequests = min(3, blocks.count)

        await withTaskGroup(of: (Int, String?, String?).self) { group in
            var nextIndex = 0

            func submit(_ index: Int) {
                let block = blocks[index]
                group.addTask {
                    do {
                        let translatedText = try await AITranslator.translate(
                            text: block.text,
                            ocrMetadata: AITranslator.ocrMetadata(for: block),
                            apiKey: requestAPIKey,
                            baseURL: requestBaseURL,
                            model: requestModelName,
                            modelPoolText: requestModelPoolText,
                            isModelPoolEnabled: requestIsModelPoolEnabled,
                            targetLanguage: requestTargetLanguage,
                            promptTemplate: requestPromptTemplate
                        )
                        return (index, translatedText, nil)
                    } catch {
                        let message = (error as? LocalizedError)?.errorDescription
                            ?? error.localizedDescription
                        return (index, nil, message)
                    }
                }
            }

            while nextIndex < maximumConcurrentRequests {
                submit(nextIndex)
                nextIndex += 1
            }

            while let (index, translatedText, errorMessage) = await group.next() {
                if Task.isCancelled {
                    group.cancelAll()
                    return
                }
                await MainActor.run {
                    guard self.url == pageURL, textBlocks.indices.contains(index) else { return }
                    if let translatedText {
                        textBlocks[index].translation = translatedText
                    } else if let errorMessage {
                        translationErrorMessage = errorMessage
                    }
                }
                if nextIndex < blocks.count {
                    submit(nextIndex)
                    nextIndex += 1
                }
            }
        }
        try Task.checkCancellation()
    }

    private func startVisionImageTranslation(image: UIImage, pageURL: URL) async throws {
        let blocks = try await AITranslator.translateVisionPage(
            image: image,
            apiKey: apiKey,
            baseURL: baseURL,
            model: modelName,
            modelPoolText: modelPoolText,
            isModelPoolEnabled: isModelPoolEnabled,
            targetLanguage: targetLanguage,
            promptTemplate: visionTranslationPromptTemplate,
            isRightToLeft: isRightToLeftReading,
            viewportAspect: visionViewportAspect
                ?? max(viewportSize.height / max(viewportSize.width, 1), 1.25)
        )
        try Task.checkCancellation()
        await MainActor.run {
            guard self.url == pageURL else { return }
            self.textBlocks = blocks
        }
    }

    private func recognizedTextBlocks(for image: UIImage) async throws -> [TextBlock] {
        let key = "\(url.absoluteString)#rtl=\(isRightToLeftReading)#min=\(ocrMinimumTextHeight)"
        if recognizedBlocksCacheKey == key, let recognizedBlocksCache {
            return recognizedBlocksCache
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
    let blocks: [TextBlock]
    let rect: CGRect

    var id: UUID { blocks.first?.id ?? UUID() }
}

private enum TranslationColorStyle: String, CaseIterable {
    case contrast
    case coolWarm
    case jewel

    var title: String {
        switch self {
        case .contrast: return "高对比"
        case .coolWarm: return "冷暖分明"
        case .jewel: return "宝石色"
        }
    }

    var palettes: [[Color]] {
        switch self {
        case .contrast:
            return [
                [Color(red: 0.02, green: 0.22, blue: 0.72), Color(red: 0.52, green: 0.05, blue: 0.58)],
                [Color(red: 0.0, green: 0.42, blue: 0.48), Color(red: 0.72, green: 0.16, blue: 0.18)],
                [Color(red: 0.18, green: 0.15, blue: 0.62), Color(red: 0.65, green: 0.22, blue: 0.04)]
            ]
        case .coolWarm:
            return [
                [Color(red: 0.0, green: 0.32, blue: 0.82), Color(red: 0.0, green: 0.62, blue: 0.68)],
                [Color(red: 0.86, green: 0.10, blue: 0.28), Color(red: 0.76, green: 0.34, blue: 0.02)],
                [Color(red: 0.30, green: 0.12, blue: 0.72), Color(red: 0.74, green: 0.12, blue: 0.52)]
            ]
        case .jewel:
            return [
                [Color(red: 0.05, green: 0.30, blue: 0.66), Color(red: 0.36, green: 0.08, blue: 0.54)],
                [Color(red: 0.0, green: 0.46, blue: 0.36), Color(red: 0.64, green: 0.08, blue: 0.18)],
                [Color(red: 0.12, green: 0.20, blue: 0.58), Color(red: 0.58, green: 0.28, blue: 0.0)]
            ]
        }
    }
}

private struct ColorfulTranslatedText: View {
    let segments: [String]
    let fontSize: CGFloat
    let style: TranslationColorStyle

    var body: some View {
        VStack(spacing: segments.count > 1 ? 7 : 0) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                Text(segment)
                    .font(.system(size: fontSize, weight: .bold))
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(colorGradient(index: index))
                    .shadow(color: .white.opacity(0.78), radius: 0.7)
                    .shadow(color: .black.opacity(0.62), radius: 1.2, y: 1)
            }
        }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.98),
                                Color(red: 0.92, green: 0.96, blue: 1.0).opacity(0.97),
                                Color(red: 1.0, green: 0.93, blue: 0.97).opacity(0.97)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(colorGradient(index: 0).opacity(0.9), lineWidth: 1)
                    }
            }
    }

    private func colorGradient(index: Int) -> LinearGradient {
        let palettes = style.palettes
        let colors = palettes[index % palettes.count]
        return LinearGradient(
            colors: colors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static let palette: [Color] = [
        Color(red: 0.10, green: 0.38, blue: 0.82),
        Color(red: 0.32, green: 0.22, blue: 0.78),
        Color(red: 0.55, green: 0.18, blue: 0.72),
        Color(red: 0.75, green: 0.20, blue: 0.55),
        Color(red: 0.12, green: 0.58, blue: 0.65),
        Color(red: 0.18, green: 0.50, blue: 0.78),
        Color(red: 0.72, green: 0.38, blue: 0.18).opacity(0.7)
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
                let outerCornerRadius = (screenCornerRadius > 0 ? screenCornerRadius : cornerRadius) + 5
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
