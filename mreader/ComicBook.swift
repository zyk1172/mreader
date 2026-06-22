import Foundation

enum ComicSourceType: String, Codable, Hashable, Sendable {
    case local
    case komga
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
    var smbPath: String?
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
    var readingDirectionRaw: String
    var readingModeRaw: String
    var pageTurnAnimationRaw: String
    var imageFitModeRaw: String
    var scrollSpeedRaw: String

    nonisolated var sourceType: ComicSourceType {
        ComicSourceType(rawValue: sourceTypeRaw) ?? .local
    }

    init(id: UUID = UUID(), title: String, bookmarkData: Data, totalPages: Int, coverImagePath: String? = nil, fileSize: Int64 = 0, libraryPath: String? = nil, sourceTypeRaw: String = ComicSourceType.local.rawValue, sourceURL: String? = nil, smbPath: String? = nil, mediaSourceID: UUID? = nil, komgaLibraryID: String? = nil, komgaSeriesID: String? = nil, komgaBookID: String? = nil, remoteCoverID: String? = nil, remoteCoverURL: String? = nil, remotePageCount: Int? = nil, chapterTypeRaw: String? = nil, chapterPath: String? = nil, seriesID: UUID? = nil, currentPageIndex: Int = 0, scrollProgress: Double = 0, scrollPageProgress: Double = 0, lastReadAt: Date = Date(), isLocked: Bool = false, isOCREnabled: Bool = true, isAITranslationEnabled: Bool = true, isAutoTranslationEnabled: Bool = false, isAutoOCRMagnificationEnabled: Bool = false, ocrTextScale: Double = 0.55, ocrSafeAreaInset: Double = 0.05, ocrMinimumTextHeight: Double = 0.014, readingDirectionRaw: String = "leftToRight", readingModeRaw: String = "horizontalPage", pageTurnAnimationRaw: String = "slide", imageFitModeRaw: String = "fitScreen", scrollSpeedRaw: String = "standard") {
        self.id = id
        self.title = title
        self.bookmarkData = bookmarkData
        self.totalPages = totalPages
        self.coverImagePath = coverImagePath
        self.fileSize = fileSize
        self.libraryPath = libraryPath
        self.sourceTypeRaw = sourceTypeRaw
        self.sourceURL = sourceURL
        self.smbPath = smbPath
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
        self.readingDirectionRaw = readingDirectionRaw
        self.readingModeRaw = readingModeRaw
        self.pageTurnAnimationRaw = pageTurnAnimationRaw
        self.imageFitModeRaw = imageFitModeRaw
        self.scrollSpeedRaw = scrollSpeedRaw
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
        smbPath = try container.decodeIfPresent(String.self, forKey: .smbPath)
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
        scrollProgress = try container.decodeIfPresent(Double.self, forKey: .scrollProgress) ?? 0
        scrollPageProgress = try container.decodeIfPresent(Double.self, forKey: .scrollPageProgress) ?? 0
        lastReadAt = try container.decodeIfPresent(Date.self, forKey: .lastReadAt) ?? Date()
        isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        isOCREnabled = try container.decodeIfPresent(Bool.self, forKey: .isOCREnabled) ?? true
        isAITranslationEnabled = try container.decodeIfPresent(Bool.self, forKey: .isAITranslationEnabled) ?? true
        isAutoTranslationEnabled = try container.decodeIfPresent(Bool.self, forKey: .isAutoTranslationEnabled) ?? false
        isAutoOCRMagnificationEnabled = try container.decodeIfPresent(Bool.self, forKey: .isAutoOCRMagnificationEnabled) ?? false
        ocrTextScale = try container.decodeIfPresent(Double.self, forKey: .ocrTextScale) ?? 0.55
        ocrSafeAreaInset = try container.decodeIfPresent(Double.self, forKey: .ocrSafeAreaInset) ?? 0.05
        ocrMinimumTextHeight = try container.decodeIfPresent(Double.self, forKey: .ocrMinimumTextHeight) ?? 0.014
        readingDirectionRaw = try container.decodeIfPresent(String.self, forKey: .readingDirectionRaw) ?? "leftToRight"
        readingModeRaw = try container.decodeIfPresent(String.self, forKey: .readingModeRaw) ?? "horizontalPage"
        pageTurnAnimationRaw = try container.decodeIfPresent(String.self, forKey: .pageTurnAnimationRaw) ?? "slide"
        imageFitModeRaw = try container.decodeIfPresent(String.self, forKey: .imageFitModeRaw) ?? "fitScreen"
        scrollSpeedRaw = try container.decodeIfPresent(String.self, forKey: .scrollSpeedRaw) ?? "standard"
    }
}
