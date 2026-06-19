import Foundation

enum ComicSourceType: String, Codable, Hashable {
    case local
    case smb
    case webdav
}

struct ComicBook: Identifiable, Codable, Hashable {
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
    var chapterTypeRaw: String?
    var chapterPath: String?
    var seriesID: UUID?
    var currentPageIndex: Int
    var lastReadAt: Date
    var isLocked: Bool
    var isOCREnabled: Bool
    var isAITranslationEnabled: Bool
    var isAutoTranslationEnabled: Bool
    var readingDirectionRaw: String
    var readingModeRaw: String
    var pageTurnAnimationRaw: String
    var imageFitModeRaw: String

    var sourceType: ComicSourceType {
        ComicSourceType(rawValue: sourceTypeRaw) ?? .local
    }

    init(id: UUID = UUID(), title: String, bookmarkData: Data, totalPages: Int, coverImagePath: String? = nil, fileSize: Int64 = 0, libraryPath: String? = nil, sourceTypeRaw: String = ComicSourceType.local.rawValue, sourceURL: String? = nil, smbPath: String? = nil, chapterTypeRaw: String? = nil, chapterPath: String? = nil, seriesID: UUID? = nil, currentPageIndex: Int = 0, lastReadAt: Date = Date(), isLocked: Bool = false, isOCREnabled: Bool = true, isAITranslationEnabled: Bool = true, isAutoTranslationEnabled: Bool = false, readingDirectionRaw: String = "leftToRight", readingModeRaw: String = "horizontalPage", pageTurnAnimationRaw: String = "slide", imageFitModeRaw: String = "fitScreen") {
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
        self.chapterTypeRaw = chapterTypeRaw
        self.chapterPath = chapterPath
        self.seriesID = seriesID
        self.currentPageIndex = currentPageIndex
        self.lastReadAt = lastReadAt
        self.isLocked = isLocked
        self.isOCREnabled = isOCREnabled
        self.isAITranslationEnabled = isAITranslationEnabled
        self.isAutoTranslationEnabled = isAutoTranslationEnabled
        self.readingDirectionRaw = readingDirectionRaw
        self.readingModeRaw = readingModeRaw
        self.pageTurnAnimationRaw = pageTurnAnimationRaw
        self.imageFitModeRaw = imageFitModeRaw
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
        chapterTypeRaw = try container.decodeIfPresent(String.self, forKey: .chapterTypeRaw)
        chapterPath = try container.decodeIfPresent(String.self, forKey: .chapterPath)
        seriesID = try container.decodeIfPresent(UUID.self, forKey: .seriesID)
        currentPageIndex = try container.decodeIfPresent(Int.self, forKey: .currentPageIndex) ?? 0
        lastReadAt = try container.decodeIfPresent(Date.self, forKey: .lastReadAt) ?? Date()
        isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        isOCREnabled = try container.decodeIfPresent(Bool.self, forKey: .isOCREnabled) ?? true
        isAITranslationEnabled = try container.decodeIfPresent(Bool.self, forKey: .isAITranslationEnabled) ?? true
        isAutoTranslationEnabled = try container.decodeIfPresent(Bool.self, forKey: .isAutoTranslationEnabled) ?? false
        readingDirectionRaw = try container.decodeIfPresent(String.self, forKey: .readingDirectionRaw) ?? "leftToRight"
        readingModeRaw = try container.decodeIfPresent(String.self, forKey: .readingModeRaw) ?? "horizontalPage"
        pageTurnAnimationRaw = try container.decodeIfPresent(String.self, forKey: .pageTurnAnimationRaw) ?? "slide"
        imageFitModeRaw = try container.decodeIfPresent(String.self, forKey: .imageFitModeRaw) ?? "fitScreen"
    }
}
