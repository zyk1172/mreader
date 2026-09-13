import XCTest
@testable import mreader

/// 审查 #5：文件下载必须在**跟随重定向之前**判定目标策略。
/// 事后再看 `response.url` 只能删掉临时文件，不能阻止对被禁止地址的访问。
///
/// 这里用 `URLProtocol` 桩把「是否真的发出了请求」变得可断言。
final class RedirectPolicyDownloadTests: XCTestCase {

    private let trustedOrigin = URL(string: "https://library.example.com")!
    private let requestURL = URL(string: "https://library.example.com/file.cbz")!
    // Redirect tests must not depend on the runner's DNS configuration. The
    // production policy still performs a real lookup; this test only needs a
    // deterministic public answer for the synthetic CDN hostname.
    private static let publicResolver: RemoteDestinationPolicy.HostResolver = { _ in
        ["203.0.113.10"]
    }

    private var context: RemoteDestinationPolicy.Context {
        RemoteDestinationPolicy.Context(originURLs: [trustedOrigin])
    }

    override func setUp() {
        super.setUp()
        PolicyDownloadStubProtocol.reset()
    }

    override func tearDown() {
        PolicyDownloadStubProtocol.reset()
        super.tearDown()
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PolicyDownloadStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// 独立构造闭包，避免在 capture list 里引用实例属性。
    private func makePolicy(
        origins: [URL] = []
    ) -> @Sendable (URL) -> RemoteDestinationPolicy.Decision {
        let context = RemoteDestinationPolicy.Context(
            originURLs: origins.isEmpty ? [trustedOrigin] : origins,
            hostResolver: Self.publicResolver
        )
        return { url in context.decision(for: url) }
    }

    private func download(
        authorization: String? = "Bearer secret",
        maximumBytes: Int = 1_024 * 1_024
    ) async throws -> URL {
        var request = URLRequest(url: requestURL)
        if let authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        let (fileURL, _) = try await PolicyCheckedDownloader.download(
            for: request,
            using: makeSession(),
            maximumBytes: maximumBytes,
            redirectPolicy: makePolicy()
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: fileURL) }
        return fileURL
    }

    // MARK: - 被禁止的跳转

    func testRedirectToUnconfiguredPrivateHostIsRejectedBeforeRequesting() async throws {
        PolicyDownloadStubProtocol.redirectTarget = URL(string: "http://192.168.1.10/secret.cbz")!

        do {
            _ = try await download()
            XCTFail("跳转到未配置的内网地址必须被拒绝")
        } catch {
            XCTAssertTrue(
                error is RemoteDestinationPolicyError,
                "应抛出目标策略错误，实际为 \(error)"
            )
        }

        XCTAssertFalse(
            PolicyDownloadStubProtocol.requestedURLs.contains { $0.host == "192.168.1.10" },
            "302 之后根本不应该向被禁止的内网地址发出请求"
        )
    }

    func testRedirectToLoopbackIsRejectedBeforeRequesting() async throws {
        PolicyDownloadStubProtocol.redirectTarget = URL(string: "http://127.0.0.1:8080/secret.cbz")!

        do {
            _ = try await download()
            XCTFail("跳转到回环地址必须被拒绝")
        } catch {
            XCTAssertTrue(error is RemoteDestinationPolicyError)
        }

        XCTAssertFalse(
            PolicyDownloadStubProtocol.requestedURLs.contains { $0.host == "127.0.0.1" },
            "回环地址不应被请求"
        )
    }

    // MARK: - 允许的跨源跳转必须去掉凭据

    func testRedirectToPublicCrossOriginIsFollowedWithoutCredentials() async throws {
        PolicyDownloadStubProtocol.redirectTarget = URL(string: "https://cdn.example.org/file.cbz")!

        let fileURL = try await download()
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        let redirected = PolicyDownloadStubProtocol.requests.first { $0.url?.host == "cdn.example.org" }
        let redirectedRequest = try XCTUnwrap(redirected, "公网跨源跳转应当被允许")
        XCTAssertNil(
            redirectedRequest.value(forHTTPHeaderField: "Authorization"),
            "跨源跳转必须显式剥离 Authorization"
        )
    }

    func testRedirectWithinTrustedOriginKeepsCredentials() async throws {
        PolicyDownloadStubProtocol.redirectTarget = URL(string: "https://library.example.com/other.cbz")!

        _ = try await download()

        let redirected = PolicyDownloadStubProtocol.requests.first { $0.url?.path == "/other.cbz" }
        let redirectedRequest = try XCTUnwrap(redirected)
        XCTAssertEqual(
            redirectedRequest.value(forHTTPHeaderField: "Authorization"),
            "Bearer secret",
            "同源跳转应当保留凭据"
        )
    }

    // MARK: - 单一来源允许的内网跳转仍然放行

    func testConfiguredLanOriginRedirectIsAllowed() async throws {
        let lanOrigin = URL(string: "http://192.168.1.10:8080")!
        PolicyDownloadStubProtocol.redirectTarget = lanOrigin.appendingPathComponent("file.cbz")
        let lanContext = RemoteDestinationPolicy.Context(originURLs: [trustedOrigin, lanOrigin])

        var request = URLRequest(url: requestURL)
        request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        let (fileURL, _) = try await PolicyCheckedDownloader.download(
            for: request,
            using: makeSession(),
            maximumBytes: 1_024 * 1_024,
            redirectPolicy: { lanContext.decision(for: $0) }
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: fileURL) }

        let redirected = PolicyDownloadStubProtocol.requests.first { $0.url?.host == "192.168.1.10" }
        XCTAssertNotNil(redirected, "用户自己配置的 LAN 地址必须可用")
        XCTAssertEqual(redirected?.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
    }

    // MARK: - 大小上限

    func testOversizedDownloadIsRejected() async throws {
        PolicyDownloadStubProtocol.payloadBytes = 4_096

        do {
            _ = try await download(maximumBytes: 1_024)
            XCTFail("超限下载必须失败")
        } catch {
            XCTAssertTrue(error is BoundedHTTPResponseError)
        }
    }
}

// MARK: - URLProtocol 桩

/// 记录所有真正发出的请求；第一个请求返回 302，其余返回固定大小的响应体。
final class PolicyDownloadStubProtocol: URLProtocol {
    nonisolated(unsafe) static var redirectTarget: URL?
    nonisolated(unsafe) static var payloadBytes = 4
    nonisolated(unsafe) static var requestedURLs: [URL] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []

    static func reset() {
        redirectTarget = nil
        payloadBytes = 4
        requestedURLs = []
        requests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.requestedURLs.append(url)
        Self.requests.append(request)

        if let target = Self.redirectTarget, url != target {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": target.absoluteString]
            )
            var redirected = URLRequest(url: target)
            // 模拟 URLSession 的默认行为：把原请求头带过去。
            // 目标策略必须显式剥离它，而不是依赖隐式行为。
            if let authorization = request.value(forHTTPHeaderField: "Authorization") {
                redirected.setValue(authorization, forHTTPHeaderField: "Authorization")
            }
            if let response {
                client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            }
            return
        }

        let payload = Data(repeating: 0x2A, count: Self.payloadBytes)
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": String(payload.count)]
        )
        if let response {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
