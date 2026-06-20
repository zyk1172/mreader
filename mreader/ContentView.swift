import SwiftUI
import UniformTypeIdentifiers
import UIKit
import ImageIO

private extension View {
    func eraseToAnyView() -> AnyView {
        AnyView(self)
    }
}

enum ShelfDisplayMode: String, CaseIterable {
    case grid
    case list
}

enum ShelfFilter: String, CaseIterable {
    case all
    case inProgress
    case locked
}

enum MainShelfPage: String, CaseIterable {
    case continueReading
    case library
}

enum ImportPickerMode {
    case files
    case folder
}

nonisolated struct MReaderSettingsBackup: Codable {
    var version = 1
    var openAIAPIKey: String
    var openAIBaseURL: String
    var openAIModel: String
    var translationTargetLanguage: String
    var translationPromptTemplate: String?
    var isHapticFeedbackEnabled: Bool
}

nonisolated struct SettingsBackupDocument: FileDocument, Identifiable {
    static var readableContentTypes: [UTType] { [.json] }

    var id = UUID()
    var backup: MReaderSettingsBackup

    init(backup: MReaderSettingsBackup) {
        self.backup = backup
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        backup = try JSONDecoder().decode(MReaderSettingsBackup.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return FileWrapper(regularFileWithContents: try encoder.encode(backup))
    }
}

struct ContentView: View {
    @StateObject private var library = ComicLibraryStore()
    @StateObject private var webServer = LocalWebServer()

    @State private var isImporting = false
    @State private var isFolderImporting = false
    @State private var isLibraryRootPicking = false
    @State private var isRestoringSettings = false
    @State private var isExportingSettings = false
    @State private var hasLibraryRoot = ComicManager.hasSelectedLibraryRoot()
    @State private var importPickerMode = ImportPickerMode.files
    @State private var isProcessing = false // 控制解压时的加载动画
    @State private var showSettings = false
    @State private var showStorageManager = false
    @State private var showActivity = false
    @State private var showNewSeriesAlert = false
    @State private var newSeriesName = ""
    @State private var isSelectionMode = false
    @State private var selectedComicIDs: Set<UUID> = []
    @State private var selectedSeriesIDs: Set<UUID> = []
    @State private var selectedPage = MainShelfPage.continueReading
    @State private var shelfDisplayMode = ShelfDisplayMode.grid
    @State private var shelfFilter = ShelfFilter.all
    @State private var importError: String?
    @State private var settingsBackupDocument: SettingsBackupDocument?
    @State private var renamingComic: ComicBook?
    @State private var renameTitle = ""
    @State private var importingSeriesID: UUID?
    @AppStorage("openai_api_key") private var apiKey = ""
    @AppStorage("openai_base_url") private var baseURL = "https://api.openai.com/v1"
    @AppStorage("openai_model") private var modelName = "gpt-4o-mini"
    @AppStorage("translation_target_language") private var translationTargetLanguage = "中文"
    @AppStorage("translation_prompt_template") private var translationPromptTemplate = AITranslator.defaultTranslationPromptTemplate
    @AppStorage(HapticSettings.isEnabledKey) private var isHapticFeedbackEnabled = true
    @Namespace private var seriesAnimationNamespace

    @State private var renamingSeries: ComicSeries?

    private var hasAnyLibrarySource: Bool {
        hasLibraryRoot
    }

    private var visibleComics: [ComicBook] {
        switch shelfFilter {
        case .all:
            return library.comics
        case .inProgress:
            return library.comics.filter { $0.currentPageIndex > 0 }
        case .locked:
            return library.comics.filter(\.isLocked)
        }
    }

    var body: some View {
        NavigationStack {
            shelfRootContent
            .navigationTitle(selectedPage == .continueReading ? "立即阅读" : "MReader 书架")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("页面", selection: $selectedPage) {
                        Text("立即阅读").tag(MainShelfPage.continueReading)
                        Text("书架").tag(MainShelfPage.library)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 190)
                }
                // 使用 ToolbarItemGroup 解决图标重复和排版混乱的问题
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    shelfActionMenu
                }
            }
            .onChange(of: selectedPage) { _, _ in
                HapticManager.shared.play(.light)
            }
            .sheet(isPresented: $showSettings) {
                settingsView
            }
            .eraseToAnyView()
            // 加载动画覆盖层
            .overlay {
                processingOverlay
            }
            .safeAreaInset(edge: .bottom) {
                if isSelectionMode {
                    selectionActionBar
                }
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: allowedImportTypes,
                allowsMultipleSelection: importPickerMode == .files
            ) { result in
                if case .success(let urls) = result {
                    importComicsOrFolder(from: urls, seriesID: importingSeriesID)
                }
                importingSeriesID = nil
            }
            .fileImporter(
                isPresented: $isRestoringSettings,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                restoreSettingsBackup(from: result)
            }
            .eraseToAnyView()
            .fileExporter(
                isPresented: $isExportingSettings,
                documents: settingsBackupDocument.map { [$0] } ?? [],
                contentType: .json
            ) { result in
                switch result {
                case .success:
                    HapticManager.shared.play(.success)
                case .failure:
                    HapticManager.shared.play(.error)
                    importError = "设置备份导出失败。"
                }
            }
            .sheet(isPresented: $isFolderImporting) {
                FolderPicker { url in
                    importComicsOrFolder(from: [url], seriesID: importingSeriesID)
                    importingSeriesID = nil
                } onCancel: {
                    importingSeriesID = nil
                }
            }
            .sheet(isPresented: $isLibraryRootPicking) {
                FolderPicker { url in
                    if ComicManager.setLibraryRoot(url) {
                        hasLibraryRoot = true
                        library.runStartupMaintenance()
                    } else {
                        importError = "无法保存漫画根目录访问权限，请重新选择 Files 中的文件夹。"
                    }
                } onCancel: {}
            }
            .eraseToAnyView()
            .alert("导入失败", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )) {
                Button("好", role: .cancel) { importError = nil }
            } message: {
                Text(importError ?? "")
            }
            .alert("网页服务", isPresented: Binding(
                get: { webServer.errorMessage != nil },
                set: { if !$0 { webServer.errorMessage = nil } }
            )) {
                Button("好", role: .cancel) { webServer.errorMessage = nil }
            } message: {
                Text(webServer.errorMessage ?? "")
            }
            .eraseToAnyView()
            .alert("重命名漫画", isPresented: Binding(
                get: { renamingComic != nil },
                set: { if !$0 { renamingComic = nil } }
            )) {
                TextField("漫画名称", text: $renameTitle)
                Button("取消", role: .cancel) { renamingComic = nil }
                Button("保存") {
                    if let renamingComic {
                        library.rename(id: renamingComic.id, title: renameTitle)
                    }
                    renamingComic = nil
                }
            }
            .alert("重命名系列", isPresented: Binding(
                get: { renamingSeries != nil },
                set: { if !$0 { renamingSeries = nil } }
            )) {
                TextField("系列名称", text: $renameTitle)
                Button("取消", role: .cancel) { renamingSeries = nil }
                Button("保存") {
                    if let renamingSeries {
                        library.renameSeries(id: renamingSeries.id, title: renameTitle)
                    }
                    renamingSeries = nil
                }
            }
            .alert("新系列", isPresented: $showNewSeriesAlert) {
                TextField("系列名称", text: $newSeriesName)
                Button("取消", role: .cancel) { newSeriesName = "" }
                Button("创建") {
                    library.addSeries(title: newSeriesName)
                    selectedPage = .library
                    newSeriesName = ""
                }
            } message: {
                Text("创建后可以打开系列并添加章节漫画。")
            }
            .sheet(isPresented: $showStorageManager) {
                StorageManagerView(library: library)
            }
            .sheet(isPresented: $showActivity) {
                ShelfActivityView(comics: library.comics)
            }
        }
    }

    private var allowedImportTypes: [UTType] {
        switch importPickerMode {
        case .files:
            return [.zip, .pdf, .image, UTType(filenameExtension: "cbz"), UTType(filenameExtension: "rar"), UTType(filenameExtension: "cbr"), UTType(filenameExtension: "7z")].compactMap { $0 }
        case .folder:
            return [.folder, .directory]
        }
    }

    private var continueReadingPage: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(continueReadingComics) { comic in
                    NavigationLink(destination: readerDestination(for: comic)) {
                        ContinueReadingCard(comic: comic)
                    }
                    .buttonStyle(.plain)
                    .hapticTap(.light)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: library.comics)
    }

    @ViewBuilder
    private var processingOverlay: some View {
        if isProcessing {
            VStack(spacing: 16) {
                ProgressView().controlSize(.large)
                Text("正在导入并解析...")
                    .font(.headline)
            }
            .padding(30)
            .background(.ultraThinMaterial)
            .cornerRadius(16)
            .shadow(radius: 10)
        }
    }

    private var settingsView: some View {
        NavigationStack {
            Form {
                openAISettingsSection
                importServiceSection
                interactionSettingsSection
                backupSettingsSection
                localLibrarySettingsSection
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("完成") {
                    showSettings = false
                }
            }
        }
    }

    @ViewBuilder
    private var shelfRootContent: some View {
        if !hasAnyLibrarySource {
            missingLibraryRootView
        } else if library.comics.isEmpty && library.series.isEmpty {
            emptyShelfView
        } else if selectedPage == .continueReading {
            continueReadingPage
        } else {
            libraryPage
        }
    }

    private var missingLibraryRootView: some View {
        ContentUnavailableView {
            Label("选择漫画库", systemImage: "folder")
        } description: {
            Text("请选择 Files 中的 Manga 或其他漫画根目录。后续扫描、导入、删除都只基于这个目录。")
        } actions: {
            Button("选择漫画根目录") {
                isLibraryRootPicking = true
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var emptyShelfView: some View {
        ContentUnavailableView {
            Label("书架空空如也", systemImage: "books.vertical")
        } description: {
            Text("支持导入图片文件夹、ZIP、CBZ")
        } actions: {
            Button("导入漫画文件") {
                beginImport(.files)
            }
            .buttonStyle(.borderedProminent)
            Button("导入漫画文件夹") {
                beginImport(.folder)
            }
        }
    }

    private var continueReadingComics: [ComicBook] {
        let candidates = visibleComics
            .filter { $0.currentPageIndex > 0 || $0.lastReadAt.timeIntervalSince1970 > 0 }
            .sorted { $0.lastReadAt > $1.lastReadAt }
        if candidates.isEmpty, let first = visibleComics.sorted(by: { $0.lastReadAt > $1.lastReadAt }).first {
            return [first]
        }
        return candidates
    }

    private var libraryPage: some View {
        GeometryReader { geometry in
            let cardWidth = ShelfCardMetrics.cardWidth(for: geometry.size.width)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(shelfTitle)
                                .font(.title2.weight(.bold))
                            Spacer()
                            Text("\(visibleComics.count + library.series.count) 项")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, ShelfCardMetrics.horizontalPadding)

                        if shelfDisplayMode == .grid {
                            LazyVGrid(columns: twoColumnGrid(cardWidth: cardWidth), spacing: 24) {
                                ForEach(library.series) { series in
                                    seriesGridItem(series, comics: library.comics.filter { $0.seriesID == series.id }, cardWidth: cardWidth)
                                }
                                ForEach(visibleComics.filter { $0.seriesID == nil }) { comic in
                                    comicGridItem(comic, cardWidth: cardWidth)
                                }
                            }
                            .padding(.horizontal, ShelfCardMetrics.horizontalPadding)
                        } else {
                            LazyVStack(spacing: 12) {
                                ForEach(library.series) { series in
                                    seriesGridItem(series, comics: library.comics.filter { $0.seriesID == series.id }, cardWidth: cardWidth)
                                }
                                ForEach(visibleComics.filter { $0.seriesID == nil }) { comic in
                                    comicListItem(comic)
                                }
                            }
                            .padding(.horizontal, ShelfCardMetrics.horizontalPadding)
                        }
                    }
                }
                .padding(.vertical, 12)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: library.comics)
    }

    private func twoColumnGrid(cardWidth: CGFloat) -> [GridItem] {
        [
            GridItem(.fixed(cardWidth), spacing: ShelfCardMetrics.columnSpacing),
            GridItem(.fixed(cardWidth), spacing: ShelfCardMetrics.columnSpacing)
        ]
    }

    private var shelfTitle: String {
        switch shelfFilter {
        case .all: return "书架"
        case .inProgress: return "正在阅读"
        case .locked: return "已锁定"
        }
    }

    private var shelfActionMenu: some View {
        Menu {
            Button {
                HapticManager.shared.play(.light)
                beginImport(.files)
            } label: {
                Label("导入文件", systemImage: "doc.badge.plus")
            }

            Button {
                HapticManager.shared.play(.light)
                beginImport(.folder)
            } label: {
                Label("导入文件夹", systemImage: "folder.badge.plus")
            }

            Button {
                HapticManager.shared.play(.medium)
                library.syncLocalLibrary()
                selectedPage = .library
            } label: {
                Label("扫描本地库", systemImage: "arrow.clockwise")
            }

            Button {
                HapticManager.shared.play(.light)
                selectedPage = .library
                showNewSeriesAlert = true
            } label: {
                Label("新系列", systemImage: "folder.badge.plus")
            }

            Button {
                HapticManager.shared.play(.medium)
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                    isSelectionMode.toggle()
                    selectedComicIDs.removeAll()
                    selectedSeriesIDs.removeAll()
                }
            } label: {
                Label(isSelectionMode ? "完成选择" : "选择", systemImage: "checkmark.circle")
            }

            Divider()

            Button {
                HapticManager.shared.play(.light)
                shelfDisplayMode = .grid
            } label: {
                Label("网格", systemImage: "square.grid.2x2")
            }

            Button {
                HapticManager.shared.play(.light)
                shelfDisplayMode = .list
            } label: {
                Label("列表", systemImage: "list.bullet")
            }

            Divider()

            Menu {
                Button {
                    HapticManager.shared.play(.light)
                    shelfFilter = .all
                } label: {
                    Label("全部漫画", systemImage: shelfFilter == .all ? "checkmark" : "books.vertical")
                }

                Button {
                    HapticManager.shared.play(.light)
                    shelfFilter = .inProgress
                } label: {
                    Label("正在阅读", systemImage: shelfFilter == .inProgress ? "checkmark" : "clock")
                }

                Button {
                    HapticManager.shared.play(.light)
                    shelfFilter = .locked
                } label: {
                    Label("已锁定", systemImage: shelfFilter == .locked ? "checkmark" : "lock")
                }
            } label: {
                Label("分类书架", systemImage: "books.vertical")
            }

            Divider()

            Button {
                HapticManager.shared.play(.light)
                showSettings = true
            } label: {
                Label("设置", systemImage: "gearshape")
            }

            Button {
                HapticManager.shared.play(.light)
                showStorageManager = true
            } label: {
                Label("管理空间", systemImage: "cube.box")
            }

            Button {
                HapticManager.shared.play(.light)
                FileOpenPresenter.shared.open(ComicManager.localLibraryURLForOpening())
            } label: {
                Label("在 Files 中显示", systemImage: "folder")
            }

            Button {
                HapticManager.shared.play(.light)
                showActivity = true
            } label: {
                Label("书架活动", systemImage: "externaldrive.badge.checkmark")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .hapticTap(.light)
    }

    private func comicGridItem(_ comic: ComicBook, cardWidth: CGFloat) -> some View {
        Group {
            if isSelectionMode {
                Button {
                    toggleSelection(for: comic)
                } label: {
                    ComicCoverCard(comic: comic, isSelected: selectedComicIDs.contains(comic.id), cardWidth: cardWidth)
                }
            } else {
                NavigationLink(destination: readerDestination(for: comic)) {
                    ComicCoverCard(comic: comic, cardWidth: cardWidth)
                }
            }
        }
        .frame(width: cardWidth, height: ShelfCardMetrics.cardHeight(for: cardWidth), alignment: .top)
        .contentShape(Rectangle())
        .clipped()
        .hapticTap(.light)
        .buttonStyle(.plain)
        .contextMenu {
            comicManagementMenu(for: comic)
        }
        .transition(.scale(scale: 0.94).combined(with: .opacity))
    }

    private func seriesGridItem(_ series: ComicSeries, comics: [ComicBook], cardWidth: CGFloat) -> some View {
        Group {
            if isSelectionMode {
                Button {
                    toggleSeriesSelection(for: series)
                } label: {
                    SeriesCard(series: series, comics: comics, isSelected: selectedSeriesIDs.contains(series.id), cardWidth: cardWidth)
                }
            } else {
                NavigationLink {
                    SeriesDetailView(series: series, comics: library.comics.filter { $0.seriesID == series.id }, allComics: library.comics) { comicID in
                        library.addComic(comicID, toSeries: series.id)
                    } onRemove: { comicID in
                        library.addComic(comicID, toSeries: nil)
                    } onImportFiles: {
                        importingSeriesID = series.id
                        beginImport(.files)
                    } onImportFolder: {
                        importingSeriesID = series.id
                        beginImport(.folder)
                    } readerDestination: { comic in
                        AnyView(readerDestination(for: comic))
                    }
                    .navigationTransition(.zoom(sourceID: series.id, in: seriesAnimationNamespace))
                } label: {
                    SeriesCard(series: series, comics: comics, cardWidth: cardWidth)
                        .matchedTransitionSource(id: series.id, in: seriesAnimationNamespace)
                }
            }
        }
        .frame(width: cardWidth, height: ShelfCardMetrics.cardHeight(for: cardWidth), alignment: .top)
        .contentShape(Rectangle())
        .clipped()
        .hapticTap(.light)
        .buttonStyle(.plain)
        .contextMenu {
            seriesManagementMenu(for: series)
        }
    }

    @ViewBuilder
    private func seriesManagementMenu(for series: ComicSeries) -> some View {
        Button {
            HapticManager.shared.play(.light)
            renameTitle = series.title
            renamingSeries = series
        } label: {
            Label("重命名", systemImage: "pencil")
        }

        Button {
            HapticManager.shared.play(.medium)
            library.rebuildThumbnails(for: [], seriesIDs: [series.id])
        } label: {
            Label("重建缩略图", systemImage: "photo.on.rectangle.angled")
        }

        if let folderURL = ComicManager.urlForLibraryPath(series.libraryPath) {
            ShareLink(item: folderURL) {
                Label("分享", systemImage: "square.and.arrow.up")
            }

            Button {
                HapticManager.shared.play(.light)
                FileOpenPresenter.shared.open(folderURL)
            } label: {
                Label("在文件中打开", systemImage: "folder")
            }
        }

        Button(role: .destructive) {
            HapticManager.shared.play(.heavy)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                library.deleteSeries(id: series.id)
            }
        } label: {
            Label("删除", systemImage: "trash")
        }
    }

    private func comicListItem(_ comic: ComicBook) -> some View {
        Group {
            if isSelectionMode {
                Button {
                    toggleSelection(for: comic)
                } label: {
                    ComicListRow(comic: comic, isSelected: selectedComicIDs.contains(comic.id))
                }
            } else {
                NavigationLink(destination: readerDestination(for: comic)) {
                    ComicListRow(comic: comic)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            comicManagementMenu(for: comic)
        }
    }

    private func toggleSelection(for comic: ComicBook) {
        if selectedComicIDs.contains(comic.id) {
            selectedComicIDs.remove(comic.id)
        } else {
            HapticManager.shared.play(.medium)
            selectedComicIDs.insert(comic.id)
        }
    }

    private func toggleSeriesSelection(for series: ComicSeries) {
        if selectedSeriesIDs.contains(series.id) {
            selectedSeriesIDs.remove(series.id)
        } else {
            HapticManager.shared.play(.medium)
            selectedSeriesIDs.insert(series.id)
        }
    }

    private var selectionActionBar: some View {
        HStack(spacing: 14) {
            Text("已选 \(selectedComicIDs.count + selectedSeriesIDs.count)")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Button {
                HapticManager.shared.play(.medium)
                library.rebuildThumbnails(for: selectedComicIDs, seriesIDs: selectedSeriesIDs)
                selectedComicIDs.removeAll()
                selectedSeriesIDs.removeAll()
                isSelectionMode = false
            } label: {
                Label("重建缩略图", systemImage: "photo.on.rectangle.angled")
            }
            .disabled(selectedComicIDs.isEmpty && selectedSeriesIDs.isEmpty)

            Button(role: .destructive) {
                deleteSelectedItems()
            } label: {
                Label("删除", systemImage: "trash")
            }
            .disabled(selectedComicIDs.isEmpty && selectedSeriesIDs.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var openAISettingsSection: some View {
        Section(header: Text("OpenAI 兼容接口"), footer: Text("Base URL 填到 /v1 即可，例如 https://api.openai.com/v1 或你的代理服务地址。漫画图片不上传，只发送 OCR 后的文字。")) {
            SecureField("输入 OpenAI API Key", text: $apiKey)
                .textContentType(.password)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            TextField("Base URL", text: $baseURL)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            TextField("模型", text: $modelName)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("翻译 Prompt 模板")
                    Spacer()
                    Button("恢复默认") {
                        translationPromptTemplate = AITranslator.defaultTranslationPromptTemplate
                    }
                    .buttonStyle(.bordered)
                }
                TextEditor(text: $translationPromptTemplate)
                    .font(.footnote.monospaced())
                    .frame(minHeight: 220)
                    .scrollContentBackground(.hidden)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text("可用占位符：{targetLanguage}、{ocrText}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var importServiceSection: some View {
        Section(header: Text("导入服务")) {
            Button {
                HapticManager.shared.play(.light)
                showSettings = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    beginImport(.files)
                }
            } label: {
                Label("从本机或云盘导入文件", systemImage: "icloud.and.arrow.down")
            }

            Button {
                HapticManager.shared.play(.light)
                showSettings = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    beginImport(.folder)
                }
            } label: {
                Label("从本机或云盘导入文件夹", systemImage: "folder.badge.plus")
            }

            Toggle(isOn: Binding(
                get: { webServer.isRunning },
                set: { enabled in
                    if enabled {
                        webServer.start { uploadedURL in
                            importComic(from: uploadedURL)
                        }
                    } else {
                        webServer.stop()
                    }
                }
            )) {
                Label("网页上传服务", systemImage: "network")
            }

            if webServer.isRunning {
                LabeledContent("访问地址") {
                    Text(webServer.address)
                        .font(.footnote)
                        .textSelection(.enabled)
                }
                Button {
                    UIPasteboard.general.string = webServer.address
                } label: {
                    Label("复制网页地址", systemImage: "doc.on.doc")
                }
            }
        }
    }

    private var interactionSettingsSection: some View {
        Section(header: Text("交互")) {
            Toggle("触感反馈", isOn: $isHapticFeedbackEnabled)
                .onChange(of: isHapticFeedbackEnabled) { _, newValue in
                    if newValue {
                        HapticManager.shared.play(.success)
                    }
                }
        }
    }

    private var backupSettingsSection: some View {
        Section(header: Text("备份与恢复"), footer: Text("只备份 AI 接口、翻译语言和触感开关。漫画文件、阅读进度、封面缓存不包含在内。")) {
            Button {
                HapticManager.shared.play(.light)
                settingsBackupDocument = SettingsBackupDocument(
                    backup: makeSettingsBackup()
                )
                showSettings = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    isExportingSettings = true
                }
            } label: {
                Label("导出设置备份", systemImage: "square.and.arrow.up")
            }

            Button {
                HapticManager.shared.play(.light)
                showSettings = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    isRestoringSettings = true
                }
            } label: {
                Label("从备份恢复", systemImage: "square.and.arrow.down")
            }
        }
    }

    private var localLibrarySettingsSection: some View {
        let address = ComicManager.readableLocalLibraryAddress()
        return Section(header: Text("本地库")) {
            LabeledContent("地址") {
                Text(address)
                    .font(.footnote)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
            }
            Button {
                UIPasteboard.general.string = address
            } label: {
                Label("复制本地库地址", systemImage: "folder")
            }
            Button {
                isLibraryRootPicking = true
            } label: {
                Label("更换漫画根目录", systemImage: "folder.badge.gearshape")
            }
        }
    }

    private func deleteSelectedItems() {
        HapticManager.shared.play(.heavy)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            for seriesID in selectedSeriesIDs {
                library.deleteSeries(id: seriesID)
            }
            for comicID in selectedComicIDs {
                library.delete(id: comicID)
            }
            selectedComicIDs.removeAll()
            selectedSeriesIDs.removeAll()
            isSelectionMode = false
        }
    }

    private func readerDestination(for comic: ComicBook) -> some View {
        ReaderContainerView(comic: comic) { pageIndex in
            library.updateProgress(for: comic.id, pageIndex: pageIndex)
        } onComicUpdate: { updatedComic in
            library.update(updatedComic)
        }
    }

    @ViewBuilder
    private func comicManagementMenu(for comic: ComicBook) -> some View {
        Button {
            HapticManager.shared.play(.light)
            renameTitle = comic.title
            renamingComic = comic
        } label: {
            Label("重命名", systemImage: "pencil")
        }

        if let folderURL = folderURL(for: comic) {
            ShareLink(item: folderURL) {
                Label("分享", systemImage: "square.and.arrow.up")
            }

            Button {
                HapticManager.shared.play(.light)
                FileOpenPresenter.shared.open(folderURL)
            } label: {
                Label("在文件中打开", systemImage: "folder")
            }
        }

        Button {
            HapticManager.shared.play(.medium)
            library.setLocked(id: comic.id, isLocked: !comic.isLocked)
        } label: {
            Label(comic.isLocked ? "取消锁定" : "锁定", systemImage: comic.isLocked ? "lock.open" : "lock")
        }

        Button {
            HapticManager.shared.play(.medium)
            library.rebuildThumbnail(for: comic.id)
        } label: {
            Label("重建缩略图", systemImage: "photo.on.rectangle.angled")
        }

        Button(role: .destructive) {
            HapticManager.shared.play(.heavy)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                library.delete(id: comic.id)
            }
        } label: {
            Label("删除", systemImage: "trash")
        }
    }

    private func folderURL(for comic: ComicBook) -> URL? {
        try? ComicManager.resolveBookmark(comic.bookmarkData)
    }
    
    private func importComicsOrFolder(from urls: [URL], seriesID: UUID? = nil) {
        isProcessing = true
        Task {
            var importedCount = 0
            var failedCount = 0
            var failureReason: String?

            let seriesDestinationRoot = await MainActor.run { () -> URL? in
                guard let seriesID,
                      let path = library.series.first(where: { $0.id == seriesID })?.libraryPath else { return nil }
                return URL(fileURLWithPath: path, isDirectory: true)
            }

            let singleURL = urls.count == 1 ? urls.first : nil
            let singleURLIsDirectory = await Task.detached(priority: .utility) {
                guard let singleURL else { return false }
                return Self.isDirectoryURL(singleURL)
            }.value

            if let url = singleURL, singleURLIsDirectory {
                // 如果只导入了一个文件夹，检查其内部结构
                let folderInspection = await Task.detached(priority: .utility) {
                    Self.inspectImportFolder(url)
                }.value
                let hasDirectImages = folderInspection.hasDirectImages
                let childFoldersOrZips = folderInspection.childFoldersOrZips

                if !hasDirectImages && !childFoldersOrZips.isEmpty {
                    let targetSeriesID = await MainActor.run { () -> UUID? in
                        if let seriesID {
                            return seriesID
                        }
                        return library.addSeries(title: url.lastPathComponent)?.id
                    }

                    if let targetSeriesID {
                        let targetRoot = await MainActor.run { () -> URL? in
                            guard let path = library.series.first(where: { $0.id == targetSeriesID })?.libraryPath else { return nil }
                            return URL(fileURLWithPath: path, isDirectory: true)
                        }
                        for childURL in childFoldersOrZips {
                            if let info = await ComicManager.importFileOrFolder(url: childURL, destinationRoot: targetRoot) {
                                await MainActor.run {
                                    library.addImported(info, seriesID: targetSeriesID)
                                }
                                importedCount += 1
                            } else {
                                failedCount += 1
                                if urls.count == 1 {
                                    failureReason = ComicManager.zipImportFailureReason(for: childURL)
                                }
                            }
                        }
                    } else {
                        failedCount += childFoldersOrZips.count
                    }
                } else {
                    // 普通漫画文件夹
                    if let info = await ComicManager.importFileOrFolder(url: url, destinationRoot: seriesDestinationRoot) {
                        await MainActor.run {
                            library.addImported(info, seriesID: seriesID)
                        }
                        importedCount += 1
                    } else {
                        failedCount += 1
                        failureReason = ComicManager.zipImportFailureReason(for: url)
                    }
                }
            } else {
                // 多选文件导入
                for url in urls {
                    if let info = await ComicManager.importFileOrFolder(url: url, destinationRoot: seriesDestinationRoot) {
                        await MainActor.run {
                            library.addImported(info, seriesID: seriesID)
                        }
                        importedCount += 1
                    } else {
                        failedCount += 1
                        if urls.count == 1 {
                            failureReason = ComicManager.zipImportFailureReason(for: url)
                        }
                    }
                }
            }

            await MainActor.run {
                if importedCount == 0 && failedCount > 0 {
                    HapticManager.shared.play(.error)
                    importError = failureReason?.isEmpty == false ? failureReason! : "没有找到可读取的图片，或压缩包/PDF 解析失败。当前可直接读取 ZIP、CBZ、7z、PDF 和图片文件夹；RAR、CBR 暂未支持。"
                } else if failedCount > 0 {
                    HapticManager.shared.play(.warning)
                    importError = "已导入 \(importedCount) 个项目，\(failedCount) 个项目失败。失败项目可能不包含可读取图片或压缩包已损坏。"
                } else {
                    HapticManager.shared.play(.success)
                }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                    selectedPage = .library
                }
                isProcessing = false
            }
        }
    }

    private func importComic(from url: URL, seriesID: UUID? = nil) {
        importComicsOrFolder(from: [url], seriesID: seriesID)
    }

    private func beginImport(_ mode: ImportPickerMode) {
        guard hasLibraryRoot else {
            isLibraryRootPicking = true
            return
        }
        importPickerMode = mode
        switch mode {
        case .files:
            isImporting = true
        case .folder:
            isFolderImporting = true
        }
    }

    nonisolated private static func isDirectoryURL(_ url: URL) -> Bool {
        url.hasDirectoryPath || ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
    }

    nonisolated private static func inspectImportFolder(_ url: URL) -> (hasDirectImages: Bool, childFoldersOrZips: [URL]) {
        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        defer { if isSecurityScoped { url.stopAccessingSecurityScopedResource() } }

        var childFoldersOrZips: [URL] = []
        guard let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return (false, [])
        }

        for fileURL in contents {
            let ext = fileURL.pathExtension.lowercased()
            if ["jpg", "jpeg", "png", "webp", "gif", "heic", "heif"].contains(ext) {
                return (true, [])
            }
            if (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true || ["zip", "cbz", "rar", "cbr", "pdf", "7z"].contains(ext) {
                childFoldersOrZips.append(fileURL)
            }
        }

        return (false, childFoldersOrZips)
    }

    private func makeSettingsBackup() -> MReaderSettingsBackup {
        MReaderSettingsBackup(
            openAIAPIKey: apiKey,
            openAIBaseURL: baseURL,
            openAIModel: modelName,
            translationTargetLanguage: translationTargetLanguage,
            translationPromptTemplate: translationPromptTemplate,
            isHapticFeedbackEnabled: isHapticFeedbackEnabled
        )
    }

    private func restoreSettingsBackup(from result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let didStartAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let data = try Data(contentsOf: url)
            let backup = try JSONDecoder().decode(MReaderSettingsBackup.self, from: data)
            apiKey = backup.openAIAPIKey
            baseURL = backup.openAIBaseURL
            modelName = backup.openAIModel
            translationTargetLanguage = backup.translationTargetLanguage
            translationPromptTemplate = backup.translationPromptTemplate ?? AITranslator.defaultTranslationPromptTemplate
            isHapticFeedbackEnabled = backup.isHapticFeedbackEnabled
            library.syncLocalLibrary()
            HapticManager.shared.play(.success)
            importError = "设置备份已恢复。"
        } catch {
            HapticManager.shared.play(.error)
            importError = "设置备份恢复失败，请确认选择的是 MReader 设置备份 JSON。"
        }
    }

}

