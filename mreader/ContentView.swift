import SwiftUI
import UniformTypeIdentifiers
import UIKit
import ImageIO

fileprivate final class SecurityScopeBox: @unchecked Sendable {
    private var url: URL?
    private var released = false

    func hold(_ url: URL) -> Bool {
        guard !released else { return false }
        let granted = url.startAccessingSecurityScopedResource()
        self.url = url
        return granted
    }

    func release() {
        guard !released else { return }
        released = true
        url?.stopAccessingSecurityScopedResource()
        url = nil
    }

    deinit {
        release()
    }
}

private extension View {
    func eraseToAnyView() -> AnyView {
        AnyView(self)
    }
}

private func naturalTitleCompare(_ lhsTitle: String, _ lhsTieBreaker: String, _ rhsTitle: String, _ rhsTieBreaker: String) -> Bool {
    let comparison = lhsTitle.localizedStandardCompare(rhsTitle)
    if comparison != .orderedSame {
        return comparison == .orderedAscending
    }
    return lhsTieBreaker.localizedStandardCompare(rhsTieBreaker) == .orderedAscending
}

enum ShelfDisplayMode: String, CaseIterable {
    case grid
    case list
}

enum ShelfFilter: String, CaseIterable {
    case all
    case inProgress
    case locked
    case local
    case komga
    case opds
}

enum MainShelfPage: String, CaseIterable {
    case continueReading
    case library
    case statistics
}

enum ImportPickerMode {
    case files
    case folder
}

private enum DeleteRequest: Identifiable {
    case comic(ComicBook)
    case series(ComicSeries)
    case selection(comics: Set<UUID>, series: Set<UUID>)

    var id: String {
        switch self {
        case .comic(let comic):
            return "comic-\(comic.id.uuidString)"
        case .series(let series):
            return "series-\(series.id.uuidString)"
        case .selection(let comics, let series):
            return "selection-\(comics.map(\.uuidString).sorted().joined(separator: ","))-\(series.map(\.uuidString).sorted().joined(separator: ","))"
        }
    }

    var message: String {
        switch self {
        case .comic(let comic):
            switch comic.sourceType {
            case .local:
                return "会删除用户漫画库中的真实文件，并清理书架记录。此操作不能撤销。"
            case .komga:
                return "会调用 Komga 服务器删除该漫画，并清理书架记录。此操作不能撤销。"
            case .opds:
                return "只会删除 MReader 中的 OPDS 书架记录和本地缓存，不会删除服务器上的文件。"
            }
        case .series:
            return "会删除该系列文件夹及其中漫画，并清理书架记录。此操作不能撤销。"
        case .selection:
            return "会删除选中漫画或系列对应的真实文件，并清理书架记录。此操作不能撤销。"
        }
    }
}

nonisolated struct MReaderSettingsBackup: Codable {
    var version = 5
    var openAIAPIKey: String
    var openAIBaseURL: String
    var openAIModel: String
    var aiModelPool: String?
    var isAIModelPoolEnabled: Bool?
    var translationTargetLanguage: String
    var translationPromptTemplate: String?
    var visionTranslationPromptTemplate: String?
    var isHapticFeedbackEnabled: Bool
    var mediaSources: [MediaSourceBackup]?
    var translationColorStyle: String?
    var isAITranslationBorderProgressEnabled: Bool?
    var isOCRDebugBoxesEnabled: Bool?
    var readingDailyPageGoal: Double?
    var isBurnInProtectionEnabled: Bool?
}

private struct SettingsRestoreNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

