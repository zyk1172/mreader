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
    nonisolated static let defaultBorderlessTranslationFontSize = 14.0
    nonisolated static let borderlessTranslationFontSizeRange: ClosedRange<Double> = 8...28

    nonisolated static func clampedBorderlessTranslationFontSize(_ value: Double) -> Double {
        min(
            max(value, borderlessTranslationFontSizeRange.lowerBound),
            borderlessTranslationFontSizeRange.upperBound
        )
    }

    // The stored property and Codable key keep their legacy names so existing
    // reading settings continue to decode. New call sites use the product
    // terminology: measured text describes the geometry strategy.
    nonisolated static let defaultMeasuredTextTranslationFontSize = defaultBorderlessTranslationFontSize
    nonisolated static let measuredTextTranslationFontSizeRange = borderlessTranslationFontSizeRange

    nonisolated static func clampedMeasuredTextTranslationFontSize(_ value: Double) -> Double {
        clampedBorderlessTranslationFontSize(value)
    }

    /// Readability floor for in-page translation. This is a user preference,
    /// not a claim that one point size is universally correct for every comic.
    nonisolated static let defaultMinimumReadableTranslationFontSize = 9.0
    nonisolated static let minimumReadableTranslationFontSizeRange: ClosedRange<Double> = 6...18

    nonisolated static func clampedMinimumReadableTranslationFontSize(_ value: Double) -> Double {
        min(
            max(value, minimumReadableTranslationFontSizeRange.lowerBound),
            minimumReadableTranslationFontSizeRange.upperBound
        )
    }

    var id: UUID
    var title: String
    var bookmarkData: Data // 核心：保存文件夹的持久化安全访问权限
    var totalPages: Int
    var coverImagePath: String?
    var fileSize: Int64
    var libraryPath: String?
    var libraryRelativePath: String?
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
    var metadataUpdatedAt: Date
    var hasBeenOpened: Bool
    var scrollProgress: Double
    var scrollPageProgress: Double
    var lastReadAt: Date
    var isLocked: Bool
    var isOCREnabled: Bool
    var isAITranslationEnabled: Bool
    var isAutoTranslationEnabled: Bool
    /// 是否在当前漫画阅读页显示已经落盘的本地译文；只控制显示，不删除离线数据。
    var isOfflineTranslationOverlayEnabled: Bool
    var isAutoOCRMagnificationEnabled: Bool
    var ocrTextScale: Double
    var ocrSafeAreaInset: Double
    var ocrMinimumTextHeight: Double
    /// measuredText 表面使用的译文字号；这是显示参数，不参与 OCR/翻译缓存。
    /// 属性名保留旧版 Codable 字段名，以兼容已有阅读设置。
    var borderlessTranslationFontSize: Double
    /// Minimum point size at which translation is rendered in-place. When a
    /// region cannot fit at this size, layout returns `needsExpansion` instead
    /// of silently shrinking to microscopic text.
    var minimumReadableTranslationFontSize: Double
    /// Opt-in, non-destructive original-position rendering for reliable dialogue bubbles.
    /// The image itself is never modified; disabling this immediately restores the artwork.
    var prefersInPlaceTranslation: Bool

    var measuredTextTranslationFontSize: Double {
        get { borderlessTranslationFontSize }
        set { borderlessTranslationFontSize = ComicBook.clampedMeasuredTextTranslationFontSize(newValue) }
    }
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

    nonisolated init(id: UUID = UUID(), title: String, bookmarkData: Data, totalPages: Int, coverImagePath: String? = nil, fileSize: Int64 = 0, libraryPath: String? = nil, libraryRelativePath: String? = nil, sourceTypeRaw: String = ComicSourceType.local.rawValue, sourceURL: String? = nil, mediaSourceID: UUID? = nil, komgaLibraryID: String? = nil, komgaSeriesID: String? = nil, komgaBookID: String? = nil, remoteCoverID: String? = nil, remoteCoverURL: String? = nil, remotePageCount: Int? = nil, chapterTypeRaw: String? = nil, chapterPath: String? = nil, seriesID: UUID? = nil, currentPageIndex: Int = 0, furthestPageIndex: Int? = nil, progressUpdatedAt: Date = .distantPast, metadataUpdatedAt: Date = .distantPast, hasBeenOpened: Bool = false, scrollProgress: Double = 0, scrollPageProgress: Double = 0, lastReadAt: Date = .distantPast, isLocked: Bool = false, isOCREnabled: Bool = true, isAITranslationEnabled: Bool = true, isAutoTranslationEnabled: Bool = false, isOfflineTranslationOverlayEnabled: Bool = true, isAutoOCRMagnificationEnabled: Bool = false, ocrTextScale: Double = 0.55, ocrSafeAreaInset: Double = 0, ocrMinimumTextHeight: Double = 0.002, borderlessTranslationFontSize: Double = ComicBook.defaultBorderlessTranslationFontSize, minimumReadableTranslationFontSize: Double = ComicBook.defaultMinimumReadableTranslationFontSize, prefersInPlaceTranslation: Bool = false, aiTranslationModeRaw: String = AITranslationMode.ocr.rawValue, translationSourceLanguageRaw: String = TranslationSourceLanguage.automatic.rawValue, hasInitializedReadingPreset: Bool = false, readingDirectionRaw: String = "leftToRight", readingModeRaw: String = "horizontalPage", pageTurnAnimationRaw: String = "slide", imageFitModeRaw: String = "fitScreen", scrollSpeedRaw: String = "standard", bookmarks: [ComicBookmark] = []) {
        self.id = id
        self.title = title
        self.bookmarkData = bookmarkData
        self.totalPages = totalPages
        self.coverImagePath = coverImagePath
        self.fileSize = fileSize
        self.libraryPath = libraryPath
        self.libraryRelativePath = libraryRelativePath
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
        self.metadataUpdatedAt = metadataUpdatedAt
        self.hasBeenOpened = hasBeenOpened
        self.scrollProgress = scrollProgress
        self.scrollPageProgress = scrollPageProgress
        self.lastReadAt = lastReadAt
        self.isLocked = isLocked
        self.isOCREnabled = isOCREnabled
        self.isAITranslationEnabled = isAITranslationEnabled
        self.isAutoTranslationEnabled = isAutoTranslationEnabled
        self.isOfflineTranslationOverlayEnabled = isOfflineTranslationOverlayEnabled
        self.isAutoOCRMagnificationEnabled = isAutoOCRMagnificationEnabled
        self.ocrTextScale = ocrTextScale
        self.ocrSafeAreaInset = ocrSafeAreaInset
        self.ocrMinimumTextHeight = ocrMinimumTextHeight
        self.borderlessTranslationFontSize = ComicBook.clampedBorderlessTranslationFontSize(borderlessTranslationFontSize)
        self.minimumReadableTranslationFontSize = ComicBook.clampedMinimumReadableTranslationFontSize(minimumReadableTranslationFontSize)
        self.prefersInPlaceTranslation = prefersInPlaceTranslation
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
        libraryRelativePath = try container.decodeIfPresent(String.self, forKey: .libraryRelativePath)
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
        metadataUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .metadataUpdatedAt) ?? .distantPast
        hasBeenOpened = try container.decodeIfPresent(Bool.self, forKey: .hasBeenOpened) ?? (currentPageIndex > 0)
        scrollProgress = try container.decodeIfPresent(Double.self, forKey: .scrollProgress) ?? 0
        scrollPageProgress = try container.decodeIfPresent(Double.self, forKey: .scrollPageProgress) ?? 0
        lastReadAt = try container.decodeIfPresent(Date.self, forKey: .lastReadAt) ?? .distantPast
        isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        isOCREnabled = try container.decodeIfPresent(Bool.self, forKey: .isOCREnabled) ?? true
        isAITranslationEnabled = try container.decodeIfPresent(Bool.self, forKey: .isAITranslationEnabled) ?? true
        isAutoTranslationEnabled = try container.decodeIfPresent(Bool.self, forKey: .isAutoTranslationEnabled) ?? false
        isOfflineTranslationOverlayEnabled = try container.decodeIfPresent(Bool.self, forKey: .isOfflineTranslationOverlayEnabled) ?? true
        isAutoOCRMagnificationEnabled = try container.decodeIfPresent(Bool.self, forKey: .isAutoOCRMagnificationEnabled) ?? false
        ocrTextScale = try container.decodeIfPresent(Double.self, forKey: .ocrTextScale) ?? 0.55
        ocrSafeAreaInset = try container.decodeIfPresent(Double.self, forKey: .ocrSafeAreaInset) ?? 0
        ocrMinimumTextHeight = try container.decodeIfPresent(Double.self, forKey: .ocrMinimumTextHeight) ?? 0.002
        borderlessTranslationFontSize = ComicBook.clampedBorderlessTranslationFontSize(
            try container.decodeIfPresent(Double.self, forKey: .borderlessTranslationFontSize)
                ?? ComicBook.defaultBorderlessTranslationFontSize
        )
        minimumReadableTranslationFontSize = ComicBook.clampedMinimumReadableTranslationFontSize(
            try container.decodeIfPresent(Double.self, forKey: .minimumReadableTranslationFontSize)
                ?? ComicBook.defaultMinimumReadableTranslationFontSize
        )
        prefersInPlaceTranslation = try container.decodeIfPresent(Bool.self, forKey: .prefersInPlaceTranslation) ?? false
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