@MainActor
final class FileOpenPresenter: NSObject, UIDocumentInteractionControllerDelegate {
    static let shared = FileOpenPresenter()

    private var controller: UIDocumentInteractionController?
    private var activityController: UIActivityViewController?
    private var activeURL: URL?
    private var didStartSecurityScope = false

    func open(_ url: URL) {
        cleanupSecurityScope()
        activeURL = url
        didStartSecurityScope = url.startAccessingSecurityScopedResource()

        UIApplication.shared.open(url) { [weak self] success in
            guard !success else {
                self?.cleanupSecurityScope()
                return
            }
            self?.presentPreview(for: url)
        }
    }

    private func presentPreview(for url: URL) {
        let controller = UIDocumentInteractionController(url: url)
        controller.delegate = self
        self.controller = controller

        guard let presenter = Self.topViewController() else {
            cleanupSecurityScope()
            return
        }

        let sourceRect = CGRect(
            x: presenter.view.bounds.midX,
            y: presenter.view.bounds.midY,
            width: 1,
            height: 1
        )

        if !controller.presentPreview(animated: true) {
            presentActivityController(for: url, from: presenter, sourceRect: sourceRect)
        }
    }

    func documentInteractionControllerViewControllerForPreview(_ controller: UIDocumentInteractionController) -> UIViewController {
        Self.topViewController() ?? UIViewController()
    }

