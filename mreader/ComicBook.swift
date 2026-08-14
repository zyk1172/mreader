import Foundation

enum ComicSourceType: String, Codable, Hashable, Sendable {
    case local
    case komga
    case opds
}

enum AITranslationMode: String, Codable, Hashable, Sendable {
    case ocr
    case vision
}

struct ComicBookmark: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var pageIndex: Int
    var note: String

    init(pageIndex: Int, note: String = "") {
        self.id = UUID()
        self.pageIndex = pageIndex
        self.note = note
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        pageIndex = try container.decode(Int.self, forKey: .pageIndex)
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
    }
}

struct ComicBook: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var title: String
    var bookmarkData: Data // 核心：保存文件夹的持久化安全访问权限
    var totalPages: Int
    var coverImagePath: String?
    var fileSize: Int64
    var libraryPath: String?
    var sourceTypeRaw: String
    var sourceURL: String?
    var mediaSourceID: UUID?
    var komgaLibraryID: String?
    var komgaSeriesID: String?
    var komgaBookID: String?
    var remoteCoverID: String?
    var remoteCoverURL: String?
    var remotePageCount: Int?
    var chapterTypeRaw: String?
    var chapterPath: String?
    var seriesID: UUID?
    var currentPageIndex: Int
    var furthestPageIndex: Int
    var progressUpdatedAt: Date
    var hasBeenOpened: Bool
    var scrollProgress: Double
    var scrollPageProgress: Double
    var lastReadAt: Date
    var isLocked: Bool
    var isOCREnabled: Bool
    var isAITranslationEnabled: Bool
    var isAutoTranslationEnabled: Bool
    var isAutoOCRMagnificationEnabled: Bool
    var ocrTextScale: Double
    var ocrSafeAreaInset: Double
    var ocrMinimumTextHeight: Double
    var aiTranslationModeRaw: String
    var translationSourceLanguageRaw: String
    var hasInitializedReadingPreset: Bool
    var readingDirectionRaw: String
    var readingModeRaw: String
    var pageTurnAnimationRaw: String
    var imageFitModeRaw: String
    var scrollSpeedRaw: String
    var bookmarks: [ComicBookmark]

    nonisolated var sourceType: ComicSourceType {
        ComicSourceType(rawValue: sourceTypeRaw) ?? .local
    }

    nonisolated var aiTranslationMode: AITranslationMode {
        AITranslationMode(rawValue: aiTranslationModeRaw) ?? .ocr
    }

    nonisolated var translationSourceLanguage: TranslationSourceLanguage {
        TranslationSourceLanguage(rawValue: translationSourceLanguageRaw) ?? .automatic
    }

    nonisolated init(id: UUID = UUID(), title: String, bookmarkData: Data, totalPages: Int, coverImagePath: String? = nil, fileSize: Int64 = 0, libraryPath: String? = nil, sourceTypeRaw: String = ComicSourceType.local.rawValue, sourceURL: String? = nil, mediaSourceID: UUID? = nil, komgaLibraryID: String? = nil, komgaSeriesID: String? = nil, komgaBookID: String? = nil, remoteCoverID: String? = nil, remoteCoverURL: String? = nil, remotePageCount: Int? = nil, chapterTypeRaw: String? = nil, chapterPath: String? = nil, seriesID: UUID? = nil, currentPageIndex: Int = 0, furthestPageIndex: Int? = nil, progressUpdatedAt: Date = .distantPast, hasBeenOpened: Bool = false, scrollProgress: Double = 0, scrollPageProgress: Double = 0, lastReadAt: Date = .distantPast, isLocked: Bool = false, isOCREnabled: Bool = true, isAITranslationEnabled: Bool = true, isAutoTranslationEnabled: Bool = false, isAutoOCRMagnificationEnabled: Bool = false, ocrTextScale: Double = 0.55, ocrSafeAreaInset: Double = 0, ocrMinimumTextHeight: Double = 0.002, aiTranslationModeRaw: String = AITranslationMode.ocr.rawValue, translationSourceLanguageRaw: String = TranslationSourceLanguage.automatic.rawValue, hasInitializedReadingPreset: Bool = false, readingDirectionRaw: String = "leftToRight", readingModeRaw: String = "horizontalPage", pageTurnAnimationRaw: String = "slide", imageFitModeRaw: String = "fitScreen", scrollSpeedRaw: String = "standard", bookmarks: [ComicBookmark] = []) {
        self.id = id
        self.title = title
        self.bookmarkData = bookmarkData
        self.totalPages = totalPages
        self.coverImagePath = coverImagePath
        self.fileSize = fileSize
        self.libraryPath = libraryPath
        self.sourceTypeRaw = sourceTypeRaw
        self.sourceURL = sourceURL
        self.mediaSourceID = mediaSourceID
        self.komgaLibraryID = komgaLibraryID
        self.komgaSeriesID = komgaSeriesID
        self.komgaBookID = komgaBookID
        self.remoteCoverID = remoteCoverID
        self.remoteCoverURL = remoteCoverURL
        self.remotePageCount = remotePageCount
        self.chapterTypeRaw = chapterTypeRaw
        self.chapterPath = chapterPath
        self.seriesID = seriesID
        self.currentPageIndex = currentPageIndex
        self.furthestPageIndex = max(currentPageIndex, furthestPageIndex ?? currentPageIndex)
        self.progressUpdatedAt = progressUpdatedAt
        self.hasBeenOpened = hasBeenOpened
        self.scrollProgress = scrollProgress
        self.scrollPageProgress = scrollPageProgress
        self.lastReadAt = lastReadAt
        self.isLocked = isLocked
        self.isOCREnabled = isOCREnabled
        self.isAITranslationEnabled = isAITranslationEnabled
        self.isAutoTranslationEnabled = isAutoTranslationEnabled
        self.isAutoOCRMagnificationEnabled = isAutoOCRMagnificationEnabled
        self.ocrTextScale = ocrTextScale
        self.ocrSafeAreaInset = ocrSafeAreaInset
        self.ocrMinimumTextHeight = ocrMinimumTextHeight
        self.aiTranslationModeRaw = aiTranslationModeRaw
        self.translationSourceLanguageRaw = translationSourceLanguageRaw
        self.hasInitializedReadingPreset = hasInitializedReadingPreset
        self.readingDirectionRaw = readingDirectionRaw
        self.readingModeRaw = readingModeRaw
        self.pageTurnAnimationRaw = pageTurnAnimationRaw
        self.imageFitModeRaw = imageFitModeRaw
        self.scrollSpeedRaw = scrollSpeedRaw
        self.bookmarks = bookmarks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decode(String.self, forKey: .title)
        bookmarkData = try container.decode(Data.self, forKey: .bookmarkData)
        totalPages = try container.decode(Int.self, forKey: .totalPages)
        coverImagePath = try container.decodeIfPresent(String.self, forKey: .coverImagePath)
        fileSize = try container.decodeIfPresent(Int64.self, forKey: .fileSize) ?? 0
        libraryPath = try container.decodeIfPresent(String.self, forKey: .libraryPath)
        sourceTypeRaw = try container.decodeIfPresent(String.self, forKey: .sourceTypeRaw) ?? ComicSourceType.local.rawValue
        sourceURL = try container.decodeIfPresent(String.self, forKey: .sourceURL)
        mediaSourceID = try container.decodeIfPresent(UUID.self, forKey: .mediaSourceID)
        komgaLibraryID = try container.decodeIfPresent(String.self, forKey: .komgaLibraryID)
        komgaSeriesID = try container.decodeIfPresent(String.self, forKey: .komgaSeriesID)
        komgaBookID = try container.decodeIfPresent(String.self, forKey: .komgaBookID)
        remoteCoverID = try container.decodeIfPresent(String.self, forKey: .remoteCoverID)
        remoteCoverURL = try container.decodeIfPresent(String.self, forKey: .remoteCoverURL)
        remotePageCount = try container.decodeIfPresent(Int.self, forKey: .remotePageCount)
        chapterTypeRaw = try container.decodeIfPresent(String.self, forKey: .chapterTypeRaw)
        chapterPath = try container.decodeIfPresent(String.self, forKey: .chapterPath)
        seriesID = try container.decodeIfPresent(UUID.self, forKey: .seriesID)
        currentPageIndex = try container.decodeIfPresent(Int.self, forKey: .currentPageIndex) ?? 0
        furthestPageIndex = max(currentPageIndex, try container.decodeIfPresent(Int.self, forKey: .furthestPageIndex) ?? currentPageIndex)
        progressUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .progressUpdatedAt) ?? .distantPast
        hasBeenOpened = try container.decodeIfPresent(Bool.self, forKey: .hasBeenOpened) ?? (currentPageIndex > 0)
        scrollProgress = try container.decodeIfPresent(Double.self, forKey: .scrollProgress) ?? 0
        scrollPageProgress = try container.decodeIfPresent(Double.self, forKey: .scrollPageProgress) ?? 0
        lastReadAt = try container.decodeIfPresent(Date.self, forKey: .lastReadAt) ?? .distantPast
        isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        isOCREnabled = try container.decodeIfPresent(Bool.self, forKey: .isOCREnabled) ?? true
        isAITranslationEnabled = try container.decodeIfPresent(Bool.self, forKey: .isAITranslationEnabled) ?? true
        isAutoTranslationEnabled = try container.decodeIfPresent(Bool.self, forKey: .isAutoTranslationEnabled) ?? false
        isAutoOCRMagnificationEnabled = try container.decodeIfPresent(Bool.self, forKey: .isAutoOCRMagnificationEnabled) ?? false
        ocrTextScale = try container.decodeIfPresent(Double.self, forKey: .ocrTextScale) ?? 0.55
        ocrSafeAreaInset = try container.decodeIfPresent(Double.self, forKey: .ocrSafeAreaInset) ?? 0
        ocrMinimumTextHeight = try container.decodeIfPresent(Double.self, forKey: .ocrMinimumTextHeight) ?? 0.002
        aiTranslationModeRaw = try container.decodeIfPresent(String.self, forKey: .aiTranslationModeRaw) ?? AITranslationMode.ocr.rawValue
        translationSourceLanguageRaw = try container.decodeIfPresent(String.self, forKey: .translationSourceLanguageRaw) ?? TranslationSourceLanguage.automatic.rawValue
        hasInitializedReadingPreset = try container.decodeIfPresent(Bool.self, forKey: .hasInitializedReadingPreset) ?? true
        readingDirectionRaw = try container.decodeIfPresent(String.self, forKey: .readingDirectionRaw) ?? "leftToRight"
        readingModeRaw = try container.decodeIfPresent(String.self, forKey: .readingModeRaw) ?? "horizontalPage"
        pageTurnAnimationRaw = try container.decodeIfPresent(String.self, forKey: .pageTurnAnimationRaw) ?? "slide"
        imageFitModeRaw = try container.decodeIfPresent(String.self, forKey: .imageFitModeRaw) ?? "fitScreen"
        scrollSpeedRaw = try container.decodeIfPresent(String.self, forKey: .scrollSpeedRaw) ?? "standard"
        bookmarks = try container.decodeIfPresent([ComicBookmark].self, forKey: .bookmarks) ?? []
    }
}

nonisolated enum ReadingProgressMergePolicy {
    struct Resolution: Equatable, Sendable {
        let currentPageIndex: Int
        let furthestPageIndex: Int
        let progressUpdatedAt: Date
        let usesIncomingLocation: Bool
    }

    static func resolve(existing: ComicBook, incoming: ComicBook, totalPages: Int) -> Resolution {
        let pageLimit = max(0, totalPages - 1)
        let usesIncoming = incoming.progressUpdatedAt > existing.progressUpdatedAt
        let selectedPage = usesIncoming ? incoming.currentPageIndex : existing.currentPageIndex
        return Resolution(
            currentPageIndex: min(max(selectedPage, 0), pageLimit),
            furthestPageIndex: min(
                max(
                    max(existing.furthestPageIndex, incoming.furthestPageIndex),
                    max(existing.currentPageIndex, incoming.currentPageIndex)
                ),
                pageLimit
            ),
            progressUpdatedAt: max(existing.progressUpdatedAt, incoming.progressUpdatedAt),
            usesIncomingLocation: usesIncoming
        )
    }

    static func serverPageIndex(for comic: ComicBook) -> Int {
        min(max(comic.furthestPageIndex, 0), max(0, comic.totalPages - 1))
    }
}
