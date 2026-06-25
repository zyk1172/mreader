import Foundation

nonisolated enum KomgaAPIEndpoint {
    static func book(bookID: String) -> String {
        "/api/v1/books/\(bookID)"
    }

    static func readProgress(bookID: String) -> String {
        "/api/v1/books/\(bookID)/read-progress"
    }

    static func deleteBookFile(bookID: String) -> String {
        "/api/v1/books/\(bookID)/file"
    }
}

nonisolated struct KomgaAPIClient: Sendable {
    let baseURL: URL
    let apiKey: String
    var timeout: TimeInterval = 20

    init(baseURLString: String, apiKey: String) throws {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw MediaSourceError.invalidURL
        }
        self.baseURL = url
        self.apiKey = apiKey
    }

    func testConnection() async throws -> [KomgaLibraryDTO] {
        try await libraries()
    }

    func libraries() async throws -> [KomgaLibraryDTO] {
        try await sendList(path: "/api/v1/libraries")
    }

    func series(libraryID: String) async throws -> [KomgaSeriesDTO] {
        try await sendList(path: "/api/v1/series", queryItems: [
            URLQueryItem(name: "library_id", value: libraryID),
            URLQueryItem(name: "size", value: "500")
        ])
    }

    func books(libraryID: String) async throws -> [KomgaBookDTO] {
        try await sendList(path: "/api/v1/books", queryItems: [
            URLQueryItem(name: "library_id", value: libraryID),
            URLQueryItem(name: "size", value: "500")
        ])
    }

    func books(seriesID: String) async throws -> [KomgaBookDTO] {
        try await sendList(path: "/api/v1/series/\(seriesID)/books", queryItems: [
            URLQueryItem(name: "size", value: "500")
        ])
    }

    func book(bookID: String) async throws -> KomgaBookDTO {
        try await sendItem(path: KomgaAPIEndpoint.book(bookID: bookID))
    }

    func pages(bookID: String) async throws -> [KomgaPageDTO] {
        try await sendList(path: "/api/v1/books/\(bookID)/pages")
    }

    func thumbnailData(bookID: String) async throws -> Data {
        try await sendData(path: "/api/v1/books/\(bookID)/thumbnail")
    }

    func pageData(bookID: String, pageIndex: Int) async throws -> Data {
        try await sendData(path: "/api/v1/books/\(bookID)/pages/\(pageIndex + 1)")
    }

    func readProgress(bookID: String) async throws -> KomgaReadProgressDTO? {
        (try await book(bookID: bookID)).readProgress
    }

    func updateReadProgress(bookID: String, pageIndex: Int, totalPages: Int) async throws {
        let completed = pageIndex >= max(totalPages - 1, 0)
        let payload = KomgaReadProgressUpdateDTO(pageIndex: pageIndex, completed: completed)
        let data = try JSONEncoder().encode(payload)
        try await sendNoContent(path: KomgaAPIEndpoint.readProgress(bookID: bookID), method: "PATCH", body: data)
    }

    func deleteBook(bookID: String) async throws {
        try await sendNoContent(path: KomgaAPIEndpoint.deleteBookFile(bookID: bookID), method: "DELETE")
    }

    private func sendItem<T: Decodable & Sendable>(path: String) async throws -> T {
        let data = try await sendData(path: path, acceptsImage: false)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw MediaSourceError.decodingFailed
        }
    }

    private func sendList<T: Decodable & Sendable>(path: String, queryItems: [URLQueryItem] = []) async throws -> [T] {
        guard queryItems.contains(where: { $0.name == "size" && $0.value == "500" }) else {
            let data = try await sendData(path: path, queryItems: queryItems, acceptsImage: false)
            return try decodeList([T].self, from: data)
        }

        var pagedItems: [T] = []
        var page = 0
        repeat {
            var items = queryItems
            if !items.contains(where: { $0.name == "page" }) {
                items.append(URLQueryItem(name: "page", value: "\(page)"))
            }
            let data = try await sendData(path: path, queryItems: items, acceptsImage: false)
            let decoded = try decodeList([T].self, from: data)
            pagedItems.append(contentsOf: decoded)
            if decoded.count < 500 {
                break
            }
            page += 1
        } while page < 20
        return pagedItems
    }

    private func decodeList<T: Decodable & Sendable>(_ type: [T].Type, from data: Data) throws -> [T] {
        let decoder = JSONDecoder()
        if let array = try? decoder.decode([T].self, from: data) {
            return array
        }
        if let page = try? decoder.decode(KomgaPageResponse<T>.self, from: data) {
            return page.content
        }
        throw MediaSourceError.decodingFailed
    }

    private func sendData(path: String, queryItems: [URLQueryItem] = [], acceptsImage: Bool = true) async throws -> Data {
        let request = try makeRequest(path: path, queryItems: queryItems, acceptsImage: acceptsImage)
        return try await send(request)
    }

    private func sendNoContent(path: String, method: String, body: Data? = nil) async throws {
        var request = try makeRequest(path: path, queryItems: [], acceptsImage: false)
        request.httpMethod = method
        request.httpBody = body
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        _ = try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw MediaSourceError.invalidResponse
            }
            let preview = String(data: data.prefix(500), encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
            print("Komga HTTP \(httpResponse.statusCode) \(request.url?.absoluteString ?? "<unknown>") response=\(preview)")
            switch httpResponse.statusCode {
            case 200..<300:
                return data
            case 401, 403:
                throw MediaSourceError.unauthorized
            case 404:
                throw MediaSourceError.notFound
            default:
                let body = String(data: data.prefix(400), encoding: .utf8)
                throw MediaSourceError.serverError(httpResponse.statusCode, body)
            }
        } catch let error as MediaSourceError {
            throw error
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                throw MediaSourceError.timeout
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost, .notConnectedToInternet:
                throw MediaSourceError.unreachable
            case .badURL, .unsupportedURL:
                throw MediaSourceError.invalidURL
            default:
                throw MediaSourceError.unreachable
            }
        } catch {
            throw MediaSourceError.invalidResponse
        }
    }

    private func makeRequest(path: String, queryItems: [URLQueryItem], acceptsImage: Bool) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw MediaSourceError.invalidURL
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpointPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + ([basePath, endpointPath].filter { !$0.isEmpty }.joined(separator: "/"))
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw MediaSourceError.invalidURL
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(acceptsImage ? "image/*,*/*" : "application/json", forHTTPHeaderField: "Accept")
        return request
    }
}