    func documentInteractionControllerDidDismissOptionsMenu(_ controller: UIDocumentInteractionController) {
        cleanupSecurityScope()
    }

    func documentInteractionControllerDidEndPreview(_ controller: UIDocumentInteractionController) {
        cleanupSecurityScope()
    }

    private func cleanupSecurityScope() {
        if didStartSecurityScope {
            activeURL?.stopAccessingSecurityScopedResource()
        }
        didStartSecurityScope = false
        activeURL = nil
        controller = nil
        activityController = nil
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let keyWindow = scenes.flatMap(\.windows).first { $0.isKeyWindow }
        var top = keyWindow?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }

    private func presentActivityController(for url: URL, from presenter: UIViewController, sourceRect: CGRect) {
        let activityController = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        activityController.popoverPresentationController?.sourceView = presenter.view
        activityController.popoverPresentationController?.sourceRect = sourceRect
        activityController.completionWithItemsHandler = { [weak self] _, _, _, _ in
            Task { @MainActor in
                self?.cleanupSecurityScope()
            }
        }
        self.activityController = activityController
        presenter.present(activityController, animated: true)
    }
}

struct FolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        controller.allowsMultipleSelection = false
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: FolderPicker

        init(parent: FolderPicker) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first {
                parent.onPick(url)
            } else {
                parent.onCancel()
            }
            parent.dismiss()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
            parent.dismiss()
        }
    }
}

