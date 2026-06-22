import Foundation

nonisolated enum MediaSourceType: String, Codable, Hashable, Sendable {
    case local
    case komga
}

nonisolated struct MediaSource: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var type: MediaSourceType
    var baseURL: String
    var username: String?
    var createdAt: Date
    var lastSyncAt: Date?
    var isEnabled: Bool

    init(id: UUID = UUID(), name: String, type: MediaSourceType, baseURL: String, username: String? = nil, createdAt: Date = Date(), lastSyncAt: Date? = nil, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.type = type
        self.baseURL = baseURL
        self.username = username
        self.createdAt = createdAt
        self.lastSyncAt = lastSyncAt
        self.isEnabled = isEnabled
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
            return "认证失败，请检查 Komga API Key"
        case .unreachable:
            return "无法连接到 Komga 服务器"
        case .invalidResponse:
            return "服务器返回了无法识别的响应"
        case .notFound:
            return "Komga 资源不存在"
        case .timeout:
            return "连接超时"
        case .decodingFailed:
            return "Komga JSON 解析失败"
        case .imageLoadFailed:
            return "页面图片加载失败"
        case .apiKeyMissing:
            return "缺少 Komga API Key"
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
    func decodeFlexibleString(forKey key: Key) -> String? {
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

    func decodeFlexibleInt(forKey key: Key) -> Int? {
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
