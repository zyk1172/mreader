import Foundation

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
        do {
            return try await sendList(path: "/api/v1/libraries/\(libraryID)/series", queryItems: [
                URLQueryItem(name: "size", value: "500")
            ])
        } catch {
            do {
                return try await sendList(path: "/api/v1/series", queryItems: [
                    URLQueryItem(name: "library_id", value: libraryID),
                    URLQueryItem(name: "size", value: "500")
                ])
            } catch {
                return try await sendList(path: "/api/v1/series", queryItems: [
                    URLQueryItem(name: "libraryId", value: libraryID),
                    URLQueryItem(name: "size", value: "500")
                ])
            }
        }
    }

    func books(libraryID: String) async throws -> [KomgaBookDTO] {
        do {
            return try await sendList(path: "/api/v1/libraries/\(libraryID)/books", queryItems: [
                URLQueryItem(name: "size", value: "500")
            ])
        } catch {
            do {
                return try await sendList(path: "/api/v1/books", queryItems: [
                    URLQueryItem(name: "library_id", value: libraryID),
                    URLQueryItem(name: "size", value: "500")
                ])
            } catch {
                return try await sendList(path: "/api/v1/books", queryItems: [
                    URLQueryItem(name: "libraryId", value: libraryID),
                    URLQueryItem(name: "size", value: "500")
                ])
            }
        }
    }

    func seriesSearch(libraryID: String) async throws -> [KomgaSeriesDTO] {
        do {
            return try await sendList(path: "/api/v1/series/list", queryItems: [
                URLQueryItem(name: "library_id", value: libraryID),
                URLQueryItem(name: "size", value: "500")
            ])
        } catch {
            return try await sendList(path: "/api/v1/series", queryItems: [
                URLQueryItem(name: "libraryId", value: libraryID),
                URLQueryItem(name: "size", value: "500")
            ])
        }
    }

    func books(seriesID: String) async throws -> [KomgaBookDTO] {
        do {
            return try await sendList(path: "/api/v1/series/\(seriesID)/books", queryItems: [
                URLQueryItem(name: "size", value: "500")
            ])
        } catch {
            do {
                return try await sendList(path: "/api/v1/books", queryItems: [
                    URLQueryItem(name: "series_id", value: seriesID),
                    URLQueryItem(name: "size", value: "500")
                ])
            } catch {
                return try await sendList(path: "/api/v1/books", queryItems: [
                    URLQueryItem(name: "seriesId", value: seriesID),
                    URLQueryItem(name: "size", value: "500")
                ])
            }
        }
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
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw MediaSourceError.invalidResponse
            }
            let preview = String(data: data.prefix(500), encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
            print("Komga HTTP \(httpResponse.statusCode) \(request.url?.absoluteString ?? path) response=\(preview)")
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
