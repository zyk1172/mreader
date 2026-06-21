import SwiftUI
import ImageIO
import UIKit

struct ReaderContainerView: View {
    @State private var comic: ComicBook
    let onProgressChange: (Int) -> Void
    let onComicUpdate: (ComicBook) -> Void
    @State private var manager = ComicManager()
    @State private var isLoaded = false
    @State private var loadFailed = false

    init(comic: ComicBook, onProgressChange: @escaping (Int) -> Void, onComicUpdate: @escaping (ComicBook) -> Void) {
        _comic = State(initialValue: comic)
        self.onProgressChange = onProgressChange
        self.onComicUpdate = onComicUpdate
    }
    
    var body: some View {
        Group {
            if isLoaded {
                ReaderView(manager: manager, comic: comic, onProgressChange: onProgressChange) { updatedComic in
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
                let bookmarkData = comic.bookmarkData
                let result = await Task.detached(priority: .userInitiated) {
                    ComicManager.loadPages(bookmarkData: bookmarkData)
                }.value
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

    private let cache = NSCache<NSURL, UIImage>()
    private var loadingURLs: Set<URL> = []

    private init() {
        cache.countLimit = 10
        cache.totalCostLimit = 130 * 1024 * 1024
    }

    func cachedImage(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func loadImage(for url: URL) async -> UIImage? {
        if let cached = cachedImage(for: url) {
            return cached
        }
        let image = await Task.detached(priority: .userInitiated) {
            decodeReaderImage(from: url)
        }.value
        if let image {
            cache.setObject(image, forKey: url as NSURL, cost: image.cacheCost)
        }
        return image
    }

    func preload(_ urls: [URL]) {
        let availableSlots = max(0, 2 - loadingURLs.count)
        guard availableSlots > 0 else { return }
        let candidates = urls
            .filter { cachedImage(for: $0) == nil && !loadingURLs.contains($0) }
            .prefix(availableSlots)

        for url in candidates {
            loadingURLs.insert(url)
            Task.detached(priority: .utility) { [weak self] in
                let image = decodeReaderImage(from: url)
                await MainActor.run {
                    guard let self else { return }
                    self.loadingURLs.remove(url)
                    if let image {
                        self.cache.setObject(image, forKey: url as NSURL, cost: image.cacheCost)
                    }
                }
            }
        }
    }

    private static func decodedImage(from url: URL) -> UIImage? {
        decodeReaderImage(from: url)
    }
}

private extension UIImage {
    var cacheCost: Int {
        guard let cgImage else { return 1 }
        return cgImage.bytesPerRow * cgImage.height
    }
}

private func decodeReaderImage(from url: URL) -> UIImage? {
    autoreleasepool {
        let source: CGImageSource?
        if ComicManager.isArchivePageURL(url), let data = ComicManager.imageData(forArchivePageURL: url) {
            source = CGImageSourceCreateWithData(data as CFData, nil)
        } else {
            source = CGImageSourceCreateWithURL(url as CFURL, nil)
        }
        guard let source else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldCache: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096.0
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
    let onProgressChange: (Int) -> Void
    let onComicUpdate: (ComicBook) -> Void
    @Environment(\.dismiss) private var dismiss
    
    @AppStorage("translation_target_language") private var translationTargetLanguage = "中文"
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

    init(manager: ComicManager, comic: ComicBook, onProgressChange: @escaping (Int) -> Void, onComicUpdate: @escaping (ComicBook) -> Void) {
        self.manager = manager
        self.onProgressChange = onProgressChange
        self.onComicUpdate = onComicUpdate
        _comic = State(initialValue: comic)
        let maxIndex = max(0, manager.pages.count - 1)
        _currentPageIndex = State(initialValue: min(max(comic.currentPageIndex, 0), maxIndex))
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
                    onToggleControls: toggleControls
                )
                .ignoresSafeArea()
            }

            TwoFingerSwipeDownDismissView {
                dismiss()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()

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
            preloadPages(around: currentPageIndex)
        }
        .onDisappear { autoHideControlsWorkItem?.cancel() }
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
            comic.currentPageIndex = clampedValue
            comic.lastReadAt = Date()
            onComicUpdate(comic)
            onProgressChange(clampedValue)
            preloadPages(around: clampedValue)
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
                        Text("文字放大倍数")
                        Slider(value: Binding(
                            get: { comic.ocrTextScale },
                            set: { newValue in updateComic { $0.ocrTextScale = newValue } }
                        ), in: 1.2...4.0, step: 0.1)
                        Text(String(format: "%.1fx", comic.ocrTextScale))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
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

                    Picker("翻译为", selection: $translationTargetLanguage) {
                        Text("中文").tag("中文")
                        Text("英文").tag("英文")
                        Text("日文").tag("日文")
                        Text("韩文").tag("韩文")
                        Text("简体中文").tag("简体中文")
                        Text("繁体中文").tag("繁体中文")
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

    private func jumpToPage() {
        let pageNumber = Int(jumpPageText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        guard pageNumber > 0 else {
            HapticManager.shared.play(.warning)
            return
        }
        let targetIndex = min(max(pageNumber - 1, 0), max(0, manager.pages.count - 1))
        HapticManager.shared.play(.medium)
        currentPageIndex = targetIndex
        scrollJumpRequestID = UUID()
        jumpPageText = ""
        showComicSettings = false
    }

    private func preloadPages(around index: Int) {
        guard !manager.pages.isEmpty else { return }
        let preferredIndices = [index, index + 1, index + 2, index - 1]
        let urls = preferredIndices.compactMap { pageIndex -> URL? in
            guard manager.pages.indices.contains(pageIndex) else { return nil }
            return manager.pages[pageIndex].url
        }
        ReaderImageCache.shared.preload(urls)
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

private struct ScrollViewAccessor: UIViewRepresentable {
    let onResolve: (UIScrollView) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        DispatchQueue.main.async {
            if let scrollView = view.enclosingScrollView {
                onResolve(scrollView)
            }
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            if let scrollView = uiView.enclosingScrollView {
                onResolve(scrollView)
            }
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
    let onToggleControls: () -> Void

    @State private var scrollView: UIScrollView?
    @State private var pageFrames: [Int: CGRect] = [:]
    @State private var didRestorePosition = false
    @State private var lastStepTime = Date.distantPast
    @State private var visiblePageUpdateWorkItem: DispatchWorkItem?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(pages) { page in
                        LocalImageView(
                            url: page.url,
                            isOCREnabled: comic.isOCREnabled,
                            isAITranslationEnabled: comic.isAITranslationEnabled,
                            isAutoTranslationEnabled: comic.isAutoTranslationEnabled,
                            translateRequestID: translateRequestID,
                            ocrMagnifyRequestID: ocrMagnifyRequestID,
                            isOCRMagnificationVisible: isOCRMagnificationVisible && page.index == currentPageIndex,
                            ocrTextScale: comic.ocrTextScale,
                            ocrSafeAreaInset: comic.ocrSafeAreaInset,
                            isRightToLeftReading: comic.readingDirectionRaw == ReadingDirection.rightToLeft.rawValue,
                            targetLanguage: targetLanguage,
                            imageFitMode: .fitWidth,
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
                                    value: [page.index: geo.frame(in: .named("continuousScroll"))]
                                )
                            }
                        )
                    }
                }
            }
            .coordinateSpace(name: "continuousScroll")
            .background(ScrollViewAccessor { resolvedScrollView in
                if scrollView !== resolvedScrollView {
                    scrollView = resolvedScrollView
                }
            })
            .onAppear {
                restoreScrollPosition(proxy, animated: false)
            }
            .onChange(of: readingMode) { _, _ in
                restoreScrollPosition(proxy, animated: false)
            }
            .onChange(of: scrollJumpRequestID) { _, _ in
                restoreScrollPosition(proxy, animated: true)
            }
            .onPreferenceChange(PageFramePreferenceKey.self) { frames in
                pageFrames = frames
                scheduleVisiblePageUpdate()
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
        DispatchQueue.main.async {
            let animation = animated ? Animation.easeInOut(duration: 0.3) : nil
            withAnimation(animation) {
                proxy.scrollTo(targetIndex, anchor: .top)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
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
        guard didRestorePosition, let scrollView else { return }
        let viewport = CGRect(origin: .zero, size: scrollView.bounds.size)
        let visible = pageFrames.compactMap { index, frame -> (Int, CGFloat)? in
            let overlap = frame.intersection(viewport)
            guard !overlap.isNull, overlap.height > 1 else { return nil }
            return (index, overlap.height)
        }
        guard let best = visible.max(by: { $0.1 < $1.1 }) else { return }
        if currentPageIndex != best.0 {
            currentPageIndex = best.0
        }
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
            isRightToLeftReading: readingDirection == .rightToLeft,
            targetLanguage: targetLanguage,
            imageFitMode: imageFitMode,
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
            isRightToLeftReading: readingDirection == .rightToLeft,
            targetLanguage: targetLanguage,
            imageFitMode: imageFitMode,
            onPreviousPage: previousSpread,
            onNextPage: nextSpread,
            onToggleControls: onToggleControls
        )
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
    let isRightToLeftReading: Bool
    let targetLanguage: String
    let imageFitMode: ImageFitMode
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
    @State private var isTranslating = false
    @State private var isRecognizingOCR = false
    @AppStorage("openai_api_key") private var apiKey = ""
    @AppStorage("openai_base_url") private var baseURL = "https://api.openai.com/v1"
    @AppStorage("openai_model") private var modelName = "gpt-4o-mini"
    @AppStorage("translation_prompt_template") private var translationPromptTemplate = AITranslator.defaultTranslationPromptTemplate

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
                            }
                        }
                    )
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(zoomGesture)
                    .simultaneousGesture(doubleTapGesture)
                    .simultaneousGesture(tapPageGesture)
                
            } else if isLoadingImage {
                ProgressView().tint(.white).controlSize(.large)
            } else if loadFailed {
                ContentUnavailableView("图片加载失败", systemImage: "exclamationmark.triangle", description: Text(url.lastPathComponent))
                    .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    @ViewBuilder
    private func translationOverlay(in size: CGSize) -> some View {
        if canTranslate {
            ForEach(textBlocks) { block in
                if let translation = block.translation {
                    let rect = translationBubbleRect(for: block, in: size)
                    Text(translation)
                        .font(.system(size: translationFontSize(for: block, in: size), weight: .medium))
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.94))
                        .foregroundColor(.black)
                        .cornerRadius(8)
                        .shadow(color: .black.opacity(0.16), radius: 3, x: 0, y: 1)
                        .frame(width: rect.width)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
        }
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

    private func overlayRect(for block: TextBlock, in size: CGSize, scaleMultiplier: CGFloat) -> CGRect {
        let width = max(block.boundingBox.width * size.width * scaleMultiplier, 44)
        let height = max(block.boundingBox.height * size.height * scaleMultiplier, 24)
        let x = block.boundingBox.midX * size.width
        let y = block.boundingBox.midY * size.height
        return CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height)
    }

    private func translationBubbleRect(for block: TextBlock, in size: CGSize) -> CGRect {
        let original = overlayRect(for: block, in: size, scaleMultiplier: 1)
        let safeMargin: CGFloat = 12
        let maxWidth = max(120, min(size.width - safeMargin * 2, 280))
        let width = min(max(original.width * 1.75, 96), maxWidth)
        let x = min(max(original.midX, safeMargin + width / 2), size.width - safeMargin - width / 2)
        let y = min(max(original.midY, safeMargin + 18), size.height - safeMargin - 18)
        return CGRect(x: x - width / 2, y: y - 18, width: width, height: 36)
    }

    private func ocrBubbleRect(for block: TextBlock, in size: CGSize) -> CGRect {
        let original = overlayRect(for: block, in: size, scaleMultiplier: CGFloat(ocrTextScale))
        let safeMargin: CGFloat = 12
        let maxWidth = max(100, size.width - safeMargin * 2)
        let width = min(max(original.width, 72), maxWidth)
        let x = min(max(original.midX, safeMargin + width / 2), size.width - safeMargin - width / 2)
        let y = min(max(original.midY, safeMargin + 18), size.height - safeMargin - 18)
        return CGRect(x: x - width / 2, y: y - 18, width: width, height: 36)
    }

    private func loadImage() async {
        if let cachedImage = ReaderImageCache.shared.cachedImage(for: url) {
            await MainActor.run {
                isLoadingImage = false
                loadFailed = false
                uiImage = cachedImage
                textBlocks.removeAll()
                ocrTextBlocks.removeAll()
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
            scale = 1
            lastScale = 1
            offset = .zero
            pendingSingleTapWorkItem?.cancel()
            pendingSingleTapWorkItem = nil
        }

        let loadedImage = await ReaderImageCache.shared.loadImage(for: url)
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

    private func ocrFontSize(for block: TextBlock, in size: CGSize) -> CGFloat {
        let blockHeight = max(block.boundingBox.height * size.height, 10)
        let scaled = blockHeight * CGFloat(ocrTextScale) * 0.78
        return min(max(scaled, 15), 42)
    }

    private func translationFontSize(for block: TextBlock, in size: CGSize) -> CGFloat {
        let blockHeight = max(block.boundingBox.height * size.height, 10)
        return min(max(blockHeight * 0.58, 13), 18)
    }

    private func preparedTextBlocks(from blocks: [TextBlock]) -> [TextBlock] {
        let filtered = AITranslator.filteredMangaTextBlocks(
            blocks,
            safeAreaInset: ocrSafeAreaInset,
            isRightToLeft: isRightToLeftReading
        )
        return AITranslator.groupedMangaTextBlocks(filtered, isRightToLeft: isRightToLeftReading)
    }

    private func startOCRMagnification() {
        guard isOCREnabled, isOCRMagnificationVisible, !isRecognizingOCR, let image = uiImage else { return }
        isRecognizingOCR = true

        Task {
            do {
                let recognizedBlocks = try await AITranslator.recognizeText(in: image, isRightToLeft: isRightToLeftReading)
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
        guard canTranslate, !isTranslating, let image = uiImage else { return }
        isTranslating = true
        
        Task {
            do {
                // 步骤一：本地执行 Apple Vision OCR
                let recognizedBlocks = try await AITranslator.recognizeText(in: image, isRightToLeft: isRightToLeftReading)
                let blocks = preparedTextBlocks(from: recognizedBlocks)
                await MainActor.run { self.textBlocks = blocks } // 先显示个框（可选）
                
                // 步骤二：并发向大模型请求翻译 (由于有多个气泡，使用并发组加速)
                await withTaskGroup(of: (Int, String).self) { group in
	                    for i in 0..<blocks.count {
	                        let text = blocks[i].text
	                        let key = apiKey
	                        let base = baseURL
	                        let model = modelName
                            let target = targetLanguage
                            let prompt = translationPromptTemplate
	                        group.addTask {
                                let translated = try? await AITranslator.translate(text: text, apiKey: key, baseURL: base, model: model, targetLanguage: target, promptTemplate: prompt)
	                            return (i, translated ?? "翻译失败")
	                        }
                    }
                    
                    for await (index, translatedText) in group {
                        await MainActor.run {
                            guard textBlocks.indices.contains(index) else { return }
                            textBlocks[index].translation = translatedText
                        }
                    }
                }
            } catch {
                print("翻译异常: \(error)")
            }
            await MainActor.run { self.isTranslating = false }
        }
    }
}
