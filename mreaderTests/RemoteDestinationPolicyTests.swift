import Foundation
import Testing
@testable import mreader

/// 审查 #11：OPDS feed 可以给出任意绝对 URL，凭据策略只保证"不带凭据"，
/// 因此还需要一层目标访问策略来拦住"不自动跟随未配置的内网地址"。
struct RemoteDestinationPolicyTests {

    private func source(baseURL: String, lanURL: String? = nil) -> MediaSource {
        MediaSource(
            name: "NAS",
            type: .opds,
            baseURL: baseURL,
            lanURL: lanURL,
            isEnabled: true
        )
    }

    // MARK: - 可信目标

    @Test
    func configuredSourceOriginIsTrusted() {
        let context = RemoteDestinationPolicy.Context(
            source: source(baseURL: "https://library.example.com/opds")
        )

        #expect(context.decision(for: URL(string: "https://library.example.com/opds/books")!) == .trustedOrigin)
        #expect(context.decision(for: URL(string: "https://library.example.com:443/other")!) == .trustedOrigin)
        // 端口不同即不同源。
        #expect(context.decision(for: URL(string: "https://library.example.com:8443/other")!) == .crossOriginPublic)
        // scheme 不同即不同源。
        #expect(context.decision(for: URL(string: "http://library.example.com/other")!) != .trustedOrigin)
    }

    @Test
    func configuredLanURLIsTrustedEvenOnPrivateNetwork() {
        let context = RemoteDestinationPolicy.Context(
            source: source(
                baseURL: "https://library.example.com/opds",
                lanURL: "http://192.168.1.10:8080/opds"
            )
        )

        #expect(context.decision(for: URL(string: "http://192.168.1.10:8080/opds/books")!) == .trustedOrigin)
        #expect(context.allowsRequest(to: URL(string: "http://192.168.1.10:8080/cover/1.jpg")!))
    }

    @Test
    func allowlistedCrossOriginHostIsTrusted() {
        let context = RemoteDestinationPolicy.Context(
            source: source(baseURL: "https://library.example.com/opds"),
            allowlistHosts: ["covers.example.net"]
        )

        #expect(context.decision(for: URL(string: "https://covers.example.net/a.jpg")!) == .trustedOrigin)
    }

    @Test
    func publicCrossOriginRemainsReachableWithoutCredentials() {
        let context = RemoteDestinationPolicy.Context(
            source: source(baseURL: "https://library.example.com/opds")
        )

        let decision = context.decision(for: URL(string: "https://cdn.example.org/cover.jpg")!)
        #expect(decision == .crossOriginPublic)
        #expect(decision.isAllowed)
        #expect(!decision.mayUseCredentials)
    }

    // MARK: - 必须拒绝

    @Test
    func unconfiguredPrivateNetworkTargetsAreDenied() {
        let context = RemoteDestinationPolicy.Context(
            source: source(baseURL: "https://library.example.com/opds")
        )

        let deniedHosts = [
            "http://127.0.0.1:8080/opds",
            "http://localhost/opds",
            "http://nas.local/opds",
            "http://10.0.0.5/opds",
            "http://172.16.9.9/opds",
            "http://172.31.255.254/opds",
            "http://192.168.1.1/opds",
            "http://169.254.169.254/latest/meta-data",
            "http://100.64.0.1/opds",
            "http://0.0.0.0/opds"
        ]

        for rawURL in deniedHosts {
            let url = URL(string: rawURL)!
            let decision = context.decision(for: url)
            #expect(decision == .denied(.privateNetwork), "应拒绝 \(rawURL)，实际 \(decision)")
            #expect(!context.allowsRequest(to: url))
        }
    }

    @Test
    func ipv6LoopbackAndLinkLocalAreDenied() {
        let context = RemoteDestinationPolicy.Context(
            source: source(baseURL: "https://library.example.com/opds")
        )

        for rawURL in ["http://[::1]/opds", "http://[fe80::1]/opds", "http://[fc00::1]/opds", "http://[fd12:3456::1]/opds"] {
            guard let url = URL(string: rawURL) else { continue }
            #expect(context.decision(for: url) == .denied(.privateNetwork), "应拒绝 \(rawURL)")
        }

        #expect(RemoteDestinationPolicy.isPrivateNetworkHost("::1"))
        #expect(RemoteDestinationPolicy.isPrivateNetworkHost("fe80::abcd"))
        #expect(RemoteDestinationPolicy.isPrivateNetworkHost("fd00::1"))
        #expect(!RemoteDestinationPolicy.isPrivateNetworkHost("2001:db8::1"))
        #expect(!RemoteDestinationPolicy.isPrivateNetworkHost("2606:4700::1111"))
    }

    @Test
    func publicAddressesAreNotTreatedAsPrivate() {
        #expect(!RemoteDestinationPolicy.isPrivateNetworkHost("8.8.8.8"))
        #expect(!RemoteDestinationPolicy.isPrivateNetworkHost("172.32.0.1"))
        #expect(!RemoteDestinationPolicy.isPrivateNetworkHost("172.15.0.1"))
        #expect(!RemoteDestinationPolicy.isPrivateNetworkHost("example.com"))
        #expect(!RemoteDestinationPolicy.isPrivateNetworkHost("192.169.0.1"))
    }

    @Test
    func nonHTTPSchemeIsDenied() {
        let context = RemoteDestinationPolicy.Context(
            source: source(baseURL: "https://library.example.com/opds")
        )

        if let fileURL = URL(string: "file:///etc/passwd") {
            #expect(context.decision(for: fileURL) == .denied(.unsupportedScheme))
        }
    }

    // MARK: - 重定向逐跳判定

    @Test
    func redirectHopToUnconfiguredPrivateHostIsDenied() {
        let context = RemoteDestinationPolicy.Context(
            source: source(baseURL: "https://library.example.com/opds")
        )

        // 首次请求命中可信目标，但 302 指向未配置的内网地址时必须拒绝。
        #expect(context.allowsRequest(to: URL(string: "https://library.example.com/opds/a")!))
        #expect(!context.allowsRequest(to: URL(string: "http://169.254.169.254/latest/meta-data")!))
    }

    @Test
    func denialErrorExposesDeniedHost() {
        let error = RemoteDestinationPolicyError.denied(.privateNetwork, host: "192.168.1.1")
        #expect(error.errorDescription?.contains("192.168.1.1") == true)
    }

    // MARK: - 跨源跳转的凭据剥离

    @Test
    func sanitizedRedirectRequestStripsCredentialsForCrossOrigin() {
        var request = URLRequest(url: URL(string: "https://cdn.example.org/a.jpg")!)
        request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        request.setValue("session=1", forHTTPHeaderField: "Cookie")
        request.setValue("Basic abc", forHTTPHeaderField: "Proxy-Authorization")

        let sanitized = RemoteDestinationPolicy.sanitizedRedirectRequest(request, for: .crossOriginPublic)
        #expect(sanitized.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(sanitized.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(sanitized.value(forHTTPHeaderField: "Proxy-Authorization") == nil)
    }

    @Test
    func sanitizedRedirectRequestKeepsCredentialsForTrustedOrigin() {
        var request = URLRequest(url: URL(string: "https://library.example.com/a.jpg")!)
        request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")

        let trusted = RemoteDestinationPolicy.sanitizedRedirectRequest(request, for: .trustedOrigin)
        #expect(trusted.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    }
}
