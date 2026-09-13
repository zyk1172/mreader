import Foundation
import os

nonisolated struct OPDSPublication: Hashable, Sendable {
    let id: String
    let title: String
    let acquisitionURL: URL
    let coverURL: URL?
    let mediaType: String?
}

nonisolated enum OPDSRemoteRevision {
    /// Content-Length 只能描述大小，不能单独证明内容身份；至少需要 ETag、Last-Modified
    /// 或 Content-Digest 之一。长度仅作为这些强身份的补充信息写入 revision。
    static func value(
        etag: String?,
        lastModified: String?,
        contentDigest: String?,
        contentLength: String?
    ) -> String? {
        let strong = [
            etag.map { "etag=\($0)" },
            lastModified.map { "last=\($0)" },
            contentDigest.map { "digest=\($0)" }
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !strong.isEmpty else { return nil }
        let length = contentLength?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (strong + (length?.isEmpty == false ? ["length=\(length!)"] : []))
            .joined(separator: "#")
    }
}

nonisolated enum OPDSResponseLimits {
    static let feedBytes = 16 * 1024 * 1024
    static let downloadBytes = 512 * 1024 * 1024
}

nonisolated struct OPDSSourceSyncResult: Sendable {
    let source: MediaSource
    let comics: [ComicBook]
    let isAuthoritative: Bool
    let error: Error?
}

nonisolated enum OPDSProvider {
    private static let coverScheme = "mreader-opds-cover"

    static func testConnection(baseURL: String, username: String?, credential: String) async throws -> Int {
        let source = try makeSource(name: "OPDS", baseURL: baseURL, username: username)
        let publications = try await OPDSClient(source: source, credential: credential).publications()
        return publications.count
    }

    static func parseCatalogForDiagnostics(data: Data, baseURL: URL, contentType: String) throws -> [OPDSPublication] {
        if contentType.lowercased().contains("json") || data.first == 0x7B {
            return try OPDSJSONParser.parse(data: data, baseURL: baseURL).publications
        }
        return try OPDSXMLFeedParser.parse(data: data, baseURL: baseURL).publications
    }

    static func addSource(name: String, baseURL: String, username: String?, credential: String, lanURL: String? = nil) async throws -> MediaSource {
        var source = try makeSource(name: name, baseURL: baseURL, username: username)
        source.lanURL = lanURL
        _ = try await OPDSClient(source: source, credential: credential).publications(limit: 1)
        source.lastSyncAt = Date()
        try KomgaProvider.saveAPIKey(credential, for: source.id)
        try await KomgaProvider.addOrReplaceSource(source, replacingType: .opds, baseURL: source.baseURL)
        return source
    }

    static func syncEnabledSources(sourceIDs: Set<UUID>? = nil) async -> [OPDSSourceSyncResult] {
        var results: [OPDSSourceSyncResult] = []
        var sources = await KomgaProvider.loadSources().filter { $0.type == .opds && $0.isEnabled }
        if let sourceIDs {
            sources = sources.filter { sourceIDs.contains($0.id) }
        }
        for source in sources {
            do {
                guard let credential = KomgaProvider.apiKey(for: source.id) else {
                    throw MediaSourceError.apiKeyMissing
                }
                var resolvedSource = source
                let resolvedURL = await KomgaProvider.resolveBestURL(source: source)
                resolvedSource.baseURL = resolvedURL
                let publications = try await OPDSClient(source: resolvedSource, credential: credential).publications()
                let comics = publications.map { makeComic(source: source, publication: $0) }
                var updatedSource = source
                updatedSource.lastSyncAt = Date()
                try? await KomgaProvider.updateSource(updatedSource)
                results.append(
                    OPDSSourceSyncResult(
                        source: updatedSource,
                        comics: comics,
                        isAuthoritative: true,
                        error: nil
                    )
                )
            } catch {
                results.append(
                    OPDSSourceSyncResult(
                        source: source,
                        comics: [],
                        isAuthoritative: false,
                        error: error
                    )
                )
            }
        }
        return results
    }

    /// OPDS 没有统一的 book metadata API；优先以 acquisition 响应的 ETag/Last-Modified/
    /// Content-Length 建立版本标识。服务端不提供这些 headers 时保留显式 unverified
    /// 标记，避免伪装成一个可靠的远程 revision。
    static func sourceRevision(for comic: ComicBook) async -> String {
        let fallback = "opds-unverified:\(comic.mediaSourceID?.uuidString ?? "")#\(comic.remoteCoverID ?? "")#\(comic.sourceURL ?? comic.chapterPath ?? "")#pages=\(comic.totalPages)"
        guard let sourceID = comic.mediaSourceID else {
            return fallback
        }
        let publicationID = comic.remoteCoverID ?? comic.sourceURL ?? comic.chapterPath ?? ""
        if let offlineURL = OfflinePageStore.opdsFile(sourceID: sourceID, publicationID: publicationID) {
            guard let data = try? Data(contentsOf: offlineURL), !data.isEmpty else {
                return fallback
            }
            return "opds-offline:\(OfflineTranslationFingerprint.sha256(for: data))"
        }
        guard
              let source = await KomgaProvider.loadSources().first(where: { $0.id == sourceID && $0.type == .opds && $0.isEnabled }),
              let credential = KomgaProvider.apiKey(for: sourceID),
              let value = comic.sourceURL ?? comic.chapterPath,
              let acquisitionURL = URL(string: value) else {
            return fallback
        }
        var resolvedSource = source
        resolvedSource.baseURL = await KomgaProvider.resolveBestURL(source: source)
        let client = OPDSClient(source: resolvedSource, credential: credential)
        guard let revision = await client.contentRevision(for: acquisitionURL) else {
            return fallback
        }
        return "opds:\(sourceID.uuidString)#\(comic.remoteCoverID ?? acquisitionURL.absoluteString)#\(revision)"
    }

    static func loadPages(for comic: ComicBook) async -> ComicManager.LoadResult? {
        guard comic.sourceType == .opds,
              let sourceID = comic.mediaSourceID,
              let source = await KomgaProvider.loadSources().first(where: { $0.id == sourceID && $0.type == .opds && $0.isEnabled }),
              let remoteURLString = comic.sourceURL,
              let remoteURL = URL(string: remoteURLString),
              let credential = KomgaProvider.apiKey(for: sourceID) else {
            return nil
        }

        let taskID = await BackgroundTaskCenter.shared.begin(
            title: "准备远程漫画",
            detail: comic.title
        )
        defer {
            Task { @MainActor in
                BackgroundTaskCenter.shared.finish(taskID)
            }
        }

        do {
            if let offlineURL = OfflinePageStore.opdsFile(sourceID: sourceID, publicationID: comic.remoteCoverID ?? remoteURL.absoluteString) {
                return await ComicManager.loadDownloadedRemotePages(from: offlineURL)
            }
            var resolvedSource = source
            let resolvedURL = await KomgaProvider.resolveBestURL(source: source)
            resolvedSource.baseURL = resolvedURL
            let publicationID = comic.remoteCoverID ?? remoteURL.absoluteString
            let localURL = try await OPDSClient(source: resolvedSource, credential: credential).download(
                remoteURL,
                publicationID: publicationID
            )
            return await ComicManager.loadDownloadedRemotePages(from: localURL)
        } catch {
            print("OPDS 漫画下载失败 \(comic.title): \(error.localizedDescription)")
            return nil
        }
    }

    static func downloadFile(for comic: ComicBook) async throws -> URL {
        guard comic.sourceType == .opds,
              let sourceID = comic.mediaSourceID,
              let source = await KomgaProvider.loadSources().first(where: { $0.id == sourceID && $0.type == .opds && $0.isEnabled }),
              let remoteURLString = comic.sourceURL,
              let remoteURL = URL(string: remoteURLString),
              let credential = KomgaProvider.apiKey(for: sourceID) else {
            throw MediaSourceError.invalidResponse
        }
        var resolvedSource = source
        resolvedSource.baseURL = await KomgaProvider.resolveBestURL(source: source)
        return try await OPDSClient(source: resolvedSource, credential: credential).download(
            remoteURL,
            publicationID: comic.remoteCoverID ?? remoteURL.absoluteString
        )
    }

    static func removeCachedFiles(sourceID: UUID) {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MReaderOPDSCache", isDirectory: true)
            .appendingPathComponent(sourceID.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        RemoteImageLoader.removeCachedImages(sourceID: sourceID)
    }

    static func coverReference(sourceID: UUID, publicationID: String, remoteURL: URL) -> String {
        var components = URLComponents()
        components.scheme = coverScheme
        components.host = sourceID.uuidString
        components.queryItems = [
            URLQueryItem(name: "id", value: publicationID),
            URLQueryItem(name: "url", value: remoteURL.absoluteString)
        ]
        return components.url?.absoluteString ?? remoteURL.absoluteString
    }

    static func isCoverReference(_ url: URL) -> Bool {
        url.scheme == coverScheme
    }

    static func coverData(for referenceURL: URL) async -> Data? {
        guard let components = URLComponents(url: referenceURL, resolvingAgainstBaseURL: false),
              let host = referenceURL.host,
              let sourceID = UUID(uuidString: host),
              let publicationID = components.queryItems?.first(where: { $0.name == "id" })?.value,
              let remoteValue = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let remoteURL = URL(string: remoteValue) else {
            return nil
        }
        if let path = RemoteImageLoader.cachedCoverPath(sourceID: sourceID, bookID: publicationID),
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            return data
        }
        guard let source = await KomgaProvider.loadSources().first(where: { $0.id == sourceID && $0.type == .opds && $0.isEnabled }),
              let credential = KomgaProvider.apiKey(for: sourceID),
              let data = try? await OPDSClient(source: source, credential: credential).data(from: remoteURL) else {
            return nil
        }
        _ = RemoteImageLoader.cacheCoverData(data, sourceID: sourceID, bookID: publicationID)
        return data
    }

    private static func makeSource(name: String, baseURL: String, username: String?) throws -> MediaSource {
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw MediaSourceError.invalidURL
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return MediaSource(
            name: trimmedName.isEmpty ? "OPDS" : trimmedName,
            type: .opds,
            baseURL: url.absoluteString,
            username: username?.trimmingCharacters(in: .whitespacesAndNewlines),
            isEnabled: true
        )
    }

    private static func makeComic(source: MediaSource, publication: OPDSPublication) -> ComicBook {
        let publicationFormat = formatName(for: publication)
        return ComicBook(
            title: publication.title,
            bookmarkData: Data(),
            totalPages: 1,
            coverImagePath: publication.coverURL.map {
                coverReference(sourceID: source.id, publicationID: publication.id, remoteURL: $0)
            },
            sourceTypeRaw: ComicSourceType.opds.rawValue,
            sourceURL: publication.acquisitionURL.absoluteString,
            mediaSourceID: source.id,
            remoteCoverID: publication.id,
            remoteCoverURL: publication.coverURL?.absoluteString,
            remotePageCount: nil,
            chapterTypeRaw: publicationFormat,
            chapterPath: publication.acquisitionURL.absoluteString
        )
    }

    private static func formatName(for publication: OPDSPublication) -> String {
        let pathExtension = publication.acquisitionURL.pathExtension.lowercased()
        if !pathExtension.isEmpty {
            return pathExtension
        }
        let mediaType = publication.mediaType?.lowercased() ?? ""
        if mediaType.contains("epub") { return "epub" }
        if mediaType.contains("pdf") { return "pdf" }
        if mediaType.contains("comicbook") || mediaType.contains("cbz") || mediaType.contains("zip") { return "cbz" }
        return ""
    }
}

/// Same-origin policy for forwarding OPDS source credentials.
///
/// OPDS feeds may embed absolute URLs (covers, acquisitions, navigation) pointing at third-party
/// hosts. Authorization (Basic/Bearer) must only ever be forwarded to the same origin (scheme +
/// host + effective port) as the configured source, so a malicious feed cannot exfiltrate the
/// source's credentials to another domain.
nonisolated enum OPDSAuthorizationPolicy {
    static func shouldForward(sourceBaseURL: String, to url: URL) -> Bool {
        guard let baseURL = URL(string: sourceBaseURL) else { return false }
        guard url.scheme?.lowercased() == baseURL.scheme?.lowercased() else { return false }
        guard url.host?.lowercased() == baseURL.host?.lowercased() else { return false }
        return effectivePort(of: url) == effectivePort(of: baseURL)
    }

    /// Resolves nil ports to the scheme's default port (80 for http, 443 for https) so that
    /// `http://host` and `http://host:80` compare equal.
    static func effectivePort(of url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}

nonisolated private struct OPDSClient: Sendable {
    let source: MediaSource
    let credential: String

    /// 目标访问策略：只把用户显式配置的 baseURL / lanURL 视为可信目标。
    /// 恶意 feed 提供的跨源私网 / 回环 / link-local 地址不会被自动跟随（审查 #11）。
    private var destination: RemoteDestinationPolicy.Context {
        RemoteDestinationPolicy.Context(source: source)
    }

    private func requireAllowedDestination(_ url: URL) throws {
        if case .denied(let denial) = destination.decision(for: url) {
            throw RemoteDestinationPolicyError.denied(
                denial,
                host: RemoteDestinationPolicy.normalizedHost(of: url) ?? ""
            )
        }
    }

    func publications(limit: Int = 5_000) async throws -> [OPDSPublication] {
        guard let rootURL = URL(string: source.baseURL) else { throw MediaSourceError.invalidURL }
        var queue: [(URL, Int)] = [(rootURL, 0)]
        var visited = Set<URL>()
        var publications: [OPDSPublication] = []
        var publicationIDs = Set<String>()

        while !queue.isEmpty && publications.count < limit && visited.count < 250 {
            let (url, depth) = queue.removeFirst()
            guard !visited.contains(url), depth <= 5 else { continue }
            visited.insert(url)
            let (data, response) = try await responseData(from: url)
            let parsed: OPDSParsedFeed
            if response.mimeType?.lowercased().contains("json") == true || data.first == 0x7B {
                parsed = try OPDSJSONParser.parse(data: data, baseURL: url)
            } else {
                parsed = try OPDSXMLFeedParser.parse(data: data, baseURL: url)
            }
            for publication in parsed.publications where !publicationIDs.contains(publication.id) {
                publicationIDs.insert(publication.id)
                publications.append(publication)
                if publications.count >= limit { break }
            }
            for navigationURL in parsed.navigationURLs where !visited.contains(navigationURL) {
                guard destination.allowsRequest(to: navigationURL) else {
                    MReaderLog.reader.notice("OPDS navigation target blocked host=\(RemoteDestinationPolicy.normalizedHost(of: navigationURL) ?? "", privacy: .public)")
                    continue
                }
                queue.append((navigationURL, depth + 1))
            }
        }
        return publications
    }

    func data(from url: URL) async throws -> Data {
        try await responseData(from: url).0
    }

    func contentRevision(for url: URL) async -> String? {
        guard destination.allowsRequest(to: url) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 20
        if shouldForwardAuthorization(to: url) {
            applyAuthorization(to: &request)
        }
        do {
            let (data, response) = try await BoundedHTTPResponseReader.data(
                for: request,
                maximumBytes: OPDSResponseLimits.feedBytes,
                redirectPolicy: { destination.decision(for: $0) }
            )
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  data.count <= OPDSResponseLimits.feedBytes else {
                return nil
            }
            return OPDSRemoteRevision.value(
                etag: httpResponse.value(forHTTPHeaderField: "ETag"),
                lastModified: httpResponse.value(forHTTPHeaderField: "Last-Modified"),
                contentDigest: httpResponse.value(forHTTPHeaderField: "Content-Digest")
                    ?? httpResponse.value(forHTTPHeaderField: "Digest"),
                contentLength: httpResponse.value(forHTTPHeaderField: "Content-Length")
            )
        } catch {
            return nil
        }
    }

    func download(_ url: URL, publicationID: String) async throws -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MReaderOPDSCache", isDirectory: true)
            .appendingPathComponent(source.id.uuidString, isDirectory: true)
        let safeID = RemoteImageLoader.safeFileName(publicationID)
        let legacyID = RemoteImageLoader.legacySafeFileName(publicationID)
        if let cached = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).first(where: {
            let identifier = $0.deletingPathExtension().lastPathComponent
            return identifier == safeID || identifier == legacyID
        }) {
            return cached
        }

        var request = URLRequest(url: url)
        if shouldForwardAuthorization(to: request.url!) {
            applyAuthorization(to: &request)
        }
        request.timeoutInterval = 120
        // 命中本地缓存直接返回；未命中才需要走网络，此时必须先过目标策略。
        try requireAllowedDestination(url)
        // 策略感知下载：302 在**跟随之前**逐跳判定，被禁止的内网地址不会被请求；
        // 允许的跨源跳转会显式剥离 Authorization（审查 #5）。
        let (temporaryURL, response) = try await PolicyCheckedDownloader.download(
            for: request,
            maximumBytes: OPDSResponseLimits.downloadBytes,
            redirectPolicy: { destination.decision(for: $0) }
        )
        try validate(response, maximumBytes: OPDSResponseLimits.downloadBytes)
        guard let values = try? temporaryURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize <= OPDSResponseLimits.downloadBytes else {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw MediaSourceError.serverError(413, "OPDS 响应超过安全上限")
        }
        let extensionValue = resolvedFileExtension(url: url, response: response)
        let cacheDestinationURL = root
            .appendingPathComponent(safeID)
            .appendingPathExtension(extensionValue)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: cacheDestinationURL)
        try FileManager.default.moveItem(at: temporaryURL, to: cacheDestinationURL)
        return cacheDestinationURL
    }

    private func resolvedFileExtension(url: URL, response: URLResponse) -> String {
        if !url.pathExtension.isEmpty {
            return url.pathExtension.lowercased()
        }
        if let suggested = response.suggestedFilename,
           !URL(fileURLWithPath: suggested).pathExtension.isEmpty {
            return URL(fileURLWithPath: suggested).pathExtension.lowercased()
        }
        switch response.mimeType?.lowercased() {
        case "application/epub+zip":
            return "epub"
        case "application/pdf":
            return "pdf"
        case "application/vnd.comicbook+zip", "application/x-cbz", "application/zip":
            return "cbz"
        default:
            return "bin"
        }
    }

    private func responseData(from url: URL) async throws -> (Data, HTTPURLResponse) {
        try requireAllowedDestination(url)
        var request = URLRequest(url: url)
        request.setValue("application/opds+json, application/atom+xml;profile=opds-catalog, application/atom+xml, application/json, */*", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 45
        if shouldForwardAuthorization(to: request.url!) {
            applyAuthorization(to: &request)
        }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await BoundedHTTPResponseReader.data(
                for: request,
                maximumBytes: OPDSResponseLimits.feedBytes,
                // 重定向逐跳判定，避免 feed 通过 302 把请求引到内网地址。
                redirectPolicy: { destination.decision(for: $0) }
            )
        } catch BoundedHTTPResponseError.tooLarge {
            throw MediaSourceError.serverError(413, "OPDS 响应超过安全上限")
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MediaSourceError.invalidResponse
        }
        try validate(httpResponse, maximumBytes: OPDSResponseLimits.feedBytes)
        guard data.count <= OPDSResponseLimits.feedBytes else {
            throw MediaSourceError.serverError(413, "OPDS 响应超过安全上限")
        }
        return (data, httpResponse)
    }

    /// Returns true only when `url` matches `source.baseURL` on scheme, host (case-insensitive),
    /// and effective port. Cross-origin URLs (e.g. third-party cover/acquisition links embedded in
    /// an OPDS feed) remain reachable but never receive the source's Basic/Bearer credentials.
    private func shouldForwardAuthorization(to url: URL) -> Bool {
        Self.shouldForwardAuthorization(sourceBaseURL: source.baseURL, to: url)
    }

    /// Static form of the same-origin authorization check (delegates to OPDSAuthorizationPolicy).
    nonisolated static func shouldForwardAuthorization(sourceBaseURL: String, to url: URL) -> Bool {
        OPDSAuthorizationPolicy.shouldForward(sourceBaseURL: sourceBaseURL, to: url)
    }

    private func applyAuthorization(to request: inout URLRequest) {
        guard !credential.isEmpty else { return }
        if let username = source.username, !username.isEmpty {
            let token = Data("\(username):\(credential)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        }
    }

    private func validate(_ response: URLResponse, maximumBytes: Int? = nil) throws {
        guard let response = response as? HTTPURLResponse else {
            throw MediaSourceError.invalidResponse
        }
        if let maximumBytes = maximumBytes,
           response.expectedContentLength > Int64(maximumBytes) {
            throw MediaSourceError.serverError(413, "OPDS 响应超过安全上限")
        }
        switch response.statusCode {
        case 200..<300:
            return
        case 401, 403:
            throw MediaSourceError.unauthorized
        case 404:
            throw MediaSourceError.notFound
        default:
            throw MediaSourceError.serverError(response.statusCode, nil)
        }
    }
}

nonisolated private struct OPDSParsedFeed: Sendable {
    var publications: [OPDSPublication]
    var navigationURLs: [URL]
}

nonisolated private enum OPDSJSONParser {
    static func parse(data: Data, baseURL: URL) throws -> OPDSParsedFeed {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MediaSourceError.decodingFailed
        }
        let rawPublications = (root["publications"] as? [[String: Any]]) ?? []
        let publications = rawPublications.compactMap { publication(from: $0, baseURL: baseURL) }
        var navigationURLs = linkURLs(from: root["navigation"], baseURL: baseURL)
        navigationURLs.append(contentsOf: linkURLs(from: root["links"], baseURL: baseURL, acceptedRels: ["next"]))
        return OPDSParsedFeed(publications: publications, navigationURLs: navigationURLs)
    }

    private static func publication(from object: [String: Any], baseURL: URL) -> OPDSPublication? {
        let metadata = object["metadata"] as? [String: Any]
        let title = (metadata?["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier = (metadata?["identifier"] as? String) ?? title
        let links = object["links"] as? [[String: Any]] ?? []
        guard let acquisition = links.first(where: { link in
            let rels = relationValues(link["rel"])
            let type = (link["type"] as? String)?.lowercased() ?? ""
            return rels.contains(where: { $0.contains("acquisition") }) || supportedAcquisitionType(type)
        }),
        let acquisitionURL = resolvedURL(acquisition["href"] as? String, baseURL: baseURL) else {
            return nil
        }
        let cover = links.first(where: { relationValues($0["rel"]).contains(where: { $0.contains("image") || $0.contains("thumbnail") }) })
            .flatMap { resolvedURL($0["href"] as? String, baseURL: baseURL) }
        return OPDSPublication(
            id: identifier ?? acquisitionURL.absoluteString,
            title: title?.isEmpty == false ? title! : acquisitionURL.deletingPathExtension().lastPathComponent,
            acquisitionURL: acquisitionURL,
            coverURL: cover,
            mediaType: acquisition["type"] as? String
        )
    }

    private static func linkURLs(from value: Any?, baseURL: URL, acceptedRels: Set<String>? = nil) -> [URL] {
        let links = value as? [[String: Any]] ?? []
        return links.compactMap { link in
            if let acceptedRels {
                let rels = Set(relationValues(link["rel"]))
                guard !rels.isDisjoint(with: acceptedRels) else { return nil }
            }
            return resolvedURL(link["href"] as? String, baseURL: baseURL)
        }
    }
}

nonisolated private final class OPDSXMLFeedParser: NSObject, XMLParserDelegate {
    private struct Entry {
        var id = ""
        var title = ""
        var links: [(rel: String, href: String, type: String)] = []
    }

    private let baseURL: URL
    private var currentEntry: Entry?
    private var currentElement = ""
    private var textBuffer = ""
    private var publications: [OPDSPublication] = []
    private var navigationURLs: [URL] = []

    private init(baseURL: URL) {
        self.baseURL = baseURL
    }

    static func parse(data: Data, baseURL: URL) throws -> OPDSParsedFeed {
        let delegate = OPDSXMLFeedParser(baseURL: baseURL)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw MediaSourceError.decodingFailed
        }
        return OPDSParsedFeed(publications: delegate.publications, navigationURLs: delegate.navigationURLs)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let element = elementName.lowercased()
        currentElement = element
        textBuffer = ""
        if element == "entry" {
            currentEntry = Entry()
        } else if element == "link",
                  let href = attributeDict["href"] {
            let rel = attributeDict["rel"] ?? ""
            let type = attributeDict["type"] ?? ""
            if currentEntry != nil {
                currentEntry?.links.append((rel, href, type))
            } else if rel.split(separator: " ").contains(where: { $0 == "next" }),
                      let url = resolvedURL(href, baseURL: baseURL) {
                navigationURLs.append(url)
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBuffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let element = elementName.lowercased()
        let value = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if element == "id" {
            currentEntry?.id = value
        } else if element == "title" {
            currentEntry?.title = value
        } else if element == "entry", let entry = currentEntry {
            consume(entry)
            currentEntry = nil
        }
        currentElement = ""
        textBuffer = ""
    }

    private func consume(_ entry: Entry) {
        if let acquisition = entry.links.first(where: {
            $0.rel.contains("acquisition") || supportedAcquisitionType($0.type.lowercased())
        }),
        let acquisitionURL = resolvedURL(acquisition.href, baseURL: baseURL) {
            let cover = entry.links.first(where: {
                $0.rel.contains("image") || $0.rel.contains("thumbnail")
            }).flatMap { resolvedURL($0.href, baseURL: baseURL) }
            publications.append(
                OPDSPublication(
                    id: entry.id.isEmpty ? acquisitionURL.absoluteString : entry.id,
                    title: entry.title.isEmpty ? acquisitionURL.deletingPathExtension().lastPathComponent : entry.title,
                    acquisitionURL: acquisitionURL,
                    coverURL: cover,
                    mediaType: acquisition.type
                )
            )
            return
        }
        for link in entry.links where link.rel.contains("subsection") || link.type.contains("atom+xml") || link.type.contains("opds") {
            if let url = resolvedURL(link.href, baseURL: baseURL) {
                navigationURLs.append(url)
            }
        }
    }
}

nonisolated private func resolvedURL(_ value: String?, baseURL: URL) -> URL? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
    return URL(string: value, relativeTo: baseURL)?.absoluteURL
}

nonisolated private func supportedAcquisitionType(_ type: String) -> Bool {
    let lowercased = type.lowercased()
    return lowercased.contains("epub")
        || lowercased.contains("pdf")
        || lowercased.contains("comicbook")
        || lowercased.contains("zip")
        || lowercased.contains("cbz")
}

nonisolated private func relationValues(_ value: Any?) -> [String] {
    if let string = value as? String {
        return string.split(separator: " ").map(String.init)
    }
    return value as? [String] ?? []
}
