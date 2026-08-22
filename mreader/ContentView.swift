import SwiftUI
import UniformTypeIdentifiers
import UIKit
import ImageIO
import Combine
import LocalAuthentication

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
                return "delete.localComic".localized
            case .komga:
                return "delete.komgaComic".localized
            case .opds:
                return "delete.opdsComic".localized
            }
        case .series:
            return "delete.series".localized
        case .selection:
            return "delete.selection".localized
        }
    }
}

nonisolated struct MReaderSettingsBackup: Codable {
    var version = 10
    var openAIAPIKey: String?
    var openAIBaseURL: String
    var openAIModel: String
    var aiModelPool: String?
    var isAIModelPoolEnabled: Bool?
    var translationTargetLanguage: String
    /// v9 及更老：旧完整 Prompt（只读，不用于新协议）。
    var translationPromptTemplate: String?
    /// v10 起：用户可编辑的“翻译风格要求”（项4）。
    var translationStyleInstructions: String? = nil
    var visionTranslationPromptTemplate: String?
    var isHapticFeedbackEnabled: Bool
    var mediaSources: [MediaSourceBackup]?
    var translationColorStyle: String?
    var isAITranslationBorderProgressEnabled: Bool?
    var isOCRDebugBoxesEnabled: Bool?
    var isOCRVisualVerificationEnabled: Bool? = nil
    var ocrLocalRecognitionMode: String? = nil
    var readingDailyPageGoal: Double?
    var isBurnInProtectionEnabled: Bool?
    var isICloudMetadataSyncEnabled: Bool? = nil
    var aiProviders: [AIProviderBackup]?
    var activeAIProviderID: UUID?
    var containsCredentials: Bool? = nil
}

