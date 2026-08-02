import Foundation

nonisolated enum MediaSourceType: String, Codable, Hashable, Sendable {
    case local
    case komga
    case opds
}

nonisolated struct MediaSource: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var type: MediaSourceType
    var baseURL: String
    var lanURL: String?
    var username: String?
    var createdAt: Date
    var lastSyncAt: Date?
    var isEnabled: Bool

    nonisolated var resolvedBaseURL: String { baseURL }

    init(id: UUID = UUID(), name: String, type: MediaSourceType, baseURL: String, lanURL: String? = nil, username: String? = nil, createdAt: Date = Date(), lastSyncAt: Date? = nil, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.type = type
        self.baseURL = baseURL
        self.lanURL = lanURL
        self.username = username
        self.createdAt = createdAt
        self.lastSyncAt = lastSyncAt
        self.isEnabled = isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(MediaSourceType.self, forKey: .type)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        lanURL = try container.decodeIfPresent(String.self, forKey: .lanURL)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastSyncAt = try container.decodeIfPresent(Date.self, forKey: .lastSyncAt)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

nonisolated enum MediaSourceError: LocalizedError, Equatable, Sendable {
    case invalidURL
    case unauthorized
    case unreachable
    case invalidResponse
    case notFound
    case timeout
    case decodingFailed
    case imageLoadFailed
    case apiKeyMissing
    case keychainFailed(String)
    case serverError(Int, String?)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "服务器地址格式不正确"
        case .unauthorized:
            return "认证失败，请检查服务器凭据"
        case .unreachable:
            return "无法连接到 Komga 服务器"
        case .invalidResponse:
            return "服务器返回了无法识别的响应"
        case .notFound:
            return "远程资源不存在"
        case .timeout:
            return "连接超时"
        case .decodingFailed:
            return "服务器目录解析失败"
        case .imageLoadFailed:
            return "页面图片加载失败"
        case .apiKeyMissing:
            return "缺少服务器凭据"
        case .keychainFailed(let message):
            return "Keychain 保存失败：\(message)"
        case .serverError(let status, let body):
            if let body, !body.isEmpty {
                return "服务器错误 \(status)：\(body)"
            }
            return "服务器错误 \(status)"
        }
    }
}

nonisolated struct KomgaLibraryDTO: Decodable, Hashable, Sendable {
    let id: String
    let name: String
}

nonisolated struct KomgaSeriesDTO: Decodable, Hashable, Sendable {
    let id: String
    let libraryId: String?
    let name: String?
    let metadata: KomgaMetadataDTO?

    var displayTitle: String {
        let metadataTitle = metadata?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let metadataTitle, !metadataTitle.isEmpty {
            return metadataTitle
        }
        let nameTitle = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let nameTitle, !nameTitle.isEmpty {
            return nameTitle
        }
        return id
    }
}