private enum ShelfCardMetrics {
    static let horizontalPadding: CGFloat = 18
    static let columnSpacing: CGFloat = 16
    static let titleHeight: CGFloat = 44
    static let progressHeight: CGFloat = 4
    static let metaHeight: CGFloat = 16
    static let verticalSpacing: CGFloat = 10
    static let debugBorders = false

    static func cardWidth(for containerWidth: CGFloat) -> CGFloat {
        let availableWidth = max(0, containerWidth - horizontalPadding * 2 - columnSpacing)
        return floor(max(132, availableWidth / 2))
    }

    static func coverHeight(for cardWidth: CGFloat) -> CGFloat {
        floor(cardWidth / 0.68)
    }

    static func cardHeight(for cardWidth: CGFloat) -> CGFloat {
        coverHeight(for: cardWidth) + titleHeight + progressHeight + metaHeight + verticalSpacing * 3
    }
}

struct ComicCoverCard: View {
    let comic: ComicBook
    var isSelected = false
    var cardWidth: CGFloat = 160

    private var coverHeight: CGFloat {
        ShelfCardMetrics.coverHeight(for: cardWidth)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topTrailing) {
                CoverImageView(path: comic.coverImagePath)
                    .frame(width: cardWidth, height: coverHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .clipped()
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 6)
                    .allowsHitTesting(false)

                if comic.isLocked {
                    Image(systemName: "lock.fill")
                        .font(.caption.weight(.bold))
                        .padding(7)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                        .padding(8)
                }

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(8)
                }
            }
            .frame(width: cardWidth, height: coverHeight)
            .contentShape(Rectangle())
            .clipped()

            Text(comic.title)
                .font(.headline)
                .lineLimit(2)
                .frame(width: cardWidth, height: ShelfCardMetrics.titleHeight, alignment: .topLeading)
                .foregroundStyle(.primary)

            ProgressView(value: Double(comic.currentPageIndex + 1), total: Double(max(comic.totalPages, 1)))
                .tint(.accentColor)
                .frame(width: cardWidth, height: ShelfCardMetrics.progressHeight)

            HStack {
                Text(sourceLabel(for: comic))
                Text("·")
                Text(formattedFileSize(comic.fileSize))
                Spacer()
                Text("\(comic.totalPages) 页")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: cardWidth, height: ShelfCardMetrics.metaHeight)
        }
        .frame(width: cardWidth, height: ShelfCardMetrics.cardHeight(for: cardWidth), alignment: .topLeading)
        .contentShape(Rectangle())
        .clipped()
        .debugShelfHitArea()
        .opacity(isSelected ? 0.78 : 1)
    }
}