nonisolated struct MediaSourceBackup: Codable {
    var id: UUID
    var name: String
    var type: MediaSourceType
    var baseURL: String
    var username: String?
    var createdAt: Date
    var lastSyncAt: Date?
    var isEnabled: Bool
    var apiKey: String?

    init(source: MediaSource, apiKey: String?) {
        id = source.id
        name = source.name
        type = source.type
        baseURL = source.baseURL
        username = source.username
        createdAt = source.createdAt
        lastSyncAt = source.lastSyncAt
        isEnabled = source.isEnabled
        self.apiKey = apiKey
    }

    var mediaSource: MediaSource {
        MediaSource(
            id: id,
            name: name,
            type: type,
            baseURL: baseURL,
            username: username,
            createdAt: createdAt,
            lastSyncAt: lastSyncAt,
            isEnabled: isEnabled
        )
    }
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
    @ObservedObject private var readingActivity = ReadingActivityStore.shared
    @ObservedObject private var backgroundTasks = BackgroundTaskCenter.shared

    @State private var isImporting = false
    @State private var isFolderImporting = false
    @State private var isLibraryRootPicking = false
    @State private var isRestoringSettings = false
    @State private var isExportingSettings = false
    @State private var hasLibraryRoot = ComicManager.hasSelectedLibraryRoot()
    @State private var importPickerMode = ImportPickerMode.files
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
    @State private var deleteRequest: DeleteRequest?
    @State private var hideKomgaRequest: ComicBook?
    @State private var hiddenKomgaVersion = 0
    @State private var isRefreshingLibraries = false
    @State private var modelPoolStatuses: [AIModelPoolStatus] = []
    @State private var settingsRestoreNotice: SettingsRestoreNotice?
    @State private var selectedReaderComic: ComicBook?
    @AppStorage("openai_api_key") private var apiKey = ""
    @AppStorage("openai_base_url") private var baseURL = "https://api.openai.com/v1"
    @AppStorage("openai_model") private var modelName = "gpt-4o-mini"
    @AppStorage("ai_model_pool") private var modelPoolText = ""
    @AppStorage("ai_model_pool_enabled") private var isModelPoolEnabled = true
    @AppStorage("translation_target_language") private var translationTargetLanguage = "中文"
    @AppStorage("translation_prompt_template") private var translationPromptTemplate = AITranslator.defaultTranslationPromptTemplate
    @AppStorage("vision_translation_prompt_template") private var visionTranslationPromptTemplate = AITranslator.defaultVisionTranslationPromptTemplate
    @AppStorage(HapticSettings.isEnabledKey) private var isHapticFeedbackEnabled = true
    @AppStorage("translation_color_style") private var translationColorStyleRaw = "contrast"
    @AppStorage("ai_translation_border_progress_enabled") private var isAITranslationBorderProgressEnabled = true
    @AppStorage("ocr_show_debug_boxes") private var isOCRDebugBoxesEnabled = false
    @AppStorage("reading_daily_page_goal") private var readingDailyPageGoal = 40.0
    @AppStorage("burn_in_protection_enabled") private var isBurnInProtectionEnabled = true
    @Namespace private var seriesAnimationNamespace

    @State private var renamingSeries: ComicSeries?

    private var hasAnyLibrarySource: Bool {
        hasLibraryRoot || KomgaProvider.loadSources().contains { $0.isEnabled && ($0.type == .komga || $0.type == .opds) }
    }

    private var visibleComics: [ComicBook] {
        _ = hiddenKomgaVersion
        let hiddenKeys = KomgaProvider.hiddenKomgaComicKeys()
        let displayableComics = library.comics.filter { comic in
            guard let hiddenKey = KomgaProvider.hiddenKey(for: comic) else { return true }
            return !hiddenKeys.contains(hiddenKey)
        }
        switch shelfFilter {
        case .all:
            return displayableComics
        case .inProgress:
            return displayableComics.filter { $0.hasBeenOpened && !ComicReadingProgress.isFinished($0) }
        case .locked:
            return displayableComics.filter(\.isLocked)
        case .local:
            return displayableComics.filter { $0.sourceType == .local }
        case .komga:
            return displayableComics.filter { $0.sourceType == .komga }
        case .opds:
            return displayableComics.filter { $0.sourceType == .opds }
        }
    }

    var body: some View {
        NavigationStack {
            shelfRootContent
            .navigationTitle(navigationTitle)
            .navigationDestination(item: $selectedReaderComic) { comic in
                readerDestination(for: comic)
                    .transaction { transaction in
                        transaction.animation = nil
                        transaction.disablesAnimations = true
                    }
            }
            .toolbar {
                if backgroundTasks.isActive {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        BackgroundTaskIndicator(center: backgroundTasks)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
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
                FolderPicker { url, scopeBox in
                    importComicsOrFolder(from: [url], seriesID: importingSeriesID, securityBox: scopeBox)
                    importingSeriesID = nil
                } onCancel: {
                    importingSeriesID = nil
                }
            }
            .sheet(isPresented: $isLibraryRootPicking) {
                FolderPicker { url, scopeBox in
                    if ComicManager.setLibraryRoot(url) {
                        hasLibraryRoot = true
                        library.runStartupMaintenance()
                    } else {
                        importError = "无法保存漫画根目录访问权限，请重新选择 Files 中的文件夹。"
                    }
                    scopeBox.release()
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
            .alert(item: $settingsRestoreNotice) { notice in
                Alert(
                    title: Text(notice.title),
                    message: Text(notice.message),
                    dismissButton: .default(Text("好"))
                )
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
            .alert(
                "确认删除",
                isPresented: Binding(
                    get: { deleteRequest != nil },
                    set: { if !$0 { deleteRequest = nil } }
                )
            ) {
                Button("删除", role: .destructive) {
                    performConfirmedDelete()
                }
                Button("取消", role: .cancel) {
                    deleteRequest = nil
                }
            } message: {
                Text(deleteRequest?.message ?? "")
            }
            .confirmationDialog(
                hideKomgaRequest.map { "隐藏“\($0.title)”？" } ?? "隐藏 Komga 漫画？",
                isPresented: Binding(
                    get: { hideKomgaRequest != nil },
                    set: { if !$0 { hideKomgaRequest = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("隐藏", role: .destructive) {
                    performConfirmedKomgaHide()
                }
                Button("取消", role: .cancel) {
                    hideKomgaRequest = nil
                }
            } message: {
                Text("此操作只会从 MReader 书架隐藏该漫画，不会删除 Komga 服务器文件。")
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
            return [.zip, .pdf, .epub, .image, UTType(filenameExtension: "cbz")].compactMap { $0 }
        case .folder:
            return [.folder, .directory]
        }
    }

    private var continueReadingPage: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(continueReadingComics) { comic in
                    Button {
                        openReader(comic)
                    } label: {
                        ContinueReadingCard(comic: comic)
                    }
                    .buttonStyle(.plain)
                    .hapticTap(.light)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .refreshable {
            await refreshShelfLibraries()
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: library.comics)
    }

    private var readingStatisticsPage: some View {
        ReadingStatisticsView(comics: visibleComics)
            .refreshable {
                await refreshShelfLibraries()
            }
    }

    private var settingsView: some View {
        NavigationStack {
            Form {
                openAISettingsSection
                mediaSourceSettingsSection
                importServiceSection
                interactionSettingsSection
                backupSettingsSection
                localLibrarySettingsSection
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("完成") {
                    normalizeStoredModelPool()
                    showSettings = false
                }
            }
            .task(id: modelPoolText) {
                await reloadModelPoolStatuses()
            }
            .onDisappear {
                normalizeStoredModelPool()
            }
        }
    }

    @ViewBuilder
    private var shelfRootContent: some View {
        TabView(selection: $selectedPage) {
            shelfPageContent(for: .continueReading)
                .tabItem {
                    Label("立即阅读", systemImage: "book")
                }
                .tag(MainShelfPage.continueReading)

            shelfPageContent(for: .library)
                .tabItem {
                    Label("书架", systemImage: "books.vertical")
                }
                .tag(MainShelfPage.library)

            shelfPageContent(for: .statistics)
                .tabItem {
                    Label("阅读统计", systemImage: "chart.bar.doc.horizontal")
                }
                .tag(MainShelfPage.statistics)
        }
    }

    @ViewBuilder
    private func shelfPageContent(for page: MainShelfPage) -> some View {
        if !hasAnyLibrarySource {
            missingLibraryRootView
        } else if library.comics.isEmpty && library.series.isEmpty {
            emptyShelfView
        } else if page == .continueReading {
            continueReadingPage
        } else if page == .statistics {
            readingStatisticsPage
        } else {
            libraryPage
        }
    }

    private var navigationTitle: String {
        switch selectedPage {
        case .continueReading:
            return "立即阅读"
        case .library:
            return "MReader 书架"
        case .statistics:
            return "阅读统计"
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
        ScrollView {
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
            .frame(maxWidth: .infinity)
            .frame(minHeight: 460)
        }
        .refreshable {
            await refreshShelfLibraries()
        }
    }

    private var continueReadingComics: [ComicBook] {
        visibleComics
            .filter { $0.hasBeenOpened || readingActivity.hasActivity(for: $0.id) }
            .sorted { $0.lastReadAt > $1.lastReadAt }
    }

    private func sortedComicsByTitle(_ comics: [ComicBook]) -> [ComicBook] {
        comics.sorted { lhs, rhs in
            naturalTitleCompare(lhs.title, comicSortTieBreaker(lhs), rhs.title, comicSortTieBreaker(rhs))
        }
    }

    private func sortedSeriesByTitle(_ seriesItems: [ComicSeries]) -> [ComicSeries] {
        seriesItems.sorted { lhs, rhs in
            naturalTitleCompare(lhs.title, lhs.libraryPath ?? lhs.id.uuidString, rhs.title, rhs.libraryPath ?? rhs.id.uuidString)
        }
    }

    private func comicSortTieBreaker(_ comic: ComicBook) -> String {
        comic.libraryPath ?? comic.komgaBookID ?? comic.sourceURL ?? comic.id.uuidString
    }

    private var libraryPage: some View {
        GeometryReader { geometry in
            let gridLayout = ShelfCardMetrics.gridLayout(for: geometry.size.width)
            let cardWidth = gridLayout.cardWidth
            let displayComics = visibleComics
            let visibleSeriesIDs = Set(displayComics.compactMap(\.seriesID))
            let seriesItems = shelfFilter == .all
                ? library.series
                : library.series.filter { visibleSeriesIDs.contains($0.id) }
            let sortedSeriesItems = sortedSeriesByTitle(seriesItems)
            let rootComics = sortedComicsByTitle(displayComics.filter { $0.seriesID == nil })
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(shelfTitle)
                                .font(.title2.weight(.bold))
                            Spacer()
                            Text("\(displayComics.count + sortedSeriesItems.count) 项")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, ShelfCardMetrics.horizontalPadding)

                        if shelfDisplayMode == .grid {
                            LazyVGrid(columns: gridLayout.columns, spacing: 24) {
                                ForEach(sortedSeriesItems) { series in
                                    seriesGridItem(series, comics: sortedComicsByTitle(displayComics.filter { $0.seriesID == series.id }), cardWidth: cardWidth)
                                }
                                ForEach(rootComics) { comic in
                                    comicGridItem(comic, cardWidth: cardWidth)
                                }
                            }
                            .padding(.horizontal, ShelfCardMetrics.horizontalPadding)
                        } else {
                            LazyVStack(spacing: 12) {
                                ForEach(sortedSeriesItems) { series in
                                    seriesListItem(series, comics: sortedComicsByTitle(displayComics.filter { $0.seriesID == series.id }))
                                }
                                ForEach(rootComics) { comic in
                                    comicListItem(comic)
                                }
                            }
                            .padding(.horizontal, ShelfCardMetrics.horizontalPadding)
                        }
                    }
                }
                .padding(.vertical, 12)
            }
            .refreshable {
                await refreshShelfLibraries()
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: library.comics)
    }

    private func refreshShelfLibraries() async {
        guard !isRefreshingLibraries else { return }
        isRefreshingLibraries = true
        let taskID = backgroundTasks.begin(title: "刷新远程漫画库")
        defer {
            backgroundTasks.finish(taskID)
            isRefreshingLibraries = false
        }
        HapticManager.shared.play(.light)
        await library.syncAllLibrariesAsync()
        hasLibraryRoot = ComicManager.hasSelectedLibraryRoot()
    }

    private var shelfTitle: String {
        switch shelfFilter {
        case .all: return "书架"
        case .inProgress: return "正在阅读"
        case .locked: return "已锁定"
        case .local: return "本地漫画"
        case .komga: return "Komga 漫画"
        case .opds: return "OPDS 漫画"
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
                selectedPage = .library
                Task {
                    await refreshShelfLibraries()
                }
            } label: {
                Label("刷新漫画库", systemImage: "arrow.clockwise")
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

                Button {
                    HapticManager.shared.play(.light)
                    shelfFilter = .local
                } label: {
                    Label("本地漫画", systemImage: shelfFilter == .local ? "checkmark" : "iphone")
                }

                Button {
                    HapticManager.shared.play(.light)
                    shelfFilter = .komga
                } label: {
                    Label("Komga 漫画", systemImage: shelfFilter == .komga ? "checkmark" : "server.rack")
                }

                Button {
                    HapticManager.shared.play(.light)
                    shelfFilter = .opds
                } label: {
                    Label("OPDS 漫画", systemImage: shelfFilter == .opds ? "checkmark" : "books.vertical.circle")
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
                guard let url = ComicManager.localLibraryURLForOpening() else {
                    isLibraryRootPicking = true
                    return
                }
                FileOpenPresenter.shared.open(url)
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
                Button {
                    openReader(comic)
                } label: {
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
                    SeriesDetailView(series: series, comics: comics, allComics: sortedComicsByTitle(visibleComics)) { comicID in
                        _ = library.moveComicToSeries(comicID, toSeries: series.id)
                    } onRemove: { comicID in
                        _ = library.moveComicToSeries(comicID, toSeries: nil)
                    } onImportFiles: {
                        importingSeriesID = series.id
                        beginImport(.files)
                    } onImportFolder: {
                        importingSeriesID = series.id
                        beginImport(.folder)
                    } onOpen: { comic in
                        openReader(comic)
                    } managementMenu: { comic in
                        AnyView(Group {
                            comicManagementMenu(for: comic)
                        })
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
            deleteRequest = .series(series)
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
                Button {
                    openReader(comic)
                } label: {
                    ComicListRow(comic: comic)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            comicManagementMenu(for: comic)
        }
    }

    private func seriesListItem(_ series: ComicSeries, comics: [ComicBook]) -> some View {
        Group {
            if isSelectionMode {
                Button {
                    toggleSeriesSelection(for: series)
                } label: {
                    SeriesListRow(
                        series: series,
                        comics: comics,
                        isSelected: selectedSeriesIDs.contains(series.id)
                    )
                }
            } else {
                NavigationLink {
                    SeriesDetailView(series: series, comics: comics, allComics: sortedComicsByTitle(visibleComics)) { comicID in
                        _ = library.moveComicToSeries(comicID, toSeries: series.id)
                    } onRemove: { comicID in
                        _ = library.moveComicToSeries(comicID, toSeries: nil)
                    } onImportFiles: {
                        importingSeriesID = series.id
                        beginImport(.files)
                    } onImportFolder: {
                        importingSeriesID = series.id
                        beginImport(.folder)
                    } onOpen: { comic in
                        openReader(comic)
                    } managementMenu: { comic in
                        AnyView(Group {
                            comicManagementMenu(for: comic)
                        })
                    }
                    .navigationTransition(.zoom(sourceID: series.id, in: seriesAnimationNamespace))
                } label: {
                    SeriesListRow(series: series, comics: comics)
                        .matchedTransitionSource(id: series.id, in: seriesAnimationNamespace)
                }
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .contextMenu {
            seriesManagementMenu(for: series)
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
                requestDeleteSelectedItems()
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
        Section(header: Text("OpenAI 兼容接口"), footer: Text("Base URL 填到 /v1 即可，例如 https://api.openai.com/v1 或你的代理服务地址。OCR 模式只发送文字；视觉模式会按设置上传当前页或切片图片。")) {
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
                Toggle("启用轮询模型池", isOn: $isModelPoolEnabled)
                Text("轮询模型池")
                TextEditor(text: $modelPoolText)
                    .font(.footnote.monospaced())
                    .frame(minHeight: 100)
                    .scrollContentBackground(.hidden)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text("每行或用逗号填写一个模型。自动去除空行和重复项；留空时只使用默认模型。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if modelPoolStatuses.isEmpty {
                    Text("未配置轮询模型")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(modelPoolStatuses) { status in
                        HStack(spacing: 8) {
                            Image(systemName: status.isRateLimited ? "exclamationmark.circle.fill" : (status.isCurrent ? "checkmark.circle.fill" : "circle"))
                                .foregroundStyle(status.isRateLimited ? .orange : (status.isCurrent ? .green : .secondary))
                            Text(status.modelName)
                                .font(.footnote.monospaced())
                            Spacer()
                            Text(modelPoolStatusLabel(status))
                                .font(.caption)
                                .foregroundStyle(status.isRateLimited ? .orange : .secondary)
                            Button(status.isCurrent ? "已选择" : "切换") {
                                Task {
                                    await AIModelPoolManager.shared.selectModel(status.modelName, poolText: modelPoolText)
                                    await reloadModelPoolStatuses()
                                }
                            }
                            .buttonStyle(.borderless)
                            .disabled(status.isCurrent || status.isRateLimited || !isModelPoolEnabled)
                        }
                    }
                }

                Button("立即清除限流状态") {
                    Task {
                        await AIModelPoolManager.shared.clearRateLimits()
                        await reloadModelPoolStatuses()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!isModelPoolEnabled || AIModelPoolManager.normalizedModels(from: modelPoolText).isEmpty)
            }
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
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("视觉翻译 Prompt 模板")
                    Spacer()
                    Button("恢复默认") {
                        visionTranslationPromptTemplate = AITranslator.defaultVisionTranslationPromptTemplate
                    }
                    .buttonStyle(.bordered)
                }
                TextEditor(text: $visionTranslationPromptTemplate)
                    .font(.footnote.monospaced())
                    .frame(minHeight: 260)
                    .scrollContentBackground(.hidden)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text("可用占位符：{targetLanguage}")
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

    private var mediaSourceSettingsSection: some View {
        Section(header: Text("漫画媒体库")) {
            NavigationLink {
                MediaSourceSettingsView(library: library)
            } label: {
                Label("Komga / OPDS", systemImage: "server.rack")
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
            Toggle("4 小时静止屏幕保护", isOn: $isBurnInProtectionEnabled)
        }
    }

    private var backupSettingsSection: some View {
        Section(header: Text("备份与恢复"), footer: Text("备份 AI 接口、模型池、翻译显示、阅读目标、交互设置和远程服务器配置。备份包含 API Key、密码或 Token，请妥善保管。漫画文件、阅读进度和缓存不包含在内。")) {
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

    private func requestDeleteSelectedItems() {
        guard !selectedComicIDs.isEmpty || !selectedSeriesIDs.isEmpty else { return }
        HapticManager.shared.play(.heavy)
        deleteRequest = .selection(comics: selectedComicIDs, series: selectedSeriesIDs)
    }

    private func performConfirmedDelete() {
        guard let request = deleteRequest else { return }
        HapticManager.shared.play(.heavy)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            switch request {
            case .comic(let comic):
                library.delete(id: comic.id)
            case .series(let series):
                library.deleteSeries(id: series.id)
            case .selection(let comicIDs, let seriesIDs):
                for seriesID in seriesIDs {
                    library.deleteSeries(id: seriesID)
                }
                for comicID in comicIDs {
                    library.delete(id: comicID)
                }
            }
            selectedComicIDs.removeAll()
            selectedSeriesIDs.removeAll()
            isSelectionMode = false
        }
        deleteRequest = nil
    }

    private func performConfirmedKomgaHide() {
        guard let comic = hideKomgaRequest else { return }
        HapticManager.shared.play(.medium)
        KomgaProvider.hideComic(comic, sourceName: KomgaProvider.sourceName(for: comic))
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            hiddenKomgaVersion += 1
        }
        library.refreshVisibility()
        hideKomgaRequest = nil
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
        ReaderContainerView(comic: comic) { updatedComic in
            library.update(updatedComic)
        }
    }

    private func openReader(_ comic: ComicBook) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            selectedReaderComic = comic
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

        if comic.sourceType == .komga {
            Button(role: .destructive) {
                HapticManager.shared.play(.medium)
                hideKomgaRequest = comic
            } label: {
                Label("隐藏", systemImage: "eye.slash")
            }
        }

        Button(role: .destructive) {
            HapticManager.shared.play(.heavy)
            deleteRequest = .comic(comic)
        } label: {
            Label("删除", systemImage: "trash")
        }
    }

    private func folderURL(for comic: ComicBook) -> URL? {
        guard comic.sourceType == .local else { return nil }
        return try? ComicManager.resolveBookmark(comic.bookmarkData)
    }
    
    private func importComicsOrFolder(from urls: [URL], seriesID: UUID? = nil, securityBox: SecurityScopeBox? = nil) {
        let taskID = backgroundTasks.begin(
            title: urls.count > 1 ? "导入 \(urls.count) 个项目" : "导入并解析",
            detail: urls.first?.lastPathComponent,
            progress: 0
        )
        Task {
            var importedCount = 0
            var failedCount = 0
            var failureReason: String?
            defer {
                securityBox?.release()
                Task { @MainActor in
                    backgroundTasks.finish(taskID)
                }
            }

            let seriesDestinationRoot = await MainActor.run { () -> URL? in
                guard let seriesID,
                      let path = library.series.first(where: { $0.id == seriesID })?.libraryPath else { return nil }
                return URL(fileURLWithPath: path, isDirectory: true)
            }

            for (urlIndex, url) in urls.enumerated() {
                await MainActor.run {
                    backgroundTasks.update(
                        taskID,
                        detail: url.lastPathComponent,
                        progress: Double(urlIndex) / Double(max(urls.count, 1))
                    )
                }
                let isDirectory = await Task.detached(priority: .utility) {
                    Self.isDirectoryURL(url)
                }.value

                if isDirectory {
                    let folderInspection = await Task.detached(priority: .utility) {
                        ComicManager.inspectImportFolder(url)
                    }.value

                    if !folderInspection.hasDirectImages && !folderInspection.importableChildren.isEmpty {
                        let targetSeriesID = await MainActor.run { () -> UUID? in
                            if let seriesID {
                                return seriesID
                            }
                            return library.addSeries(title: url.lastPathComponent)?.id
                        }

                        guard let targetSeriesID else {
                            failedCount += folderInspection.importableChildren.count
                            continue
                        }

                        let targetRoot = await MainActor.run { () -> URL? in
                            guard let path = library.series.first(where: { $0.id == targetSeriesID })?.libraryPath else { return nil }
                            return URL(fileURLWithPath: path, isDirectory: true)
                        }

                        for (childIndex, childURL) in folderInspection.importableChildren.enumerated() {
                            await MainActor.run {
                                backgroundTasks.update(
                                    taskID,
                                    detail: childURL.lastPathComponent,
                                    progress: Double(childIndex) / Double(max(folderInspection.importableChildren.count, 1))
                                )
                            }
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
                        continue
                    }
                }

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

            await MainActor.run {
                if importedCount == 0 && failedCount > 0 {
                    HapticManager.shared.play(.error)
                    importError = failureReason?.isEmpty == false ? failureReason! : "没有找到可读取的图片，或压缩包/PDF 解析失败。当前支持 ZIP、CBZ、EPUB、PDF 和图片文件夹。"
                } else if failedCount > 0 {
                    HapticManager.shared.play(.warning)
                    importError = "已导入 \(importedCount) 个项目，\(failedCount) 个项目失败。失败项目可能不包含可读取图片或压缩包已损坏。"
                } else {
                    HapticManager.shared.play(.success)
                }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                    selectedPage = .library
                }
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

    private func makeSettingsBackup() -> MReaderSettingsBackup {
        let mediaSources = KomgaProvider.loadSources().map { source in
            MediaSourceBackup(source: source, apiKey: KomgaProvider.apiKey(for: source.id))
        }
        return MReaderSettingsBackup(
            openAIAPIKey: apiKey,
            openAIBaseURL: baseURL,
            openAIModel: modelName,
            aiModelPool: modelPoolText,
            isAIModelPoolEnabled: isModelPoolEnabled,
            translationTargetLanguage: translationTargetLanguage,
            translationPromptTemplate: translationPromptTemplate,
            visionTranslationPromptTemplate: visionTranslationPromptTemplate,
            isHapticFeedbackEnabled: isHapticFeedbackEnabled,
            mediaSources: mediaSources,
            translationColorStyle: translationColorStyleRaw,
            isAITranslationBorderProgressEnabled: isAITranslationBorderProgressEnabled,
            isOCRDebugBoxesEnabled: isOCRDebugBoxesEnabled,
            readingDailyPageGoal: readingDailyPageGoal,
            isBurnInProtectionEnabled: isBurnInProtectionEnabled
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
            modelPoolText = backup.aiModelPool ?? ""
            isModelPoolEnabled = backup.isAIModelPoolEnabled ?? true
            translationTargetLanguage = backup.translationTargetLanguage
            translationPromptTemplate = backup.translationPromptTemplate ?? AITranslator.defaultTranslationPromptTemplate
            visionTranslationPromptTemplate = backup.visionTranslationPromptTemplate ?? AITranslator.defaultVisionTranslationPromptTemplate
            isHapticFeedbackEnabled = backup.isHapticFeedbackEnabled
            translationColorStyleRaw = backup.translationColorStyle ?? translationColorStyleRaw
            isAITranslationBorderProgressEnabled = backup.isAITranslationBorderProgressEnabled ?? isAITranslationBorderProgressEnabled
            isOCRDebugBoxesEnabled = backup.isOCRDebugBoxesEnabled ?? isOCRDebugBoxesEnabled
            readingDailyPageGoal = min(max(backup.readingDailyPageGoal ?? readingDailyPageGoal, 0), 5_000)
            isBurnInProtectionEnabled = backup.isBurnInProtectionEnabled ?? isBurnInProtectionEnabled
            try restoreMediaSources(from: backup.mediaSources ?? [])
            Task {
                await library.syncAllLibrariesAsync()
            }
            HapticManager.shared.play(.success)
            settingsRestoreNotice = SettingsRestoreNotice(title: "恢复成功", message: "设置备份已恢复。")
        } catch {
            HapticManager.shared.play(.error)
            settingsRestoreNotice = SettingsRestoreNotice(
                title: "恢复失败",
                message: "设置备份恢复失败：\(error.localizedDescription)"
            )
        }
    }

    private func restoreMediaSources(from backups: [MediaSourceBackup]) throws {
        guard !backups.isEmpty else { return }
        var sources = KomgaProvider.loadSources()
        for backup in backups {
            let source = backup.mediaSource
            sources.removeAll { existing in
                existing.id == source.id || (existing.type == source.type && existing.baseURL == source.baseURL)
            }
            sources.append(source)
            if let apiKey = backup.apiKey, !apiKey.isEmpty {
                try KomgaProvider.saveAPIKey(apiKey, for: source.id)
            }
        }
        try KomgaProvider.saveSources(sources)
    }

    private func reloadModelPoolStatuses() async {
        let statuses = await AIModelPoolManager.shared.statuses(poolText: modelPoolText)
        await MainActor.run {
            modelPoolStatuses = statuses
        }
    }

    private func modelPoolStatusLabel(_ status: AIModelPoolStatus) -> String {
        if status.isRateLimited {
            return "已限流，明日 0 点恢复"
        }
        if status.isCurrent {
            return "当前使用中"
        }
        return "可用"
    }

    private func normalizeStoredModelPool() {
        let normalized = AIModelPoolManager.normalizedModels(from: modelPoolText)
            .joined(separator: "\n")
        if modelPoolText != normalized {
            modelPoolText = normalized
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

fileprivate struct FolderPicker: UIViewControllerRepresentable {
    fileprivate let onPick: (URL, SecurityScopeBox) -> Void
    fileprivate let onCancel: () -> Void
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

    fileprivate final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: FolderPicker
        fileprivate var securityBox: SecurityScopeBox?

        init(parent: FolderPicker) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first {
                let box = SecurityScopeBox()
                _ = box.hold(url)
                securityBox = box
                parent.onPick(url, box)
            } else {
                parent.onCancel()
            }
            parent.dismiss()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            securityBox?.release()
            securityBox = nil
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

    static func gridLayout(for containerWidth: CGFloat) -> (columns: [GridItem], cardWidth: CGFloat) {
        if UIDevice.current.userInterfaceIdiom == .phone {
            let width = cardWidth(for: containerWidth)
            return (
                [
                    GridItem(.fixed(width), spacing: columnSpacing),
                    GridItem(.fixed(width), spacing: columnSpacing)
                ],
                width
            )
        }

        let preferredWidth: CGFloat = 184
        let availableWidth = max(preferredWidth, containerWidth - horizontalPadding * 2)
        let columnCount = max(3, Int((availableWidth + columnSpacing) / (preferredWidth + columnSpacing)))
        let width = floor((availableWidth - CGFloat(columnCount - 1) * columnSpacing) / CGFloat(columnCount))
        let columns = Array(repeating: GridItem(.fixed(width), spacing: columnSpacing), count: columnCount)
        return (columns, width)
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

            ProgressView(
                value: Double(ComicReadingProgress.completedPages(for: comic)),
                total: Double(max(comic.totalPages, 1))
            )
                .tint(comicProgressTint(comic))
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
    case .komga:
        return "Komga"
    case .opds:
        return "OPDS"
    }
}

private func comicProgressTint(_ comic: ComicBook) -> Color {
    ComicReadingProgress.isFinished(comic)
        ? Color(red: 52.0 / 255, green: 199.0 / 255, blue: 89.0 / 255)
        : Color.accentColor
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

                ProgressView(
                    value: Double(ComicReadingProgress.completedPages(for: comic)),
                    total: Double(max(comic.totalPages, 1))
                )
                    .tint(comicProgressTint(comic))

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

struct SeriesListRow: View {
    let series: ComicSeries
    let comics: [ComicBook]
    var isSelected = false

    private var covers: ArraySlice<ComicBook> {
        comics.prefix(3)
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                if covers.isEmpty {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "folder")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                        }
                } else {
                    ForEach(Array(covers.enumerated()), id: \.element.id) { index, comic in
                        CoverImageView(path: comic.coverImagePath)
                            .frame(width: 58, height: 84)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .rotationEffect(.degrees(Double(index - 1) * 3))
                            .offset(x: CGFloat(index) * 3 - 3, y: CGFloat(index) * -2 + 2)
                    }
                }
            }
            .frame(width: 66, height: 92)
            .clipped()
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 8) {
                Text(series.title)
                    .font(.headline)
                    .lineLimit(2)

                ProgressView(
                    value: Double(comics.filter(\.hasBeenOpened).count),
                    total: Double(max(comics.count, 1))
                )
                .tint(!comics.isEmpty && comics.allSatisfy(ComicReadingProgress.isFinished) ? Color(red: 52.0 / 255, green: 199.0 / 255, blue: 89.0 / 255) : .accentColor)

                Text("\(comics.count) 章 · \(comics.reduce(0) { $0 + $1.totalPages }) 页")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
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

            ProgressView(
                value: Double(comics.filter(\.hasBeenOpened).count),
                total: Double(max(comics.count, 1))
            )
                .tint(!comics.isEmpty && comics.allSatisfy(ComicReadingProgress.isFinished) ? Color(red: 52.0 / 255, green: 199.0 / 255, blue: 89.0 / 255) : .accentColor)
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
        "\(ComicReadingProgress.completedPages(for: comic)) / \(comic.totalPages)"
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

                ProgressView(
                    value: Double(ComicReadingProgress.completedPages(for: comic)),
                    total: Double(max(comic.totalPages, 1))
                )
                    .tint(comicProgressTint(comic))

                Text(comic.hasBeenOpened ? "阅读进度 \(progressText)" : "尚未阅读")
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

private struct ReadingStatisticsSnapshot {
    struct DailyActivity: Identifiable {
        let id = UUID()
        let date: Date
        let minutes: Int
        let pages: Int
        let hasRead: Bool
    }

    let todayMinutes: Int
    let todayPages: Int
    let todayCompletedCount: Int
    let todayGoalProgress: Double
    let weekGoalProgress: Double
    let currentStreak: Int
    let longestStreak: Int
    let sevenDayActivity: [DailyActivity]
    let thirtyDayActivity: [DailyActivity]
    let topComics: [ComicBook]

    init(comics: [ComicBook], activityDays: [ReadingActivityDay], dailyPageGoal: Int = 40, calendar: Calendar = .current) {
        let activeComicIDs = Set(activityDays.flatMap { day in
            Array(day.comicSeconds.keys) + Array(day.comicPages.keys) + Array(day.completedComicIDs)
        })
        let activeComics = comics.filter { $0.hasBeenOpened || activeComicIDs.contains($0.id) }
        let todayKey = ReadingActivityStore.dateKey(for: Date(), calendar: calendar)
        let todayRecord = activityDays.first { $0.dateKey == todayKey }
        let todayPages = todayRecord?.pages ?? 0
        let todaySeconds = min(max(todayRecord?.seconds ?? 0, 0), 86_400)
        let todayCompleted = todayRecord?.completedComicIDs.count ?? 0
        let lastSevenDates = Self.currentWeekDates(calendar: calendar)
        let lastThirtyDates = Self.currentMonthDatesThroughToday(calendar: calendar)
        let sevenDayActivity = lastSevenDates.map { date in
            Self.activity(for: date, activityDays: activityDays, calendar: calendar)
        }
        let thirtyDayActivity = lastThirtyDates.map { date in
            Self.activity(for: date, activityDays: activityDays, calendar: calendar)
        }
        let weekPages = sevenDayActivity.reduce(0) { $0 + $1.pages }
        let readDays = Set(activityDays.compactMap { day -> Date? in
            guard day.seconds > 0 || day.pages > 0 else { return nil }
            return Self.date(from: day.dateKey, calendar: calendar)
        })

        self.todayMinutes = todaySeconds > 0 ? max(1, Int(ceil(Double(todaySeconds) / 60))) : 0
        self.todayPages = todayPages
        self.todayCompletedCount = todayCompleted
        let clampedDailyGoal = max(dailyPageGoal, 0)
        self.todayGoalProgress = clampedDailyGoal == 0 ? 1 : Self.clampedProgress(Double(todayPages) / Double(clampedDailyGoal))
        self.weekGoalProgress = clampedDailyGoal == 0 ? 1 : Self.clampedProgress(Double(weekPages) / Double(clampedDailyGoal * 7))
        self.currentStreak = Self.currentStreak(readDays: readDays, calendar: calendar)
        self.longestStreak = Self.longestStreak(readDays: readDays, calendar: calendar)
        self.sevenDayActivity = sevenDayActivity
        self.thirtyDayActivity = thirtyDayActivity
        self.topComics = activeComics.sorted {
            let lhsID = $0.id
            let rhsID = $1.id
            let lhsSeconds = activityDays.reduce(0) { $0 + ($1.comicSeconds[lhsID] ?? 0) }
            let rhsSeconds = activityDays.reduce(0) { $0 + ($1.comicSeconds[rhsID] ?? 0) }
            if lhsSeconds != rhsSeconds { return lhsSeconds > rhsSeconds }
            let lhsPages = activityDays.reduce(0) { $0 + ($1.comicPages[lhsID] ?? 0) }
            let rhsPages = activityDays.reduce(0) { $0 + ($1.comicPages[rhsID] ?? 0) }
            if lhsPages != rhsPages { return lhsPages > rhsPages }
            return $0.lastReadAt > $1.lastReadAt
        }
        .prefix(5)
        .map { $0 }
    }

    static func completedPages(for comic: ComicBook) -> Int {
        ComicReadingProgress.completedPages(for: comic)
    }

    static func progress(for comic: ComicBook) -> Double {
        guard comic.totalPages > 0 else { return 0 }
        return clampedProgress(Double(completedPages(for: comic)) / Double(comic.totalPages))
    }

    static func estimatedMinutes(forPages pages: Int) -> Int {
        guard pages > 0 else { return 0 }
        return max(1, Int(ceil(Double(pages) / 2.2)))
    }

    private static func clampedProgress(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private static func currentWeekDates(calendar: Calendar) -> [Date] {
        var mondayCalendar = calendar
        mondayCalendar.firstWeekday = 2
        let today = calendar.startOfDay(for: Date())
        let weekday = mondayCalendar.component(.weekday, from: today)
        let daysFromMonday = (weekday + 5) % 7
        let monday = mondayCalendar.date(byAdding: .day, value: -daysFromMonday, to: today) ?? today
        return (0..<7).compactMap { offset in
            mondayCalendar.date(byAdding: .day, value: offset, to: monday)
        }
    }

    private static func currentMonthDatesThroughToday(calendar: Calendar) -> [Date] {
        let today = calendar.startOfDay(for: Date())
        let day = max(calendar.component(.day, from: today), 1)
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: today)) ?? today
        return (0..<day).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: startOfMonth)
        }
    }

    private static func activity(for date: Date, activityDays: [ReadingActivityDay], calendar: Calendar) -> DailyActivity {
        let key = ReadingActivityStore.dateKey(for: date, calendar: calendar)
        let record = activityDays.first { $0.dateKey == key }
        let seconds = record?.seconds ?? 0
        let pages = record?.pages ?? 0
        return DailyActivity(
            date: date,
            minutes: seconds > 0 ? max(1, Int(ceil(Double(seconds) / 60))) : 0,
            pages: pages,
            hasRead: seconds > 0 || pages > 0
        )
    }

    private static func date(from key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func currentStreak(readDays: Set<Date>, calendar: Calendar) -> Int {
        var streak = 0
        var cursor = calendar.startOfDay(for: Date())
        while readDays.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }

    private static func longestStreak(readDays: Set<Date>, calendar: Calendar) -> Int {
        let sortedDays = readDays.sorted()
        guard !sortedDays.isEmpty else { return 0 }
        var longest = 1
        var current = 1
        for index in sortedDays.indices.dropFirst() {
            let previous = sortedDays[sortedDays.index(before: index)]
            let dayGap = calendar.dateComponents([.day], from: previous, to: sortedDays[index]).day ?? 0
            if dayGap == 1 {
                current += 1
                longest = max(longest, current)
            } else if dayGap > 1 {
                current = 1
            }
        }
        return longest
    }
}

struct ReadingStatisticsView: View {
    let comics: [ComicBook]
    @ObservedObject private var activityStore = ReadingActivityStore.shared
    @AppStorage("reading_daily_page_goal") private var dailyPageGoal = 40.0

    private var snapshot: ReadingStatisticsSnapshot {
        ReadingStatisticsSnapshot(
            comics: comics,
            activityDays: activityStore.days,
            dailyPageGoal: Int(dailyPageGoal.rounded())
        )
    }

    var body: some View {
        let stats = snapshot
        GeometryReader { proxy in
            let layout = ReadingStatisticsLayout(availableWidth: proxy.size.width)

            ScrollView {
                LazyVGrid(columns: layout.columns, alignment: .leading, spacing: layout.spacing) {
                    TodaySummaryCard(stats: stats, dailyPageGoal: Int(dailyPageGoal.rounded()))
                        .gridCellColumns(layout.columnCount)

                    ReadingGoalCard(goal: $dailyPageGoal)
                        .frame(minHeight: layout.secondaryCardHeight)

                    ReadingRingsCard(stats: stats, dailyPageGoal: Int(dailyPageGoal.rounded()))
                        .frame(minHeight: layout.secondaryCardHeight)
                        .gridCellColumns(layout.ringsColumnSpan)

                    SevenDayActivityCard(activity: stats.sevenDayActivity)
                        .frame(minHeight: layout.activityCardHeight)
                        .gridCellColumns(layout.activityColumnSpan)

                    ThirtyDayDotsCard(
                        activity: stats.thirtyDayActivity,
                        currentStreak: stats.currentStreak,
                        longestStreak: stats.longestStreak
                    )
                    .frame(minHeight: layout.activityCardHeight)

                    TopReadingComicsCard(comics: stats.topComics)
                        .gridCellColumns(layout.topComicsColumnSpan)
                }
                .frame(maxWidth: layout.maximumContentWidth)
                .padding(.horizontal, layout.horizontalPadding)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity)
            }
        }
        .background(FitnessPalette.pageBackground.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}

private struct ReadingStatisticsLayout {
    let availableWidth: CGFloat

    var isThreeColumn: Bool { availableWidth >= 1_180 }
    var isTwoColumn: Bool { availableWidth >= 700 && !isThreeColumn }
    var columnCount: Int { isThreeColumn ? 3 : (isTwoColumn ? 2 : 1) }
    var spacing: CGFloat { isThreeColumn ? 20 : 16 }
    var horizontalPadding: CGFloat { isThreeColumn ? 28 : (isTwoColumn ? 22 : 16) }
    var maximumContentWidth: CGFloat { isThreeColumn ? 1_440 : 1_080 }

    var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 0), spacing: spacing, alignment: .top),
            count: columnCount
        )
    }

    var ringsColumnSpan: Int { isThreeColumn ? 2 : 1 }
    var activityColumnSpan: Int { isThreeColumn ? 2 : (isTwoColumn ? 2 : 1) }
    var topComicsColumnSpan: Int { isThreeColumn ? 3 : 1 }
    var secondaryCardHeight: CGFloat? { columnCount > 1 ? 224 : nil }
    var activityCardHeight: CGFloat? { columnCount > 1 ? 216 : nil }
}

private enum FitnessPalette {
    static let move = Color(red: 1, green: 45.0 / 255, blue: 85.0 / 255)
    static let exercise = Color(red: 167.0 / 255, green: 252.0 / 255, blue: 0)
    static let stand = Color(red: 0, green: 199.0 / 255, blue: 1)
    static let pageBackground = Color.black
    static let cardBackground = Color(red: 28.0 / 255, green: 28.0 / 255, blue: 30.0 / 255)
    static let raisedCardBackground = Color(red: 44.0 / 255, green: 44.0 / 255, blue: 46.0 / 255)
    static let track = Color(red: 56.0 / 255, green: 56.0 / 255, blue: 58.0 / 255)
    static let primaryText = Color.white
    static let secondaryText = Color(red: 235.0 / 255, green: 235.0 / 255, blue: 245.0 / 255).opacity(0.6)
    static let weakText = Color(red: 235.0 / 255, green: 235.0 / 255, blue: 245.0 / 255).opacity(0.3)
}

private struct StatisticsCard<Content: View>: View {
    let content: Content
    let isRaised: Bool

    init(isRaised: Bool = false, @ViewBuilder content: () -> Content) {
        self.isRaised = isRaised
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isRaised ? FitnessPalette.raisedCardBackground : FitnessPalette.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct TodaySummaryCard: View {
    let stats: ReadingStatisticsSnapshot
    let dailyPageGoal: Int

    var body: some View {
        StatisticsCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label("今日摘要", systemImage: "sun.max.fill")
                        .font(.headline)
                        .foregroundStyle(FitnessPalette.primaryText)
                    Spacer()
                    Text("目标 \(dailyPageGoal) 页")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(FitnessPalette.secondaryText)
                }

                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    TodayMetric(value: "\(stats.todayMinutes)", title: "分钟", color: FitnessPalette.move)
                    TodayMetric(value: "\(stats.todayPages)", title: "页", color: FitnessPalette.exercise)
                    TodayMetric(value: "\(stats.todayCompletedCount)", title: "完成", color: FitnessPalette.stand)
                }

                FitnessProgressBar(progress: stats.todayGoalProgress, tint: FitnessPalette.move)
                    .frame(height: 8)
            }
        }
    }
}

private struct TodayMetric: View {
    let value: String
    let title: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .monospacedDigit()
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(FitnessPalette.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FitnessProgressBar: View {
    let progress: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(FitnessPalette.track)
                Capsule()
                    .fill(tint)
                    .frame(width: proxy.size.width * min(max(progress, 0), 1))
            }
        }
    }
}

private struct ReadingGoalCard: View {
    @Binding var goal: Double

    private var roundedGoal: Int {
        Int(goal.rounded())
    }

    var body: some View {
        StatisticsCard(isRaised: true) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("每日目标", systemImage: "target")
                        .font(.headline)
                    Spacer()
                    Text("\(roundedGoal) 页")
                        .font(.system(.headline, design: .rounded).weight(.bold))
                        .monospacedDigit()
                }

                ReadingGoalArcControl(goal: $goal)
                    .frame(height: 106)

                HStack {
                    Text("0")
                    Spacer()
                    Text("5000")
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(FitnessPalette.secondaryText)
            }
        }
    }
}

private struct ReadingGoalArcControl: View {
    @Binding var goal: Double
    @State private var isDraggingThumb = false

    private var progress: Double {
        min(max(goal / 5000, 0), 1)
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let radius = min(size.width / 2 - 28, size.height - 28)
            let center = CGPoint(x: size.width / 2, y: size.height - 8)
            let angle = Angle.degrees(180 + progress * 180)
            let thumb = point(on: center, radius: radius, angle: angle)
            let thumbSize: CGFloat = isDraggingThumb ? 34 : 24

            ZStack {
                ArcShape(startAngle: .degrees(180), endAngle: .degrees(360))
                    .stroke(FitnessPalette.track, style: StrokeStyle(lineWidth: 11, lineCap: .round))
                ArcShape(startAngle: .degrees(180), endAngle: angle)
                    .stroke(FitnessPalette.move.gradient, style: StrokeStyle(lineWidth: 11, lineCap: .round))
                Circle()
                    .fill(FitnessPalette.move)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: FitnessPalette.move.opacity(0.4), radius: 10)
                    .padding(18)
                    .contentShape(Circle())
                    .position(thumb)
                    .animation(.spring(response: 0.22, dampingFraction: 0.78), value: isDraggingThumb)
                    .gesture(
                        LongPressGesture(minimumDuration: 0.18, maximumDistance: 18)
                            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("readingGoalArc")))
                            .onChanged { value in
                                switch value {
                                case .first(true):
                                    if !isDraggingThumb {
                                        isDraggingThumb = true
                                        HapticManager.shared.play(.medium)
                                    }
                                case .second(true, let drag?):
                                    guard isDraggingThumb else { return }
                                    goal = goalValue(for: drag.location, center: center, radius: radius)
                                default:
                                    break
                                }
                            }
                            .onEnded { _ in
                                isDraggingThumb = false
                            }
                    )
                VStack(spacing: 2) {
                    Text("\(Int(goal.rounded()))")
                        .font(.system(size: 27, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("页/天")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(FitnessPalette.secondaryText)
                }
                .position(x: center.x, y: max(44, center.y - radius * 0.42))
            }
            .coordinateSpace(name: "readingGoalArc")
        }
    }

    private func point(on center: CGPoint, radius: CGFloat, angle: Angle) -> CGPoint {
        let radians = CGFloat(angle.radians)
        return CGPoint(
            x: center.x + cos(radians) * radius,
            y: center.y + sin(radians) * radius
        )
    }

    private func goalValue(for location: CGPoint, center: CGPoint, radius: CGFloat) -> Double {
        let leftX = center.x - radius
        let rightX = center.x + radius
        let xProgress = Double(min(max((location.x - leftX) / max(rightX - leftX, 1), 0), 1))
        let rawValue = xProgress * 5000
        return min(max((rawValue / 10).rounded() * 10, 0), 5000)
    }
}

private struct ArcShape: Shape {
    var startAngle: Angle
    var endAngle: Angle

    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width / 2 - 28, rect.height - 28)
        let center = CGPoint(x: rect.midX, y: rect.maxY - 8)
        var path = Path()
        path.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
        return path
    }
}

private struct ReadingRingsCard: View {
    let stats: ReadingStatisticsSnapshot
    let dailyPageGoal: Int

    var body: some View {
        StatisticsCard {
            VStack(alignment: .leading, spacing: 16) {
                Label("阅读圆环", systemImage: "circle.circle.fill")
                    .font(.headline)
                HStack(spacing: 18) {
                    ReadingRing(progress: stats.todayGoalProgress, tint: FitnessPalette.move, value: "\(stats.todayPages)", caption: "今日 / \(dailyPageGoal)")
                    ReadingRing(progress: stats.weekGoalProgress, tint: FitnessPalette.exercise, value: "\(Int(stats.weekGoalProgress * 100))%", caption: "本周目标")
                    ReadingRing(progress: min(Double(stats.currentStreak) / 7, 1), tint: FitnessPalette.stand, value: "\(stats.currentStreak)", caption: "连续天数")
                }
            }
        }
    }
}

private struct ReadingRing: View {
    let progress: Double
    let tint: Color
    let value: String
    let caption: String

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(tint.opacity(0.16), lineWidth: 9)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(tint.gradient, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(value)
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .monospacedDigit()
            }
            .frame(width: 74, height: 74)

            Text(caption)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(FitnessPalette.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct SevenDayActivityCard: View {
    let activity: [ReadingStatisticsSnapshot.DailyActivity]
    @State private var selectedID: UUID?

    private var selectedActivity: ReadingStatisticsSnapshot.DailyActivity? {
        activity.first { $0.id == selectedID } ?? activity.first { Calendar.current.isDateInToday($0.date) } ?? activity.last
    }

    private var maxMinutes: Int {
        max(activity.map(\.minutes).max() ?? 1, 1)
    }

    var body: some View {
        StatisticsCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("本周", systemImage: "chart.bar.fill")
                        .font(.headline)
                    Spacer()
                    if let selectedActivity {
                        Text("\(selectedActivity.minutes) 分钟 · \(selectedActivity.pages) 页")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(FitnessPalette.secondaryText)
                    }
                }

                HStack(alignment: .bottom, spacing: 9) {
                    ForEach(activity) { day in
                        Button {
                            selectedID = day.id
                            HapticManager.shared.play(.light)
                        } label: {
                            VStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(day.id == selectedActivity?.id ? FitnessPalette.move : FitnessPalette.move.opacity(0.28))
                                    .frame(height: barHeight(for: day))
                                    .frame(maxHeight: 88, alignment: .bottom)
                                Text(weekdayText(for: day.date))
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(day.id == selectedActivity?.id ? FitnessPalette.primaryText : FitnessPalette.secondaryText)
                            }
                            .frame(maxWidth: .infinity, minHeight: 112, alignment: .bottom)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func barHeight(for day: ReadingStatisticsSnapshot.DailyActivity) -> CGFloat {
        guard day.minutes > 0 else { return 8 }
        return 16 + CGFloat(day.minutes) / CGFloat(maxMinutes) * 72
    }

    private func weekdayText(for date: Date) -> String {
        let index = Calendar.current.component(.weekday, from: date)
        return ["日", "一", "二", "三", "四", "五", "六"][max(0, min(index - 1, 6))]
    }
}

private struct ThirtyDayDotsCard: View {
    let activity: [ReadingStatisticsSnapshot.DailyActivity]
    let currentStreak: Int
    let longestStreak: Int

    var body: some View {
        StatisticsCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("本月记录", systemImage: "calendar")
                        .font(.headline)
                    Spacer()
                    Text("连续 \(currentStreak) 天")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(FitnessPalette.secondaryText)
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 10), spacing: 10) {
                    ForEach(activity) { day in
                        CalendarDot(day: day)
                    }
                }

                HStack {
                    Label("最长 \(longestStreak) 天", systemImage: "flame.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(FitnessPalette.move)
                    Spacer()
                    Text("实心圆表示当天阅读")
                        .font(.caption)
                        .foregroundStyle(FitnessPalette.secondaryText)
                }
            }
        }
    }
}

private struct CalendarDot: View {
    let day: ReadingStatisticsSnapshot.DailyActivity

    private var size: CGFloat {
        if day.pages >= 120 { return 16 }
        if day.pages >= 40 { return 13 }
        return day.hasRead ? 10 : 10
    }

    var body: some View {
        Circle()
            .strokeBorder(day.hasRead ? FitnessPalette.stand.opacity(0) : FitnessPalette.weakText, lineWidth: 1.5)
            .background {
                Circle()
                    .fill(day.hasRead ? FitnessPalette.stand.opacity(day.pages >= 40 ? 0.95 : 0.58) : Color.clear)
            }
            .frame(width: size, height: size)
            .frame(width: 22, height: 22)
            .accessibilityLabel(Text("\(day.pages) 页"))
    }
}

private struct TopReadingComicsCard: View {
    let comics: [ComicBook]

    var body: some View {
        StatisticsCard {
            VStack(alignment: .leading, spacing: 14) {
                Label("阅读最多", systemImage: "books.vertical.fill")
                    .font(.headline)

                if comics.isEmpty {
                    ContentUnavailableView("暂无阅读记录", systemImage: "book.closed", description: Text("开始阅读后，这里会显示最常读的漫画。"))
                        .frame(minHeight: 150)
                } else {
                    VStack(spacing: 12) {
                        ForEach(comics) { comic in
                            TopComicRow(comic: comic)
                        }
                    }
                }
            }
        }
    }
}

private struct TopComicRow: View {
    let comic: ComicBook
    @ObservedObject private var activityStore = ReadingActivityStore.shared

    private var pages: Int {
        activityStore.totalPages(for: comic.id)
    }

    private var minutes: Int {
        let seconds = activityStore.totalSeconds(for: comic.id)
        return seconds > 0 ? max(1, Int(ceil(Double(seconds) / 60))) : 0
    }

    var body: some View {
        HStack(spacing: 12) {
            CoverImageView(path: comic.coverImagePath)
                .frame(width: 46, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .clipped()

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text(comic.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(sourceLabel(for: comic))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(FitnessPalette.secondaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(FitnessPalette.track)
                        .clipShape(Capsule())
                }

                FitnessProgressBar(
                    progress: ReadingStatisticsSnapshot.progress(for: comic),
                    tint: ComicReadingProgress.isFinished(comic) ? Color(red: 52 / 255, green: 199 / 255, blue: 89 / 255) : FitnessPalette.exercise
                )
                .frame(height: 5)

                Text("\(minutes) 分钟 · \(pages) / \(comic.totalPages) 页")
                    .font(.caption)
                    .foregroundStyle(FitnessPalette.secondaryText)
            }
        }
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
        let source: CGImageSource?
        if let remoteURL = URL(string: path), OPDSProvider.isCoverReference(remoteURL) {
            guard let data = await OPDSProvider.coverData(for: remoteURL) else { return nil }
            source = CGImageSourceCreateWithData(data as CFData, nil)
        } else if let archiveURL = URL(string: path), ComicManager.isArchivePageURL(archiveURL) {
            guard let data = ComicManager.imageData(forArchivePageURL: archiveURL) else { return nil }
            source = CGImageSourceCreateWithData(data as CFData, nil)
        } else {
            let url = URL(fileURLWithPath: path)
            source = CGImageSourceCreateWithURL(url as CFURL, nil)
        }
        guard let source else { return nil }
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
                        Label("刷新漫画库索引", systemImage: "arrow.clockwise")
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
                            Text(
                                comic.hasBeenOpened
                                    ? "读到 \(ComicReadingProgress.completedPages(for: comic)) / \(comic.totalPages)"
                                    : "尚未阅读"
                            )
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
    let onOpen: (ComicBook) -> Void
    let managementMenu: (ComicBook) -> AnyView

    @Environment(\.dismiss) private var dismiss
    @State private var showAddSheet = false
    @State private var didSpreadChapters = false
    @State private var isClosing = false

    private var sortedComics: [ComicBook] {
        comics.sorted { lhs, rhs in
            naturalTitleCompare(lhs.title, sortTieBreaker(for: lhs), rhs.title, sortTieBreaker(for: rhs))
        }
    }

    private var availableComics: [ComicBook] {
        allComics
            .filter { $0.seriesID != series.id }
            .sorted { lhs, rhs in
                naturalTitleCompare(lhs.title, sortTieBreaker(for: lhs), rhs.title, sortTieBreaker(for: rhs))
            }
    }

    private func sortTieBreaker(for comic: ComicBook) -> String {
        comic.libraryPath ?? comic.komgaBookID ?? comic.sourceURL ?? comic.id.uuidString
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
                    let gridLayout = ShelfCardMetrics.gridLayout(for: geometry.size.width)
                    let cardWidth = gridLayout.cardWidth
                    ScrollView {
                        LazyVGrid(columns: gridLayout.columns, spacing: 24) {
                            ForEach(Array(sortedComics.enumerated()), id: \.element.id) { index, comic in
                                Button {
                                    onOpen(comic)
                                } label: {
                                    ComicCoverCard(comic: comic, cardWidth: cardWidth)
                                }
                                .frame(width: cardWidth, height: ShelfCardMetrics.cardHeight(for: cardWidth), alignment: .top)
                                .contentShape(Rectangle())
                                .clipped()
                                .buttonStyle(.plain)
                                .scaleEffect(didSpreadChapters ? 1 : 0.82)
                                .opacity(didSpreadChapters ? 1 : 0)
                                .rotationEffect(.degrees(didSpreadChapters ? 0 : Double(index.isMultiple(of: 2) ? -5 : 5)))
                                .offset(
                                    x: didSpreadChapters ? 0 : CGFloat(index.isMultiple(of: 2) ? -24 : 24),
                                    y: didSpreadChapters ? 0 : 32
                                )
                                .animation(
                                    .spring(response: 0.7, dampingFraction: 0.84)
                                        .delay(didSpreadChapters ? min(Double(index) * 0.025, 0.22) : 0),
                                    value: didSpreadChapters
                                )
                                .contextMenu {
                                    managementMenu(comic)
                                    Divider()
                                    Button {
                                        HapticManager.shared.play(.medium)
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
        .navigationBarBackButtonHidden(true)
        .onAppear {
            withAnimation(.spring(response: 0.78, dampingFraction: 0.86)) {
                didSpreadChapters = true
            }
        }
        .onDisappear {
            didSpreadChapters = false
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    closeSeries()
                } label: {
                    Label("返回", systemImage: "chevron.backward")
                }
                .disabled(isClosing)
            }
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

    private func closeSeries() {
        guard !isClosing else { return }
        isClosing = true
        HapticManager.shared.play(.light)
        withAnimation(.easeInOut(duration: 0.36)) {
            didSpreadChapters = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) {
            dismiss()
        }
    }
}