nonisolated struct KomgaBookDTO: Decodable, Hashable, Sendable {
    let id: String
    let seriesId: String?
    let libraryId: String?
    let seriesTitle: String?
    let name: String?
    let url: String?
    let number: String?
    let pagesCount: Int?
    let pageCountValue: Int?
    let metadata: KomgaMetadataDTO?
    let media: KomgaBookMediaDTO?
    let readProgress: KomgaReadProgressDTO?

    var displayTitle: String {
        let metadataTitle = metadata?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let metadataTitle, !metadataTitle.isEmpty {
            return metadataTitle
        }
        let nameTitle = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let nameTitle, !nameTitle.isEmpty {
            return nameTitle
        }
        return id
    }

    var pageCount: Int? {
        pagesCount ?? pageCountValue ?? media?.pagesCount ?? media?.pageCount
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case seriesId
        case libraryId
        case seriesTitle
        case name
        case url
        case number
        case pagesCount
        case pageCountValue = "pageCount"
        case metadata
        case media
        case readProgress
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let decodedID = container.decodeFlexibleString(forKey: .id) else {
            throw DecodingError.keyNotFound(CodingKeys.id, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Komga book is missing id"))
        }
        id = decodedID
        seriesId = container.decodeFlexibleString(forKey: .seriesId)
        libraryId = container.decodeFlexibleString(forKey: .libraryId)
        seriesTitle = container.decodeFlexibleString(forKey: .seriesTitle)
        name = container.decodeFlexibleString(forKey: .name)
        url = container.decodeFlexibleString(forKey: .url)
        number = container.decodeFlexibleString(forKey: .number)
        pagesCount = container.decodeFlexibleInt(forKey: .pagesCount)
        pageCountValue = container.decodeFlexibleInt(forKey: .pageCountValue)
        metadata = try? container.decodeIfPresent(KomgaMetadataDTO.self, forKey: .metadata)
        media = try? container.decodeIfPresent(KomgaBookMediaDTO.self, forKey: .media)
        readProgress = try? container.decodeIfPresent(KomgaReadProgressDTO.self, forKey: .readProgress)
    }
}

nonisolated struct KomgaMetadataDTO: Decodable, Hashable, Sendable {
    let title: String?
}

nonisolated struct KomgaBookMediaDTO: Decodable, Hashable, Sendable {
    let pagesCount: Int?
    let pageCount: Int?

    private enum CodingKeys: String, CodingKey {
        case pagesCount
        case pageCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pagesCount = container.decodeFlexibleInt(forKey: .pagesCount)
        pageCount = container.decodeFlexibleInt(forKey: .pageCount)
    }
}

nonisolated struct KomgaPageDTO: Decodable, Hashable, Sendable {
    let number: Int?
    let fileName: String?
    let mediaType: String?
}

nonisolated struct KomgaReadProgressDTO: Decodable, Hashable, Sendable {
    let page: Int?
    let pageIndex: Int?
    let completed: Bool?
    let readDate: String?
    let created: String?
    let lastModified: String?

    var resolvedPageIndex: Int? {
        pageIndex ?? page.map { max($0 - 1, 0) }
    }

    var resolvedUpdatedAt: Date {
        [lastModified, readDate, created]
            .compactMap { value in
                guard let value else { return nil }
                return try? Date(value, strategy: .iso8601)
            }
            .max() ?? .distantPast
    }

    private enum CodingKeys: String, CodingKey {
        case page
        case pageIndex
        case completed
        case readDate
        case created
        case lastModified
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        page = container.decodeFlexibleInt(forKey: .page)
        pageIndex = container.decodeFlexibleInt(forKey: .pageIndex)
        completed = try? container.decodeIfPresent(Bool.self, forKey: .completed)
        readDate = container.decodeFlexibleString(forKey: .readDate)
        created = container.decodeFlexibleString(forKey: .created)
        lastModified = container.decodeFlexibleString(forKey: .lastModified)
    }
}

nonisolated struct KomgaReadProgressUpdateDTO: Encodable, Sendable {
    let page: Int
    let completed: Bool

    init(pageIndex: Int, completed: Bool) {
        self.page = pageIndex + 1
        self.completed = completed
    }
}

nonisolated struct RemoteReadingProgressSnapshot: Equatable, Sendable {
    let pageIndex: Int
    let updatedAt: Date
}

nonisolated struct KomgaPageResponse<T: Decodable & Sendable>: Decodable, Sendable {
    let content: [T]

    private enum CodingKeys: String, CodingKey {
        case content
        case items
        case results
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = try container.decodeIfPresent([T].self, forKey: .content)
            ?? container.decodeIfPresent([T].self, forKey: .items)
            ?? container.decodeIfPresent([T].self, forKey: .results)
            ?? []
    }
}

private extension KeyedDecodingContainer {
    nonisolated func decodeFlexibleString(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return String(value)
        }
        return nil
    }

    nonisolated func decodeFlexibleInt(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return Int(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}