private func formattedFileSize(_ bytes: Int64) -> String {
    guard bytes > 0 else { return "未知大小" }
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

private func sourceLabel(for comic: ComicBook) -> String {
    switch comic.sourceType {
    case .local:
        return "本地"
    case .smb:
        return "SMB"
    case .webdav:
        return "WebDAV"
    }
}

struct ComicListRow: View {
    let comic: ComicBook
    var isSelected = false

    var body: some View {
        HStack(spacing: 14) {
            Color.clear
                .frame(width: 62, height: 90)
                .overlay {
                    CoverImageView(path: comic.coverImagePath)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(comic.title)
                        .font(.headline)
                        .lineLimit(2)
                    if comic.isLocked {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                ProgressView(value: Double(comic.currentPageIndex + 1), total: Double(max(comic.totalPages, 1)))
                    .tint(.accentColor)

                Text("\(formattedFileSize(comic.fileSize)) · \(comic.totalPages) 页")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(10)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct SeriesCard: View {
    let series: ComicSeries
    let comics: [ComicBook]
    var isSelected = false
    var cardWidth: CGFloat = 160

    private var coverHeight: CGFloat {
        ShelfCardMetrics.coverHeight(for: cardWidth)
    }

    private var stackedCovers: ArraySlice<ComicBook> {
        comics.prefix(3)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    if !stackedCovers.isEmpty {
                        ZStack {
                            ForEach(Array(stackedCovers.enumerated()), id: \.element.id) { index, comic in
                                CoverImageView(path: comic.coverImagePath)
                                    .frame(width: cardWidth - 14, height: coverHeight - 12)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .clipped()
                                    .rotationEffect(.degrees(Double(index - 1) * 2.8))
                                    .offset(x: CGFloat(index) * 4 - 4, y: CGFloat(index) * -5 + 5)
                                    .scaleEffect(1 - CGFloat(index) * 0.035)
                                    .shadow(color: .black.opacity(index == 0 ? 0.18 : 0.1), radius: 8, y: 5)
                                    .allowsHitTesting(false)
                            }
                        }
                        .frame(width: cardWidth, height: coverHeight)
                        .clipped()
                    } else {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.quaternary)
                            .frame(width: cardWidth, height: coverHeight)
                            .overlay {
                                Image(systemName: "folder")
                                    .font(.system(size: 42, weight: .regular))
                                    .foregroundStyle(.secondary)
                            }
                    }
                }
                .frame(width: cardWidth, height: coverHeight)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .clipped()
                .shadow(color: .black.opacity(0.18), radius: 10, y: 6)
                .allowsHitTesting(false)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(8)
                }
            }
            .frame(width: cardWidth, height: coverHeight)
            .contentShape(Rectangle())
            .clipped()

            Text(series.title)
                .font(.headline)
                .lineLimit(2)
                .frame(width: cardWidth, height: ShelfCardMetrics.titleHeight, alignment: .topLeading)
                .foregroundStyle(.primary)

            ProgressView(value: Double(comics.filter { $0.currentPageIndex > 0 }.count), total: Double(max(comics.count, 1)))
                .tint(.accentColor)
                .frame(width: cardWidth, height: ShelfCardMetrics.progressHeight)

            HStack {
                Text("\(comics.count) 章")
                Spacer()
                Text("\(comics.reduce(0) { $0 + $1.totalPages }) 页")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: cardWidth, height: ShelfCardMetrics.metaHeight)
        }
        .frame(width: cardWidth, height: ShelfCardMetrics.cardHeight(for: cardWidth), alignment: .topLeading)
        .contentShape(Rectangle())
        .clipped()
        .debugShelfHitArea()
        .opacity(isSelected ? 0.78 : 1)
    }
}

private extension View {
    @ViewBuilder
    func debugShelfHitArea() -> some View {
        if ShelfCardMetrics.debugBorders {
            overlay {
                Rectangle()
                    .stroke(Color.red.opacity(0.45), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        } else {
            self
        }
    }
}

struct ContinueReadingCard: View {
    let comic: ComicBook

    private var progressText: String {
        "\(min(comic.currentPageIndex + 1, comic.totalPages)) / \(comic.totalPages)"
    }

    var body: some View {
        HStack(spacing: 14) {
            Color.clear
                .frame(width: 86, height: 126)
                .overlay {
                    CoverImageView(path: comic.coverImagePath)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .shadow(color: .black.opacity(0.16), radius: 10, y: 5)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text(comic.title)
                        .font(.headline)
                        .lineLimit(2)
                    if comic.isLocked {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                ProgressView(value: Double(comic.currentPageIndex + 1), total: Double(max(comic.totalPages, 1)))
                    .tint(.accentColor)

                Text("阅读进度 \(progressText)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text("继续阅读")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.accentColor)
                    .clipShape(Capsule())
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct CoverImageView: View {
    let path: String?
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary)

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                } else {
                    Image(systemName: "book.closed")
                        .font(.system(size: 42, weight: .regular))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: path) { await loadCover() }
    }

    private func loadCover() async {
        guard let path else {
            image = nil
            return
        }
        let loadedImage = await Task.detached(priority: .utility) {
            await Self.makeThumbnail(path: path, maxPixelSize: 640)
        }.value
        image = loadedImage
    }

    private static func makeThumbnail(path: String, maxPixelSize: CGFloat) async -> UIImage? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

}

struct StorageManagerView: View {
    @ObservedObject var library: ComicLibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var temporaryCacheSize = ComicManager.temporaryImportCacheSize()

    private var estimatedPages: Int {
        library.comics.reduce(0) { $0 + $1.totalPages }
    }

    var body: some View {
        NavigationStack {
            List {
                Section(header: Text("本地库")) {
                    LabeledContent("系列数量", value: "\(library.series.count)")
                    LabeledContent("漫画数量", value: "\(library.comics.count)")
                    LabeledContent("图片页数", value: "\(estimatedPages)")
                    Text(ComicManager.readableLocalLibraryAddress())
                        .font(.footnote)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                    Button {
                        UIPasteboard.general.string = ComicManager.readableLocalLibraryAddress()
                    } label: {
                        Label("复制本地库地址", systemImage: "doc.on.doc")
                    }
                }

                Section(header: Text("缓存与临时文件"), footer: Text("漫画源文件只存放在 Files 可见的 MReader 本地库；这里不删除漫画源文件。")) {
                    LabeledContent("临时解压缓存", value: formattedFileSize(temporaryCacheSize))
                    Button(role: .destructive) {
                        ComicManager.clearTemporaryImportCache()
                        temporaryCacheSize = ComicManager.temporaryImportCacheSize()
                    } label: {
                        Label("清理临时解压缓存", systemImage: "trash")
                    }

                    Button {
                        library.rebuildAllThumbnails()
                    } label: {
                        Label("检查并重建封面索引", systemImage: "photo.on.rectangle.angled")
                    }

                    Button {
                        library.syncLocalLibrary()
                    } label: {
                        Label("重新扫描本地库索引", systemImage: "arrow.clockwise")
                    }
                }
            }
            .navigationTitle("管理空间")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("完成") { dismiss() }
            }
        }
    }
}

struct ShelfActivityView: View {
    let comics: [ComicBook]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(comics.sorted { $0.lastReadAt > $1.lastReadAt }) { comic in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(comic.title)
                                .font(.headline)
                                .lineLimit(1)
                            Text("读到 \(min(comic.currentPageIndex + 1, comic.totalPages)) / \(comic.totalPages)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(comic.lastReadAt, format: .dateTime.month().day().hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("书架活动")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("完成") { dismiss() }
            }
        }
    }
}

struct SeriesDetailView: View {
    let series: ComicSeries
    let comics: [ComicBook]
    let allComics: [ComicBook]
    let onAdd: (UUID) -> Void
    let onRemove: (UUID) -> Void
    let onImportFiles: () -> Void
    let onImportFolder: () -> Void
    let readerDestination: (ComicBook) -> AnyView

    @State private var showAddSheet = false
    @State private var didSpreadChapters = false

    private var availableComics: [ComicBook] {
        allComics.filter { $0.seriesID != series.id }
    }

    var body: some View {
        Group {
            if comics.isEmpty {
                ContentUnavailableView {
                    Label("系列为空", systemImage: "books.vertical")
                } description: {
                    Text("添加章节漫画后会显示在这里")
                } actions: {
                    Button("导入章节文件") {
                        onImportFiles()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("导入章节文件夹") {
                        onImportFolder()
                    }
                    Button("从书架添加") { showAddSheet = true }
                }
            } else {
                GeometryReader { geometry in
                    let cardWidth = ShelfCardMetrics.cardWidth(for: geometry.size.width)
                    ScrollView {
                        LazyVGrid(columns: [
                            GridItem(.fixed(cardWidth), spacing: ShelfCardMetrics.columnSpacing),
                            GridItem(.fixed(cardWidth), spacing: ShelfCardMetrics.columnSpacing)
                        ], spacing: 24) {
                            ForEach(comics) { comic in
                                NavigationLink(destination: readerDestination(comic)) {
                                    ComicCoverCard(comic: comic, cardWidth: cardWidth)
                                }
                                .frame(width: cardWidth, height: ShelfCardMetrics.cardHeight(for: cardWidth), alignment: .top)
                                .contentShape(Rectangle())
                                .clipped()
                                .buttonStyle(.plain)
                                .scaleEffect(didSpreadChapters ? 1 : 0.82)
                                .opacity(didSpreadChapters ? 1 : 0)
                                .offset(y: didSpreadChapters ? 0 : 28)
                                .contextMenu {
                                    Button {
                                        onRemove(comic.id)
                                    } label: {
                                        Label("移出系列", systemImage: "minus.circle")
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, ShelfCardMetrics.horizontalPadding)
                        .padding(.vertical, 12)
                    }
                }
            }
        }
        .navigationTitle(series.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            withAnimation(.spring(response: 0.78, dampingFraction: 0.86)) {
                didSpreadChapters = true
            }
        }
        .onDisappear {
            didSpreadChapters = false
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        onImportFiles()
                    } label: {
                        Label("导入章节文件", systemImage: "doc.badge.plus")
                    }
                    Button {
                        onImportFolder()
                    } label: {
                        Label("导入章节文件夹", systemImage: "folder.badge.plus")
                    }
                    Button {
                        showAddSheet = true
                    } label: {
                        Label("从书架添加", systemImage: "books.vertical")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            NavigationStack {
                List {
                    ForEach(availableComics) { comic in
                        Button {
                            onAdd(comic.id)
                        } label: {
                            ComicListRow(comic: comic)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .navigationTitle("添加章节")
                .toolbar {
                    Button("完成") { showAddSheet = false }
                }
            }
        }
    }
}