nonisolated struct AIProviderBackup: Codable, Sendable {
    var profile: AIProviderProfile
    var apiKey: String?
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
    var lanURL: String?
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
        lanURL = source.lanURL
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
            lanURL: lanURL,
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
    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct BackupPasswordRequest: Identifiable {
    enum Purpose {
        case export
        case restore(Data)
    }

    let id = UUID()
    let purpose: Purpose
}

struct ContentView: View {
    @StateObject private var library = ComicLibraryStore()
    @StateObject private var webServer = LocalWebServer()
    @ObservedObject private var readingActivity = ReadingActivityStore.shared
    @ObservedObject private var backgroundTasks = BackgroundTaskCenter.shared
    @ObservedObject private var offlineDownloads = OfflineDownloadManager.shared
    @ObservedObject private var ocrIndexer = OCRLibraryIndexer.shared
    @ObservedObject private var iCloudSync = ICloudMetadataSyncService.shared

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
    @State private var importInfo: String?
    @State private var settingsBackupDocument: SettingsBackupDocument?
    @State private var backupPasswordRequest: BackupPasswordRequest?
    @State private var renamingComic: ComicBook?
    @State private var renameTitle = ""
    @State private var importingSeriesID: UUID?
    @State private var deleteRequest: DeleteRequest?
    @State private var hideKomgaRequest: ComicBook?
    @State private var hiddenKomgaVersion = 0
    @State private var isRefreshingLibraries = false
    @State private var settingsRestoreNotice: SettingsRestoreNotice?
    @State private var libraryLoadNotice: SettingsRestoreNotice?
    @State private var selectedReaderComic: ComicBook?
    @State private var offlineTranslationStartComic: ComicBook?
    @State private var offlineTranslationManagerComic: ComicBook?
    @State private var backgroundTaskDestination: BackgroundTaskDestination?
    @State private var showTranslationPrompt = false
    @State private var showVisionPrompt = false
    @State private var showOCRSearch = false
    @AppStorage("translation_target_language") private var translationTargetLanguage = TranslationTargetLanguage.simplifiedChinese.rawValue
    @AppStorage("translation_style_instructions") private var translationStyleInstructions = AITranslator.defaultTranslationStyleInstructions
    @AppStorage("vision_translation_prompt_template") private var visionTranslationPromptTemplate = AITranslator.defaultVisionTranslationPromptTemplate
    @AppStorage(HapticSettings.isEnabledKey) private var isHapticFeedbackEnabled = true
    @AppStorage("translation_color_style") private var translationColorStyleRaw = "contrast"
    @AppStorage("ai_translation_border_progress_enabled") private var isAITranslationBorderProgressEnabled = true
    @AppStorage("ocr_show_debug_boxes") private var isOCRDebugBoxesEnabled = false
    @AppStorage("ocr_visual_verification_enabled") private var isOCRVisualVerificationEnabled = false
    @AppStorage("ocr_local_recognition_mode") private var ocrLocalRecognitionModeRaw = OCRRecognitionMode.adaptive.rawValue
    @AppStorage("reading_daily_page_goal") private var readingDailyPageGoal = 40.0
    @AppStorage("burn_in_protection_enabled") private var isBurnInProtectionEnabled = true
    @AppStorage(ICloudMetadataSyncService.enabledKey) private var isICloudMetadataSyncEnabled = false
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
            .modifier(shelfToolbarModifiers)
            .onChange(of: selectedPage) { _, _ in
                HapticManager.shared.play(.light)
            }
            .modifier(shelfSheetModifiers)
            .eraseToAnyView()
            .modifier(shelfFileModifiers)
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
                        importError = "error.libraryRootFailed".localized
                    }
                    scopeBox.release()
                } onCancel: {}
            }
            .eraseToAnyView()
            .modifier(alertModifiers)
            .task(id: library.libraryLoadIssues) {
                guard !library.libraryLoadIssues.isEmpty else { return }
                libraryLoadNotice = SettingsRestoreNotice(
                    title: "error.libraryLoad".localized,
                    message: library.libraryLoadIssues.joined(separator: "\n")
                )
            }
            .alert(item: $libraryLoadNotice) { notice in
                Alert(
                    title: Text(notice.title),
                    message: Text(notice.message),
                    dismissButton: .default(Text("common.confirm".localized))
                )
            }
            .sheet(isPresented: $showStorageManager) {
                StorageManagerView(library: library)
            }
            .sheet(item: $offlineTranslationStartComic) { comic in
                OfflineTranslationStartView(
                    comic: comic,
                    currentPageIndex: comic.currentPageIndex,
                    onBackground: { offlineTranslationStartComic = nil }
                )
            }
            .sheet(item: $offlineTranslationManagerComic) { comic in
                OfflineTranslationManagerView(
                    comic: comic,
                    onBackground: { offlineTranslationManagerComic = nil }
                )
            }
            .sheet(item: $backgroundTaskDestination) { destination in
                if case .offlineTranslation(let comicID, _) = destination,
                   let comic = library.comics.first(where: { $0.id == comicID }) {
                    OfflineTranslationProgressView(comic: comic) {
                        backgroundTaskDestination = nil
                    }
                }
            }
            .sheet(isPresented: $showActivity) {
                ShelfActivityView(comics: library.comics)
            }
            .sheet(item: $backupPasswordRequest) { request in
                BackupPasswordView(
                    isCreatingBackup: {
                        if case .export = request.purpose { return true }
                        return false
                    }(),
                    onCancel: {
                        backupPasswordRequest = nil
                    },
                    onSubmit: { password in
                        handleBackupPassword(password, request: request)
                    }
                )
            }
            .sheet(isPresented: $showOCRSearch) {
                OCRSearchView(comics: visibleComics) { result in
                    guard var comic = library.comics.first(where: { $0.id == result.comicID }) else { return }
                    comic.currentPageIndex = min(max(result.pageIndex, 0), max(comic.totalPages - 1, 0))
                    comic.progressUpdatedAt = Date()
                    library.update(comic)
                    openReader(comic)
                }
            }
            .task {
                iCloudSync.start { payload in
                    library.applySyncedMetadata(payload)
                    readingActivity.mergeSyncedDays(payload.activityDays)
                }
                if let payload = await iCloudSync.pull() {
                    library.applySyncedMetadata(payload)
                    readingActivity.mergeSyncedDays(payload.activityDays)
                }
            }
            .task(id: library.isLoaded) {
                guard library.isLoaded else { return }
                library.runStartupRemoteMaintenance()
            }
            .onReceive(library.$comics.debounce(for: .seconds(2), scheduler: RunLoop.main)) { comics in
                iCloudSync.push(comics: comics, activityDays: readingActivity.days)
            }
            .onReceive(readingActivity.$days.debounce(for: .seconds(2), scheduler: RunLoop.main)) { days in
                iCloudSync.push(comics: library.comics, activityDays: days)
            }
        }
    }

    private struct AlertModifiers: ViewModifier {
        @Binding var importError: String?
        @Binding var importInfo: String?
        @Binding var settingsRestoreNotice: SettingsRestoreNotice?
        @Binding var webServerErrorMessage: String?
        @Binding var renamingComic: ComicBook?
        @Binding var renameTitle: String
        @Binding var renamingSeries: ComicSeries?
        @Binding var showNewSeriesAlert: Bool
        @Binding var newSeriesName: String
        @Binding var deleteRequest: DeleteRequest?
        @Binding var hideKomgaRequest: ComicBook?
        var library: ComicLibraryStore
        var performConfirmedDelete: () -> Void
        var performConfirmedKomgaHide: () -> Void

        func body(content: Content) -> some View {
            content
                .alert("error.importFailed".localized, isPresented: Binding(
                    get: { importError != nil },
                    set: { if !$0 { importError = nil } }
                )) {
                    Button("common.confirm".localized, role: .cancel) { importError = nil }
                } message: {
                    Text(importError ?? "")
                }
                .alert("error.importSuccess".localized, isPresented: Binding(
                    get: { importInfo != nil },
                    set: { if !$0 { importInfo = nil } }
                )) {
                    Button("common.confirm".localized, role: .cancel) { importInfo = nil }
                } message: {
                    Text(importInfo ?? "")
                }
                .alert(item: $settingsRestoreNotice) { notice in
                    Alert(
                        title: Text(notice.title),
                        message: Text(notice.message),
                        dismissButton: .default(Text("common.confirm".localized))
                    )
                }
                .alert("import.webServer".localized, isPresented: Binding(
                    get: { webServerErrorMessage != nil },
                    set: { if !$0 { webServerErrorMessage = nil } }
                )) {
                    Button("common.confirm".localized, role: .cancel) { webServerErrorMessage = nil }
                } message: {
                    Text(webServerErrorMessage ?? "")
                }
                .alert("comic.rename".localized, isPresented: Binding(
                    get: { renamingComic != nil },
                    set: { if !$0 { renamingComic = nil } }
                )) {
                    TextField("comic.rename".localized, text: $renameTitle)
                    Button("nav.cancel".localized, role: .cancel) { renamingComic = nil }
                    Button("nav.save".localized) {
                        if let renamingComic {
                            library.rename(id: renamingComic.id, title: renameTitle)
                        }
                        renamingComic = nil
                    }
                }
                .alert("series.rename".localized, isPresented: Binding(
                    get: { renamingSeries != nil },
                    set: { if !$0 { renamingSeries = nil } }
                )) {
                    TextField("series.name".localized, text: $renameTitle)
                    Button("nav.cancel".localized, role: .cancel) { renamingSeries = nil }
                    Button("nav.save".localized) {
                        if let renamingSeries {
                            library.renameSeries(id: renamingSeries.id, title: renameTitle)
                        }
                        renamingSeries = nil
                    }
                }
                .alert("series.new".localized, isPresented: $showNewSeriesAlert) {
                    TextField("series.name".localized, text: $newSeriesName)
                    Button("nav.cancel".localized, role: .cancel) { newSeriesName = "" }
                    Button("series.create".localized) {
                        library.addSeries(title: newSeriesName)
                        showNewSeriesAlert = false
                        newSeriesName = ""
                    }
                } message: {
                    Text("series.newDescription".localized)
                }
                .alert(
                    "common.confirm".localized,
                    isPresented: Binding(
                        get: { deleteRequest != nil },
                        set: { if !$0 { deleteRequest = nil } }
                    )
                ) {
                    Button("common.delete".localized, role: .destructive) {
                        performConfirmedDelete()
                    }
                    Button("nav.cancel".localized, role: .cancel) {
                        deleteRequest = nil
                    }
                } message: {
                    Text(deleteRequest?.message ?? "")
                }
                .confirmationDialog(
                    hideKomgaRequest != nil ? "comic.hideConfirm".localizedFormat(hideKomgaRequest!.title) : "comic.hideConfirmDefault".localized,
                    isPresented: Binding(
                        get: { hideKomgaRequest != nil },
                        set: { if !$0 { hideKomgaRequest = nil } }
                    ),
                    titleVisibility: .visible
                ) {
                    Button("comic.hide".localized, role: .destructive) {
                        performConfirmedKomgaHide()
                    }
                    Button("nav.cancel".localized, role: .cancel) {
                        hideKomgaRequest = nil
                    }
                } message: {
                    Text("comic.hideDescription".localized)
                }
        }
    }

    private var alertModifiers: AlertModifiers {
        AlertModifiers(
            importError: $importError,
            importInfo: $importInfo,
            settingsRestoreNotice: $settingsRestoreNotice,
            webServerErrorMessage: $webServer.errorMessage,
            renamingComic: $renamingComic,
            renameTitle: $renameTitle,
            renamingSeries: $renamingSeries,
            showNewSeriesAlert: $showNewSeriesAlert,
            newSeriesName: $newSeriesName,
            deleteRequest: $deleteRequest,
            hideKomgaRequest: $hideKomgaRequest,
            library: library,
            performConfirmedDelete: performConfirmedDelete,
            performConfirmedKomgaHide: performConfirmedKomgaHide
        )
    }

    // MARK: - Toolbar Modifier

    private struct ShelfToolbarModifiers: ViewModifier {
        @ObservedObject var backgroundTasks: BackgroundTaskCenter
        @Binding var backgroundTaskDestination: BackgroundTaskDestination?
        var shelfActionMenu: ShelfActionMenuContent

        func body(content: Content) -> some View {
            content
                .toolbar {
                    if backgroundTasks.isActive {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            BackgroundTaskIndicator(
                                center: backgroundTasks,
                                onSelect: { backgroundTaskDestination = $0 }
                            )
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        shelfActionMenu
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    EmptyView()
                }
        }
    }

    private struct ShelfActionMenuContent: View {
        @Binding var isSelectionMode: Bool
        @Binding var selectedComicIDs: Set<UUID>
        @Binding var selectedSeriesIDs: Set<UUID>
        @Binding var shelfDisplayMode: ShelfDisplayMode
        @Binding var shelfFilter: ShelfFilter
        @Binding var showSettings: Bool
        @Binding var showStorageManager: Bool
        @Binding var showActivity: Bool
        @Binding var showNewSeriesAlert: Bool
        @Binding var selectedPage: MainShelfPage
        @Binding var showOCRSearch: Bool
        var beginImport: (ImportPickerMode) -> Void
        var refreshShelfLibraries: () async -> Void

        var body: some View {
            Menu {
                Button {
                    HapticManager.shared.play(.light)
                    beginImport(.files)
                } label: {
                    Label("import.files".localized, systemImage: "doc.badge.plus")
                }
                Button {
                    HapticManager.shared.play(.light)
                    beginImport(.folder)
                } label: {
                    Label("import.folder".localized, systemImage: "folder.badge.plus")
                }
                Button {
                    HapticManager.shared.play(.medium)
                    selectedPage = .library
                    Task { await refreshShelfLibraries() }
                } label: {
                    Label("storage.refreshIndex".localized, systemImage: "arrow.clockwise")
                }
                Button {
                    HapticManager.shared.play(.light)
                    showOCRSearch = true
                } label: {
                    Label("ocr.search.title".localized, systemImage: "text.magnifyingglass")
                }
                Button {
                    HapticManager.shared.play(.light)
                    selectedPage = .library
                    showNewSeriesAlert = true
                } label: {
                    Label("series.new".localized, systemImage: "folder.badge.plus")
                }
                Button {
                    HapticManager.shared.play(.medium)
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                        isSelectionMode.toggle()
                        selectedComicIDs.removeAll()
                        selectedSeriesIDs.removeAll()
                    }
                } label: {
                    Label(isSelectionMode ? "nav.done".localized : "common.edit".localized, systemImage: "checkmark.circle")
                }
                Divider()
                Button {
                    HapticManager.shared.play(.light)
                    shelfDisplayMode = .grid
                } label: {
                    Label("shelf.gridMode".localized, systemImage: "square.grid.2x2")
                }
                Button {
                    HapticManager.shared.play(.light)
                    shelfDisplayMode = .list
                } label: {
                    Label("shelf.listMode".localized, systemImage: "list.bullet")
                }
                Divider()
                Menu {
                    FilterButton(title: "shelf.all".localized, icon: "books.vertical", filter: .all, current: $shelfFilter)
                    FilterButton(title: "shelf.inProgress".localized, icon: "clock", filter: .inProgress, current: $shelfFilter)
                    FilterButton(title: "shelf.locked".localized, icon: "lock", filter: .locked, current: $shelfFilter)
                    FilterButton(title: "shelf.local".localized, icon: "iphone", filter: .local, current: $shelfFilter)
                    FilterButton(title: "shelf.komga".localized, icon: "server.rack", filter: .komga, current: $shelfFilter)
                    FilterButton(title: "shelf.opds".localized, icon: "books.vertical.circle", filter: .opds, current: $shelfFilter)
                } label: {
                    Label("shelf.filterCategory".localized, systemImage: "books.vertical")
                }
                Divider()
                Button {
                    HapticManager.shared.play(.light)
                    showSettings = true
                } label: {
                    Label("nav.settings".localized, systemImage: "gearshape")
                }
                Button {
                    HapticManager.shared.play(.light)
                    showStorageManager = true
                } label: {
                    Label("storage.title".localized, systemImage: "externaldrive")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
        }
    }

    private struct FilterButton: View {
        let title: String
        let icon: String
        let filter: ShelfFilter
        @Binding var current: ShelfFilter

        var body: some View {
            Button {
                HapticManager.shared.play(.light)
                current = filter
            } label: {
                Label(title, systemImage: current == filter ? "checkmark" : icon)
            }
        }
    }

    private var shelfToolbarModifiers: ShelfToolbarModifiers {
        ShelfToolbarModifiers(
            backgroundTasks: backgroundTasks,
            backgroundTaskDestination: $backgroundTaskDestination,
            shelfActionMenu: ShelfActionMenuContent(
                isSelectionMode: $isSelectionMode,
                selectedComicIDs: $selectedComicIDs,
                selectedSeriesIDs: $selectedSeriesIDs,
                shelfDisplayMode: $shelfDisplayMode,
                shelfFilter: $shelfFilter,
                showSettings: $showSettings,
                showStorageManager: $showStorageManager,
                showActivity: $showActivity,
                showNewSeriesAlert: $showNewSeriesAlert,
                selectedPage: $selectedPage,
                showOCRSearch: $showOCRSearch,
                beginImport: beginImport,
                refreshShelfLibraries: refreshShelfLibraries
            )
        )
    }

    // MARK: - Sheet Modifier

    private struct ShelfSheetModifiers: ViewModifier {
        @Binding var showSettings: Bool
        @Binding var isSelectionMode: Bool
        @Binding var selectedComicIDs: Set<UUID>
        @Binding var selectedSeriesIDs: Set<UUID>
        var settingsContent: AnyView
        var library: ComicLibraryStore
        var requestDeleteSelectedItems: () -> Void

        func body(content: Content) -> some View {
            content
                .sheet(isPresented: $showSettings) {
                    settingsContent
                }
                .eraseToAnyView()
                .safeAreaInset(edge: .bottom) {
                    if isSelectionMode {
                        SelectionActionBar(
                            selectedComicIDs: $selectedComicIDs,
                            selectedSeriesIDs: $selectedSeriesIDs,
                            isSelectionMode: $isSelectionMode,
                            library: library,
                            requestDeleteSelectedItems: requestDeleteSelectedItems
                        )
                    }
                }
        }
    }

    private var shelfSheetModifiers: ShelfSheetModifiers {
        ShelfSheetModifiers(
            showSettings: $showSettings,
            isSelectionMode: $isSelectionMode,
            selectedComicIDs: $selectedComicIDs,
            selectedSeriesIDs: $selectedSeriesIDs,
            settingsContent: AnyView(settingsView),
            library: library,
            requestDeleteSelectedItems: requestDeleteSelectedItems
        )
    }

    private struct SelectionActionBar: View {
        @Binding var selectedComicIDs: Set<UUID>
        @Binding var selectedSeriesIDs: Set<UUID>
        @Binding var isSelectionMode: Bool
        var library: ComicLibraryStore
        var requestDeleteSelectedItems: () -> Void

        var body: some View {
            HStack(spacing: 14) {
                Text("shelf.selectedCount".localizedFormat(selectedComicIDs.count + selectedSeriesIDs.count))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    HapticManager.shared.play(.medium)
                    library.rebuildThumbnails(for: selectedComicIDs, seriesIDs: selectedSeriesIDs)
                    selectedComicIDs.removeAll()
                    selectedSeriesIDs.removeAll()
                    isSelectionMode = false
                } label: {
                    Label("comic.rebuildThumbnail".localized, systemImage: "photo.on.rectangle.angled")
                }
                .disabled(selectedComicIDs.isEmpty && selectedSeriesIDs.isEmpty)
                Button(role: .destructive) {
                    requestDeleteSelectedItems()
                } label: {
                    Label("comic.delete".localized, systemImage: "trash")
                }
                .disabled(selectedComicIDs.isEmpty && selectedSeriesIDs.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }

    // MARK: - File Import/Export Modifier

    private struct ShelfFileModifiers: ViewModifier {
        @Binding var isImporting: Bool
        @Binding var isRestoringSettings: Bool
        @Binding var isExportingSettings: Bool
        @Binding var importingSeriesID: UUID?
        @Binding var importError: String?
        @Binding var settingsBackupDocument: SettingsBackupDocument?
        var importPickerMode: ImportPickerMode
        var allowedImportTypes: [UTType]
        var importComicsOrFolder: ([URL], UUID?) -> Void
        var restoreSettingsBackup: (Result<[URL], Error>) -> Void

        func body(content: Content) -> some View {
            content
                .fileImporter(
                    isPresented: $isImporting,
                    allowedContentTypes: allowedImportTypes,
                    allowsMultipleSelection: importPickerMode == .files
                ) { result in
                    if case .success(let urls) = result {
                        importComicsOrFolder(urls, importingSeriesID)
                    }
                    importingSeriesID = nil
                }
                .fileImporter(
                    isPresented: $isRestoringSettings,
                    allowedContentTypes: [.json],
                    allowsMultipleSelection: false
                ) { result in
                    restoreSettingsBackup(result)
                }
                .eraseToAnyView()
                .fileExporter(
                    isPresented: $isExportingSettings,
                    documents: settingsBackupDocument.map { [$0] } ?? [],
                    contentType: .json
                ) { result in
                    if case .success = result {
                        HapticManager.shared.play(.success)
                    } else {
                        HapticManager.shared.play(.error)
                        importError = "error.backupFailed".localized
                    }
                }
        }
    }

    private var shelfFileModifiers: ShelfFileModifiers {
        ShelfFileModifiers(
            isImporting: $isImporting,
            isRestoringSettings: $isRestoringSettings,
            isExportingSettings: $isExportingSettings,
            importingSeriesID: $importingSeriesID,
            importError: $importError,
            settingsBackupDocument: $settingsBackupDocument,
            importPickerMode: importPickerMode,
            allowedImportTypes: allowedImportTypes,
            importComicsOrFolder: { urls, seriesID in importComicsOrFolder(from: urls, seriesID: seriesID) },
            restoreSettingsBackup: { result in restoreSettingsBackup(from: result) }
        )
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
                dataAndSyncSettingsSection
                localLibrarySettingsSection
            }
            .navigationTitle("settings.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("nav.done".localized) {
                    showSettings = false
                }
            }
            .sheet(isPresented: $showTranslationPrompt) {
                NavigationStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("settings.translationStyleDescription".localized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $translationStyleInstructions)
                            .font(.footnote.monospaced())
                            .scrollContentBackground(.hidden)
                            .background(Color.secondary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .padding()
                    .navigationTitle("settings.translationStyleTitle".localized)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("nav.cancel".localized) {
                                translationStyleInstructions = AITranslator.defaultTranslationStyleInstructions
                                showTranslationPrompt = false
                            }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("nav.done".localized) {
                                showTranslationPrompt = false
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showVisionPrompt) {
                NavigationStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("settings.visionPromptPlaceholder".localized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $visionTranslationPromptTemplate)
                            .font(.footnote.monospaced())
                            .scrollContentBackground(.hidden)
                            .background(Color.secondary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .padding()
                    .navigationTitle("settings.visionPrompt".localized)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("nav.cancel".localized) {
                                visionTranslationPromptTemplate = AITranslator.defaultVisionTranslationPromptTemplate
                                showVisionPrompt = false
                            }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("nav.done".localized) {
                                showVisionPrompt = false
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var shelfRootContent: some View {
        TabView(selection: $selectedPage) {
            shelfPageContent(for: .continueReading)
                .tabItem {
                    Label("tab.continueReading".localized, systemImage: "book")
                }
                .tag(MainShelfPage.continueReading)

            shelfPageContent(for: .library)
                .tabItem {
                    Label("tab.library".localized, systemImage: "books.vertical")
                }
                .tag(MainShelfPage.library)

            shelfPageContent(for: .statistics)
                .tabItem {
                    Label("tab.statistics".localized, systemImage: "chart.bar.doc.horizontal")
                }
                .tag(MainShelfPage.statistics)
        }
        .task(id: library.comics.count) {
            let topComics = Array(continueReadingComics.prefix(3))
            RemotePagePrefetcher.shared.previewPrefetch(comics: topComics)
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
            return "tab.continueReading".localized
        case .library:
            return "shelf.title".localized
        case .statistics:
            return "tab.statistics".localized
        }
    }

    private var missingLibraryRootView: some View {
        ContentUnavailableView {
            Label("settings.selectLibrary".localized, systemImage: "folder")
        } description: {
            Text("settings.selectLibraryDescription".localized)
        } actions: {
            Button("settings.selectLibraryRoot".localized) {
                isLibraryRootPicking = true
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var emptyShelfView: some View {
        ScrollView {
            ContentUnavailableView {
                Label("shelf.emptyTitle".localized, systemImage: "books.vertical")
            } description: {
                Text("shelf.emptyDescription".localized)
            } actions: {
                Button("shelf.importComics".localized) {
                    beginImport(.files)
                }
                .buttonStyle(.borderedProminent)
                Button("shelf.importFolder".localized) {
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
            .sorted { lhs, rhs in
                let lhsFinished = ComicReadingProgress.isFinished(lhs)
                let rhsFinished = ComicReadingProgress.isFinished(rhs)
                if lhsFinished != rhsFinished { return !lhsFinished }
                return lhs.lastReadAt > rhs.lastReadAt
            }
    }

    private func sortedComicsByTitle(_ comics: [ComicBook]) -> [ComicBook] {
        comics.sorted { lhs, rhs in
            return naturalTitleCompare(lhs.title, comicSortTieBreaker(lhs), rhs.title, comicSortTieBreaker(rhs))
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
            }
            .refreshable {
                await refreshShelfLibraries()
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.82), value: library.comics)
        }
    }

    private func refreshShelfLibraries() async {
        guard !isRefreshingLibraries else { return }
        isRefreshingLibraries = true
        let taskID = backgroundTasks.begin(title: "import.refreshRemoteLibrary".localized)
        defer {
            backgroundTasks.finish(taskID)
            isRefreshingLibraries = false
        }
        HapticManager.shared.play(.light)
        await library.syncAllLibrariesAsync(skipPrewarm: true)
        hasLibraryRoot = ComicManager.hasSelectedLibraryRoot()
    }

    private var shelfTitle: String {
        switch shelfFilter {
        case .all: return "shelf.title".localized
        case .inProgress: return "shelf.inProgress".localized
        case .locked: return "shelf.locked".localized
        case .local: return "shelf.local".localized
        case .komga: return "shelf.komga".localized
        case .opds: return "shelf.opds".localized
        }
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
            Label("series.rename".localized, systemImage: "pencil")
        }

        Button {
            HapticManager.shared.play(.medium)
            library.rebuildThumbnails(for: [], seriesIDs: [series.id])
        } label: {
            Label("series.rebuildThumbnails".localized, systemImage: "photo.on.rectangle.angled")
        }

        Button {
            HapticManager.shared.play(.medium)
            library.markSeriesAsRead(seriesID: series.id)
        } label: {
            Label("series.markAllRead".localized, systemImage: "checkmark.circle.fill")
        }

        if let folderURL = ComicManager.urlForLibraryPath(series.libraryPath) {
            ShareLink(item: folderURL) {
                Label("comic.share".localized, systemImage: "square.and.arrow.up")
            }

            Button {
                HapticManager.shared.play(.light)
                FileOpenPresenter.shared.open(folderURL)
            } label: {
                Label("comic.openInFiles".localized, systemImage: "folder")
            }
        }

        Button(role: .destructive) {
            HapticManager.shared.play(.heavy)
            deleteRequest = .series(series)
        } label: {
            Label("comic.delete".localized, systemImage: "trash")
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

    private var openAISettingsSection: some View {
        Section(header: Text("settings.openai".localized), footer: Text("settings.openaiDescription".localized)) {
            NavigationLink {
                AIProviderSettingsView()
            } label: {
                Label("aiProvider.title".localized, systemImage: "cpu")
            }
            Button {
                showTranslationPrompt = true
            } label: {
                HStack {
                    Text("settings.translationStyleTitle".localized)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                showVisionPrompt = true
            } label: {
                HStack {
                    Text("settings.visionPrompt".localized)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.secondary)
                }
            }
            Picker("ocr.localMode".localized, selection: $ocrLocalRecognitionModeRaw) {
                ForEach(OCRRecognitionMode.allCases, id: \.rawValue) { mode in
                    Text(mode.localizationKey.localized).tag(mode.rawValue)
                }
            }
            Toggle("ocr.visualVerification".localized, isOn: $isOCRVisualVerificationEnabled)
            Toggle("ocr.showDebugBoxes".localized, isOn: $isOCRDebugBoxesEnabled)
        }
    }

    private var importServiceSection: some View {
        Section(header: Text("import.title".localized)) {
            Button {
                HapticManager.shared.play(.light)
                showSettings = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    beginImport(.files)
                }
            } label: {
                Label("import.files".localized, systemImage: "icloud.and.arrow.down")
            }

            Button {
                HapticManager.shared.play(.light)
                showSettings = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    beginImport(.folder)
                }
            } label: {
                Label("import.folder".localized, systemImage: "folder.badge.plus")
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
                Label("import.webServer".localized, systemImage: "network")
            }

            if webServer.isRunning {
                LabeledContent("import.accessAddress".localized) {
                    Text(webServer.address)
                        .font(.footnote)
                        .textSelection(.enabled)
                }
                Button {
                    UIPasteboard.general.string = webServer.address
                } label: {
                    Label("import.copyWebAddress".localized, systemImage: "doc.on.doc")
                }
            }
        }
    }

    private var mediaSourceSettingsSection: some View {
        Section(header: Text("import.comicMediaLibrary".localized)) {
            NavigationLink {
                MediaSourceSettingsView(library: library)
            } label: {
                Label("Komga / OPDS", systemImage: "server.rack")
            }
        }
    }

    private var interactionSettingsSection: some View {
        Section(header: Text("interaction.title".localized)) {
            Toggle("interaction.haptic".localized, isOn: $isHapticFeedbackEnabled)
                .onChange(of: isHapticFeedbackEnabled) { _, newValue in
                    if newValue {
                        HapticManager.shared.play(.success)
                    }
                }
            Toggle("interaction.burnInProtection".localized, isOn: $isBurnInProtectionEnabled)
        }
    }

    private var dataAndSyncSettingsSection: some View {
        Section(header: Text("sync.metadata.title".localized), footer: Text("sync.metadata.description".localized)) {
            Toggle("sync.metadata.icloud".localized, isOn: $isICloudMetadataSyncEnabled)
                .onChange(of: isICloudMetadataSyncEnabled) { _, enabled in
                    if enabled {
                        Task {
                            if let payload = await iCloudSync.pull() {
                                library.applySyncedMetadata(payload)
                                readingActivity.mergeSyncedDays(payload.activityDays)
                            }
                            iCloudSync.push(comics: library.comics, activityDays: readingActivity.days)
                        }
                    }
                }
            if isICloudMetadataSyncEnabled && !iCloudSync.usesICloudDrive {
                Text("sync.metadata.localOnly".localized)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let date = iCloudSync.lastSyncAt {
                LabeledContent("sync.metadata.lastSync".localized, value: date.formatted(date: .abbreviated, time: .shortened))
            }
            if let error = iCloudSync.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Divider()
            Button {
                HapticManager.shared.play(.light)
                showSettings = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    backupPasswordRequest = BackupPasswordRequest(purpose: .export)
                }
            } label: {
                Label("backup.exportWithCredentials".localized, systemImage: "lock.doc")
            }

            Button {
                HapticManager.shared.play(.light)
                showSettings = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    isRestoringSettings = true
                }
            } label: {
                Label("backup.import".localized, systemImage: "square.and.arrow.down")
            }
        }
    }

    private var localLibrarySettingsSection: some View {
        let address = ComicManager.readableLocalLibraryAddress()
        return Section(header: Text("localLibrary.title".localized)) {
            LabeledContent("localLibrary.address".localized) {
                Text(address)
                    .font(.footnote)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
            }
            Button {
                UIPasteboard.general.string = address
            } label: {
                Label("localLibrary.copyAddress".localized, systemImage: "folder")
            }
            Button {
                isLibraryRootPicking = true
            } label: {
                Label("localLibrary.changeRoot".localized, systemImage: "folder.badge.gearshape")
            }
            Button {
                library.resetReadingPresetDetection()
                HapticManager.shared.play(.success)
            } label: {
                Label("storage.resetDetection".localized, systemImage: "arrow.counterclockwise")
            }
            Button {
                HapticManager.shared.play(.light)
                showSettings = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    showStorageManager = true
                }
            } label: {
                Label("storage.title".localized, systemImage: "externaldrive")
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

    private func readerDestination(for comic: ComicBook) -> some View {
        ReaderContainerView(comic: comic) { updatedComic in
            library.update(updatedComic)
        }
    }

    private func openReader(_ comic: ComicBook) {
        if comic.isLocked {
            authenticateLockedComic(comic) {
                openAuthorizedReader(comic)
            }
            return
        }
        openAuthorizedReader(comic)
    }

    private func openAuthorizedReader(_ comic: ComicBook) {
        RemotePagePrefetcher.shared.cancelPreviewForNonOpened(comicID: comic.id)
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            selectedReaderComic = comic
        }
    }

    private func authenticateLockedComic(_ comic: ComicBook, onSuccess: @escaping () -> Void) {
        let context = LAContext()
        var authorizationError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authorizationError) else {
            importError = authorizationError?.localizedDescription ?? "comic.lockUnavailable".localized
            HapticManager.shared.play(.error)
            return
        }
        Task {
            do {
                guard try await context.evaluatePolicy(
                    .deviceOwnerAuthentication,
                    localizedReason: "comic.unlockReason".localizedFormat(comic.title)
                ) else { return }
                HapticManager.shared.play(.success)
                onSuccess()
            } catch let error as LAError where error.code == .userCancel || error.code == .appCancel || error.code == .systemCancel {
                return
            } catch {
                importError = error.localizedDescription
                HapticManager.shared.play(.error)
            }
        }
    }

    @ViewBuilder
    private func comicManagementMenu(for comic: ComicBook) -> some View {
        Button {
            HapticManager.shared.play(.light)
            renameTitle = comic.title
            renamingComic = comic
        } label: {
            Label("comic.rename".localized, systemImage: "pencil")
        }

        if let folderURL = folderURL(for: comic) {
            ShareLink(item: folderURL) {
                Label("comic.share".localized, systemImage: "square.and.arrow.up")
            }

            Button {
                HapticManager.shared.play(.light)
                FileOpenPresenter.shared.open(folderURL)
            } label: {
                Label("comic.openInFiles".localized, systemImage: "folder")
            }
        }

        Button {
            HapticManager.shared.play(.medium)
            if comic.isLocked {
                authenticateLockedComic(comic) {
                    library.setLocked(id: comic.id, isLocked: false)
                }
            } else {
                library.setLocked(id: comic.id, isLocked: true)
            }
        } label: {
            Label(comic.isLocked ? "comic.unlock".localized : "comic.lock".localized, systemImage: comic.isLocked ? "lock.open" : "lock")
        }

        if !ComicReadingProgress.isFinished(comic) {
            Button {
                HapticManager.shared.play(.medium)
                library.markAsRead(id: comic.id)
            } label: {
                Label("comic.markAsRead".localized, systemImage: "checkmark.circle")
            }
        }

        Button {
            HapticManager.shared.play(.medium)
            library.rebuildThumbnail(for: comic.id)
        } label: {
            Label("comic.rebuildThumbnail".localized, systemImage: "photo.on.rectangle.angled")
        }

        Button {
            HapticManager.shared.play(.medium)
            if ocrIndexer.activeComicID == comic.id {
                ocrIndexer.cancel()
            } else {
                ocrIndexer.start(comic)
            }
        } label: {
            if ocrIndexer.activeComicID == comic.id {
                Label("ocr.index.cancel".localized, systemImage: "xmark.circle")
            } else {
                Label("ocr.index.build".localized, systemImage: "text.magnifyingglass")
            }
        }

        Button {
            HapticManager.shared.play(.light)
            offlineTranslationStartComic = comic
        } label: {
            Label("offlineTranslation.start".localized, systemImage: "text.bubble.fill")
        }

        Button {
            HapticManager.shared.play(.light)
            offlineTranslationManagerComic = comic
        } label: {
            Label("offlineTranslation.manage".localized, systemImage: "list.bullet.rectangle")
        }

        if comic.sourceType == .komga || comic.sourceType == .opds {
            if offlineDownloads.activeComicIDs.contains(comic.id) || offlineDownloads.queuedComicIDs.contains(comic.id) {
                Button { offlineDownloads.cancel(comic) } label: {
                    Label("offline.cancel".localized, systemImage: "xmark.circle")
                }
            } else if offlineDownloads.isAvailableOffline(comic) {
                Button(role: .destructive) { offlineDownloads.remove(comic) } label: {
                    Label("offline.remove".localized, systemImage: "externaldrive.badge.xmark")
                }
            } else {
                Button { offlineDownloads.download(comic) } label: {
                    Label("offline.download".localized, systemImage: "arrow.down.circle")
                }
            }
        }

        if comic.sourceType == .komga {
            Button(role: .destructive) {
                HapticManager.shared.play(.medium)
                hideKomgaRequest = comic
            } label: {
                Label("comic.hide".localized, systemImage: "eye.slash")
            }
        }

        Button(role: .destructive) {
            HapticManager.shared.play(.heavy)
            deleteRequest = .comic(comic)
        } label: {
            Label("comic.delete".localized, systemImage: "trash")
        }
    }

    private func folderURL(for comic: ComicBook) -> URL? {
        guard comic.sourceType == .local else { return nil }
        return try? ComicManager.resolveBookmark(comic.bookmarkData)
    }
    
    private func importComicsOrFolder(from urls: [URL], seriesID: UUID? = nil, securityBox: SecurityScopeBox? = nil) {
        let taskID = backgroundTasks.begin(
            title: urls.count > 1 ? "import.itemsCount".localizedFormat(urls.count) : "import.importAndParse".localized,
            detail: urls.first?.lastPathComponent,
            progress: 0
        )
        Task {
            var importedCount = 0
            var failedCount = 0
            var processedPDFCount = 0
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
                                if childURL.pathExtension.lowercased() == "pdf" {
                                    processedPDFCount += 1
                                    continue
                                }
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
                    if url.pathExtension.lowercased() == "pdf" {
                        processedPDFCount += 1
                        continue
                    }
                    failedCount += 1
                    if urls.count == 1 {
                        failureReason = ComicManager.zipImportFailureReason(for: url)
                    }
                }
            }

            if processedPDFCount > 0 {
                await library.syncLocalLibraryAsync()
            }

            await MainActor.run {
                if importedCount == 0 && failedCount > 0 {
                    HapticManager.shared.play(.error)
                    importError = failureReason?.isEmpty == false ? failureReason! : "import.noReadableImages".localized
                } else if failedCount > 0 {
                    HapticManager.shared.play(.warning)
                    if processedPDFCount > 0 {
                        importError = "import.partialSuccessWithPDF".localizedFormat(importedCount, failedCount)
                    } else {
                        importError = "import.partialSuccess".localizedFormat(importedCount, failedCount)
                    }
                } else {
                    HapticManager.shared.play(.success)
                    if processedPDFCount > 0 {
                        importInfo = processedPDFCount == 1
                            ? "import.pdfProcessedSingle".localized
                            : "import.pdfProcessed".localizedFormat(processedPDFCount)
                    }
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

    /// 备份现在必须携带密钥（API Key / 媒体源 Key），并始终以密码加密导出。
    private func makeSettingsBackup() -> MReaderSettingsBackup {
        let mediaSources = KomgaProvider.loadSources().map { source in
            MediaSourceBackup(
                source: source,
                apiKey: KomgaProvider.apiKey(for: source.id)
            )
        }
        let providerStore = AIProviderStore.shared
        let providerBackups = providerStore.profiles().map { profile in
            AIProviderBackup(
                profile: profile,
                apiKey: providerStore.apiKey(for: profile.id)
            )
        }
        let activeConfiguration = providerStore.activeConfiguration()
        return MReaderSettingsBackup(
            openAIAPIKey: activeConfiguration?.apiKey,
            openAIBaseURL: activeConfiguration?.baseURL ?? "https://api.openai.com/v1",
            openAIModel: activeConfiguration?.textModel ?? "gpt-4o-mini",
            aiModelPool: nil,
            isAIModelPoolEnabled: false,
            translationTargetLanguage: translationTargetLanguage,
            translationPromptTemplate: nil,
            translationStyleInstructions: translationStyleInstructions,
            visionTranslationPromptTemplate: visionTranslationPromptTemplate,
            isHapticFeedbackEnabled: isHapticFeedbackEnabled,
            mediaSources: mediaSources,
            translationColorStyle: translationColorStyleRaw,
            isAITranslationBorderProgressEnabled: isAITranslationBorderProgressEnabled,
            isOCRDebugBoxesEnabled: isOCRDebugBoxesEnabled,
            isOCRVisualVerificationEnabled: isOCRVisualVerificationEnabled,
            ocrLocalRecognitionMode: ocrLocalRecognitionModeRaw,
            readingDailyPageGoal: readingDailyPageGoal,
            isBurnInProtectionEnabled: isBurnInProtectionEnabled,
            isICloudMetadataSyncEnabled: isICloudMetadataSyncEnabled,
            aiProviders: providerBackups,
            activeAIProviderID: providerStore.activeProfileID(),
            containsCredentials: true
        )
    }

    /// 导出设置备份：始终包含密钥，且必须用密码加密（不允许明文携带密钥）。
    private func exportSettingsBackup(password: String? = nil) {
        do {
            let backup = makeSettingsBackup()
            guard let password else { throw SettingsBackupCodecError.invalidPassword }
            let data = try SettingsBackupCodec.encodeEncrypted(backup, password: password)
            settingsBackupDocument = SettingsBackupDocument(data: data)
            showSettings = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isExportingSettings = true
            }
        } catch {
            HapticManager.shared.play(.error)
            importError = error.localizedDescription
        }
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
            if SettingsBackupCodec.isEncrypted(data) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    backupPasswordRequest = BackupPasswordRequest(purpose: .restore(data))
                }
                return
            }
            let backup = try SettingsBackupCodec.decode(data)
            try applySettingsBackup(backup)
        } catch {
            HapticManager.shared.play(.error)
            settingsRestoreNotice = SettingsRestoreNotice(
                title: "settings.restoreFailed".localized,
                message: "设置备份恢复失败：\(error.localizedDescription)"
            )
        }
    }

    private func applySettingsBackup(_ backup: MReaderSettingsBackup) throws {
            if let providers = backup.aiProviders, !providers.isEmpty {
                let providerStore = AIProviderStore.shared
                try AIProviderStore.shared.replaceProfiles(
                    providers.map { provider in
                        (provider.profile, provider.apiKey ?? providerStore.apiKey(for: provider.profile.id))
                    },
                    activeProfileID: backup.activeAIProviderID
                )
            } else {
                let legacyProfile = AIProviderProfile.fromLegacySettings(
                    apiDisplayName: "默认接口",
                    baseURL: backup.openAIBaseURL,
                    defaultModel: backup.openAIModel,
                    poolText: backup.aiModelPool ?? ""
                )
                try AIProviderStore.shared.replaceProfiles(
                    [(legacyProfile, backup.openAIAPIKey ?? "")],
                    activeProfileID: legacyProfile.id
                )
            }
            translationTargetLanguage = backup.translationTargetLanguage
            // 备份协议显式带版本（项4）：v10 直接恢复 translationStyleInstructions；
            // v9 及更老把 translationPromptTemplate 视为旧完整 Prompt，备份而不回填。
            if backup.version >= 10, let style = backup.translationStyleInstructions,
               !style.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                translationStyleInstructions = style
            } else if let legacy = backup.translationPromptTemplate,
                      !legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                UserDefaults.standard.set(legacy, forKey: "translation_prompt_legacy_backup")
                translationStyleInstructions = AITranslator.defaultTranslationStyleInstructions
            } else {
                translationStyleInstructions = AITranslator.defaultTranslationStyleInstructions
            }
            visionTranslationPromptTemplate = backup.visionTranslationPromptTemplate ?? AITranslator.defaultVisionTranslationPromptTemplate
            isHapticFeedbackEnabled = backup.isHapticFeedbackEnabled
            translationColorStyleRaw = backup.translationColorStyle ?? translationColorStyleRaw
            isAITranslationBorderProgressEnabled = backup.isAITranslationBorderProgressEnabled ?? isAITranslationBorderProgressEnabled
            isOCRDebugBoxesEnabled = backup.isOCRDebugBoxesEnabled ?? isOCRDebugBoxesEnabled
            isOCRVisualVerificationEnabled = backup.isOCRVisualVerificationEnabled ?? isOCRVisualVerificationEnabled
            ocrLocalRecognitionModeRaw = backup.ocrLocalRecognitionMode ?? ocrLocalRecognitionModeRaw
            readingDailyPageGoal = min(max(backup.readingDailyPageGoal ?? readingDailyPageGoal, 0), 5_000)
            isBurnInProtectionEnabled = backup.isBurnInProtectionEnabled ?? isBurnInProtectionEnabled
            isICloudMetadataSyncEnabled = backup.isICloudMetadataSyncEnabled ?? isICloudMetadataSyncEnabled
            try restoreMediaSources(from: backup.mediaSources ?? [])
            Task {
                await library.syncAllLibrariesAsync()
            }
            HapticManager.shared.play(.success)
            settingsRestoreNotice = SettingsRestoreNotice(title: "settings.restoreSuccess".localized, message: "settings.restoreSuccessMessage".localized)
    }

    private func handleBackupPassword(_ password: String, request: BackupPasswordRequest) -> String? {
        do {
            switch request.purpose {
            case .export:
                backupPasswordRequest = nil
                exportSettingsBackup(password: password)
            case .restore(let data):
                let backup = try SettingsBackupCodec.decode(data, password: password)
                try applySettingsBackup(backup)
                backupPasswordRequest = nil
            }
            return nil
        } catch {
            HapticManager.shared.play(.error)
            return error.localizedDescription
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

}

private struct BackupPasswordView: View {
    let isCreatingBackup: Bool
    let onCancel: () -> Void
    let onSubmit: (String) -> String?

    @State private var password = ""
    @State private var confirmation = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("backup.password".localized, text: $password)
                        .textContentType(.newPassword)
                    if isCreatingBackup {
                        SecureField("backup.passwordConfirm".localized, text: $confirmation)
                            .textContentType(.newPassword)
                    }
                } footer: {
                    Text("backup.passwordDescription".localized)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle(isCreatingBackup ? "backup.encryptTitle".localized : "backup.decryptTitle".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("nav.cancel".localized, action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("nav.done".localized) {
                        errorMessage = onSubmit(password)
                    }
                    .disabled(password.count < 8 || (isCreatingBackup && password != confirmation))
                }
            }
        }
        .presentationDetents([.medium])
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

enum ShelfCardMetrics {
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

    static func gridLayout(
        for containerWidth: CGFloat,
        idiom: UIUserInterfaceIdiom = UIDevice.current.userInterfaceIdiom
    ) -> (columns: [GridItem], cardWidth: CGFloat) {
        if idiom == .phone {
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
                CoverImageView(comic: comic)
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
                if comic.sourceType == .local && comic.fileSize > 0 {
                    Text("·")
                    Text(formattedFileSize(comic.fileSize))
                }
                Spacer()
                Text("comic.pagesCount".localizedFormat(comic.totalPages))
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
    guard bytes > 0 else { return "comic.unknownSize".localized }
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

private func sourceLabel(for comic: ComicBook) -> String {
    switch comic.sourceType {
    case .local:
        return "comic.sourceLocal".localized
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
                    CoverImageView(comic: comic)
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

                Text(comic.sourceType == .local && comic.fileSize > 0
                     ? "\(formattedFileSize(comic.fileSize)) · " + "comic.pagesCount".localizedFormat(comic.totalPages)
                     : "comic.pagesCount".localizedFormat(comic.totalPages))
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
                        CoverImageView(comic: comic)
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

                Text("comic.chaptersPages".localizedFormat(comics.count, comics.reduce(0) { $0 + $1.totalPages }))
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
                                CoverImageView(comic: comic)
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
                Text("comic.chaptersCount".localizedFormat(comics.count))
                Spacer()
                Text("comic.pagesCount".localizedFormat(comics.reduce(0) { $0 + $1.totalPages }))
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
                    CoverImageView(comic: comic)
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

                Text(comic.hasBeenOpened ? "comic.readProgress".localized + " \(progressText)" : "comic.notOpened".localized)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text("comic.continueReading".localized)
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
    static let pageBackground = Color(.systemBackground)
    static let cardBackground = Color(.secondarySystemBackground)
    static let raisedCardBackground = Color(.tertiarySystemBackground)
    static let track = Color(.systemGray4)
    static let primaryText = Color(.label)
    static let secondaryText = Color(.secondaryLabel)
    static let weakText = Color(.tertiaryLabel)
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
                    Label("stats.todaySummary".localized, systemImage: "sun.max.fill")
                        .font(.headline)
                        .foregroundStyle(FitnessPalette.primaryText)
                    Spacer()
                    Text("stats.goalPages".localizedFormat(Int(dailyPageGoal)))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(FitnessPalette.secondaryText)
                }

                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    TodayMetric(value: "\(stats.todayMinutes)", title: "stats.minutes".localized, color: FitnessPalette.move)
                    TodayMetric(value: "\(stats.todayPages)", title: "stats.pages".localized, color: FitnessPalette.exercise)
                    TodayMetric(value: "\(stats.todayCompletedCount)", title: "stats.completed".localized, color: FitnessPalette.stand)
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
                    Label("stats.dailyGoalLabel".localized, systemImage: "target")
                        .font(.headline)
                    Spacer()
                    Text("stats.goalPages".localizedFormat(roundedGoal))
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
                    Text("stats.pagesPerDay".localized)
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
                Label("stats.readingRingsLabel".localized, systemImage: "circle.circle.fill")
                    .font(.headline)
                HStack(spacing: 18) {
                    ReadingRing(progress: stats.todayGoalProgress, tint: FitnessPalette.move, value: "\(stats.todayPages)", caption: "stats.todayGoal".localizedFormat(Int(dailyPageGoal)))
                    ReadingRing(progress: stats.weekGoalProgress, tint: FitnessPalette.exercise, value: "\(Int(stats.weekGoalProgress * 100))%", caption: "stats.weekGoal".localized)
                    ReadingRing(progress: min(Double(stats.currentStreak) / 7, 1), tint: FitnessPalette.stand, value: "\(stats.currentStreak)", caption: "stats.streakDays".localized)
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
                    Label("stats.thisWeek".localized, systemImage: "chart.bar.fill")
                        .font(.headline)
                    Spacer()
                    if let selectedActivity {
                        Text("stats.minutesPages".localizedFormat(selectedActivity.minutes, selectedActivity.pages))
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
        return ["day.sunday".localized, "day.monday".localized, "day.tuesday".localized, "day.wednesday".localized, "day.thursday".localized, "day.friday".localized, "day.saturday".localized][max(0, min(index - 1, 6))]
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
                    Label("stats.monthlyRecord".localized, systemImage: "calendar")
                        .font(.headline)
                    Spacer()
                    Text("stats.currentStreakDays".localizedFormat(currentStreak))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(FitnessPalette.secondaryText)
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 10), spacing: 10) {
                    ForEach(activity) { day in
                        CalendarDot(day: day)
                    }
                }

                HStack {
                    Label("stats.longestStreakDays".localizedFormat(longestStreak), systemImage: "flame.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(FitnessPalette.move)
                    Spacer()
                    Text("stats.solidDotMeaning".localized)
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
            .accessibilityLabel(Text("stats.pagesReadShort".localizedFormat(day.pages)))
    }
}

private struct TopReadingComicsCard: View {
    let comics: [ComicBook]

    var body: some View {
        StatisticsCard {
            VStack(alignment: .leading, spacing: 14) {
                Label("stats.topReading".localized, systemImage: "books.vertical.fill")
                    .font(.headline)

                if comics.isEmpty {
                    ContentUnavailableView("stats.noReadingRecords".localized, systemImage: "book.closed", description: Text("stats.noReadingRecordsDescription".localized))
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
            CoverImageView(comic: comic)
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

                Text("\(minutes) \("stats.minutes".localized) · \(pages) / \(comic.totalPages) \("stats.pages".localized)")
                    .font(.caption)
                    .foregroundStyle(FitnessPalette.secondaryText)
            }
        }
    }
}

struct CoverImageView: View {
    let path: String?
    let remoteSourceID: UUID?
    let remoteBookID: String?
    @State private var image: UIImage?

    init(path: String?) {
        self.path = path
        self.remoteSourceID = nil
        self.remoteBookID = nil
    }

    init(comic: ComicBook) {
        self.path = comic.coverImagePath
        self.remoteSourceID = comic.sourceType == .komga ? comic.mediaSourceID : nil
        self.remoteBookID = comic.sourceType == .komga ? comic.komgaBookID : nil
    }

    private var coverTaskID: String {
        "\(path ?? "")|\(remoteSourceID?.uuidString ?? "")|\(remoteBookID ?? "")"
    }

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
        .task(id: coverTaskID) { await loadCover() }
    }

    private func loadCover() async {
        let resolvedPath = RemoteImageLoader.resolvedCoverPath(
            persistedPath: path,
            sourceID: remoteSourceID,
            bookID: remoteBookID
        )
        guard let resolvedPath else {
            image = nil
            return
        }
        let loadedImage = await Task.detached(priority: .utility) {
            await Self.makeThumbnail(path: resolvedPath, maxPixelSize: 640)
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
            guard FileManager.default.fileExists(atPath: path) else { return nil }
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
    @ObservedObject private var offlineDownloads = OfflineDownloadManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var cacheSnapshot = CacheStorageSnapshot.zero
    @State private var isClearingCaches = false

    private var estimatedPages: Int {
        library.comics.reduce(0) { $0 + $1.totalPages }
    }

    var body: some View {
        NavigationStack {
            List {
                Section(header: Text("localLibrary.title".localized)) {
                    LabeledContent("storage.seriesCount".localized, value: "\(library.series.count)")
                    LabeledContent("storage.comicCountLabel".localized, value: "\(library.comics.count)")
                    LabeledContent("storage.imagePages".localized, value: "\(estimatedPages)")
                    Text(ComicManager.readableLocalLibraryAddress())
                        .font(.footnote)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                    Button {
                        UIPasteboard.general.string = ComicManager.readableLocalLibraryAddress()
                    } label: {
                        Label("storage.copyAddress".localized, systemImage: "doc.on.doc")
                    }
                }

                Section(header: Text("storage.cacheAndTemp".localized), footer: Text("storage.cacheDescription".localized)) {
                    LabeledContent("storage.pageCache".localized, value: formattedFileSize(cacheSnapshot.remotePages))
                    LabeledContent("storage.generatedCache".localized, value: formattedFileSize(cacheSnapshot.generatedAssets))
                    LabeledContent("storage.tempExtractCache".localized, value: formattedFileSize(cacheSnapshot.temporaryFiles))
                    LabeledContent("offlineTranslation.storage".localized, value: formattedFileSize(cacheSnapshot.offlineTranslations))
                    LabeledContent("storage.totalCache".localized, value: formattedFileSize(cacheSnapshot.readerCacheTotal))
                    Button(role: .destructive) {
                        clearReaderCaches()
                    } label: {
                        Label("storage.clearReaderCaches".localized, systemImage: "trash")
                    }
                    .disabled(isClearingCaches || cacheSnapshot.readerCacheTotal == 0)
                }

                Section(header: Text("offline.title".localized)) {
                    LabeledContent("storage.offlineCache".localized, value: formattedFileSize(cacheSnapshot.offlineComics))
                    if offlineComics.isEmpty {
                        Text("offline.empty".localized)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(offlineComics) { comic in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(comic.title).lineLimit(1)
                                    if offlineDownloads.activeComicIDs.contains(comic.id) {
                                        ProgressView(value: offlineDownloads.progress[comic.id] ?? 0)
                                    } else if offlineDownloads.queuedComicIDs.contains(comic.id) {
                                        Text("offline.queued".localized).font(.caption).foregroundStyle(.secondary)
                                    } else {
                                        Text("offline.available".localized).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    offlineDownloads.remove(comic)
                                    refreshCacheSnapshot()
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .accessibilityLabel("offline.remove".localized)
                            }
                        }
                    }
                }

                Section(header: Text("storage.maintenance".localized)) {
                    Button {
                        library.rebuildAllThumbnails()
                    } label: {
                        Label("storage.rebuildCoverIndex".localized, systemImage: "photo.on.rectangle.angled")
                    }

                    Button {
                        Task { await library.syncAllLibrariesAsync() }
                    } label: {
                        Label("storage.refreshLibraryIndex".localized, systemImage: "arrow.clockwise")
                    }
                }
            }
            .navigationTitle("storage.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("nav.done".localized) { dismiss() }
            }
            .task {
                offlineDownloads.removeOrphanedRecords(validComicIDs: Set(library.comics.map(\.id)))
                await loadCacheSnapshot()
            }
        }
    }

    private var offlineComics: [ComicBook] {
        library.comics
            .filter {
                offlineDownloads.records[$0.id] != nil ||
                offlineDownloads.activeComicIDs.contains($0.id) ||
                offlineDownloads.queuedComicIDs.contains($0.id)
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func refreshCacheSnapshot() {
        Task { await loadCacheSnapshot() }
    }

    private func loadCacheSnapshot() async {
        cacheSnapshot = await Task.detached(priority: .utility) {
            CacheStorageManager.snapshot()
        }.value
    }

    private func clearReaderCaches() {
        guard !isClearingCaches else { return }
        isClearingCaches = true
        HapticManager.shared.play(.heavy)
        Task {
            await Task.detached(priority: .utility) {
                CacheStorageManager.clearReaderCaches()
            }.value
            NotificationCenter.default.post(name: .mreaderClearReaderMemoryCaches, object: nil)
            await RemotePageCache.shared.clearMemoryCache()
            await AITranslationPageCoordinator.shared.clearCache()
            await OCRRecognitionCache.shared.clearCache()
            await PanelDetectionService.shared.clearCache()
            library.rebuildAllThumbnails()
            await loadCacheSnapshot()
            isClearingCaches = false
            HapticManager.shared.play(.success)
        }
    }
}

struct ShelfActivityView: View {
    let comics: [ComicBook]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(comics.sorted { lhs, rhs in
                    let lhsFinished = ComicReadingProgress.isFinished(lhs)
                    let rhsFinished = ComicReadingProgress.isFinished(rhs)
                    if lhsFinished != rhsFinished { return !lhsFinished }
                    return lhs.lastReadAt > rhs.lastReadAt
                }) { comic in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(comic.title)
                                .font(.headline)
                                .lineLimit(1)
                            Text(
                                comic.hasBeenOpened
                                    ? "comic.readTo".localizedFormat(ComicReadingProgress.completedPages(for: comic), comic.totalPages)
                                    : "comic.notOpened".localized
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
            .navigationTitle("shelf.activity".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("nav.done".localized) { dismiss() }
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
            return naturalTitleCompare(lhs.title, sortTieBreaker(for: lhs), rhs.title, sortTieBreaker(for: rhs))
        }
    }

    private var availableComics: [ComicBook] {
        allComics
            .filter { $0.seriesID == nil }
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
                    Label("series.empty".localized, systemImage: "books.vertical")
                } description: {
                    Text("series.addChapters".localized)
                } actions: {
                    Button("series.addChapterFiles".localized) {
                        onImportFiles()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("series.addChapterFolder".localized) {
                        onImportFolder()
                    }
                    Button("series.addFromShelfButton".localized) { showAddSheet = true }
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
                                        Label("series.removeFromSeries".localized, systemImage: "minus.circle")
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
                    Label("nav.back".localized, systemImage: "chevron.backward")
                }
                .disabled(isClosing)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        onImportFiles()
                    } label: {
                        Label("series.addChapterFiles".localized, systemImage: "doc.badge.plus")
                    }
                    Button {
                        onImportFolder()
                    } label: {
                        Label("series.addChapterFolder".localized, systemImage: "folder.badge.plus")
                    }
                    Button {
                        showAddSheet = true
                    } label: {
                        Label("series.addFromShelfButton".localized, systemImage: "books.vertical")
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
                .navigationTitle("series.addSheetTitle".localized)
                .toolbar {
                    Button("nav.done".localized) { showAddSheet = false }
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
