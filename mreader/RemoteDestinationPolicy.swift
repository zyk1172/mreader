import Foundation

/// 远端目标访问策略（审查 #11）。
///
/// 与凭据策略分层，两者职责不重叠：
/// - `OPDSAuthorizationPolicy`（Credential Policy）：**能不能带凭据**。
/// - `RemoteDestinationPolicy`（Destination Policy）：**能不能访问这个地址**。
///
/// mReader 本身就要连 NAS 和内网媒体源，因此**不能**一刀切封禁私网地址。
/// 判定顺序：
/// 1. 用户为该 source 显式配置的地址（baseURL / lanURL）→ 可信，可用凭据；
/// 2. same-origin 或 per-source 跨源白名单 → 可信，可用凭据；
/// 3. 其它跨源公网地址 → 可达，但绝不携带 source 凭据（如 CDN 封面）；
/// 4. **非用户配置目标**的 loopback / link-local / 私网 / CGNAT 地址 → 拒绝，
///    避免恶意 feed 把客户端当成内网探测跳板（SSRF）。
///
/// 重定向必须逐跳重新判定，见 `Context.allowsRequest(to:)`。
nonisolated enum RemoteDestinationPolicy {

    enum Decision: Equatable, Sendable {
        /// 允许请求，且允许携带该 source 的凭据。
        case trustedOrigin
        /// 允许请求，但绝不携带 source 凭据（普通公网跨源）。
        case crossOriginPublic
        /// 拒绝请求。
        case denied(Denial)

        var isAllowed: Bool {
            if case .denied = self { return false }
            return true
        }

        var mayUseCredentials: Bool {
            self == .trustedOrigin
        }
    }

    enum Denial: String, Equatable, Sendable {
        /// 只允许 http / https。
        case unsupportedScheme
        case invalidURL
        /// 非用户配置目标的 loopback / link-local / 私网地址。
        case privateNetwork
    }

    /// 一次远端请求的判定上下文：该 source 的配置地址与跨源白名单。
    struct Context: Sendable {
        /// 用户显式配置的地址（baseURL、lanURL 等）。
        let originURLs: [URL]
        /// 该 source 允许的额外跨源主机（小写）。
        let allowlistHosts: Set<String>

        init(originURLs: [URL], allowlistHosts: Set<String> = []) {
            self.originURLs = originURLs
            self.allowlistHosts = Set(allowlistHosts.map { $0.lowercased() })
        }

        /// 从媒体源构造上下文：baseURL + lanURL 都是用户显式配置的可信目标。
        init(source: MediaSource, allowlistHosts: Set<String> = []) {
            var origins: [URL] = []
            if let baseURL = URL(string: source.baseURL) {
                origins.append(baseURL)
            }
            if let lanURL = source.lanURL, !lanURL.isEmpty, let url = URL(string: lanURL) {
                origins.append(url)
            }
            self.init(originURLs: origins, allowlistHosts: allowlistHosts)
        }

        func decision(for url: URL) -> Decision {
            RemoteDestinationPolicy.decision(
                for: url,
                originURLs: originURLs,
                allowlistHosts: allowlistHosts
            )
        }

        /// 单跳判定；重定向的每一跳都要各自调用一次。
        func allowsRequest(to url: URL) -> Bool {
            decision(for: url).isAllowed
        }
    }

    static func decision(
        for url: URL,
        originURLs: [URL],
        allowlistHosts: Set<String> = []
    ) -> Decision {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .denied(.unsupportedScheme)
        }
        guard let host = normalizedHost(of: url), !host.isEmpty else {
            return .denied(.invalidURL)
        }
        if originURLs.contains(where: { matchesOrigin($0, url) }) {
            return .trustedOrigin
        }
        if allowlistHosts.contains(host) {
            return .trustedOrigin
        }
        if isPrivateNetworkHost(host) {
            return .denied(.privateNetwork)
        }
        return .crossOriginPublic
    }

    /// scheme + host + effective port 完全相同才算同源。
    static func matchesOrigin(_ origin: URL, _ url: URL) -> Bool {
        guard origin.scheme?.lowercased() == url.scheme?.lowercased() else { return false }
        guard let lhs = normalizedHost(of: origin), let rhs = normalizedHost(of: url), lhs == rhs else {
            return false
        }
        return effectivePort(of: origin) == effectivePort(of: url)
    }

    static func normalizedHost(of url: URL) -> String? {
        var host = (url.host ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        // IPv6 可能带 zone id，例如 fe80::1%en0。
        if let separator = host.firstIndex(of: "%") {
            host = String(host[host.startIndex..<separator])
        }
        return host.isEmpty ? nil : host
    }

    static func effectivePort(of url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    /// loopback / link-local / 私网 / CGNAT / mDNS 本地域名。
    static func isPrivateNetworkHost(_ rawHost: String) -> Bool {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        guard !host.isEmpty else { return true }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") {
            return true
        }
        if host.contains(":") {
            return isPrivateIPv6Host(host)
        }
        return isPrivateIPv4Host(host)
    }

    private static func isPrivateIPv4Host(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var octets: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 3,
                  part.allSatisfy({ $0.isNumber }),
                  let value = Int(part), (0...255).contains(value) else {
                return false
            }
            octets.append(value)
        }
        switch (octets[0], octets[1]) {
        case (0, _): return true              // 0.0.0.0/8 “this network”
        case (10, _): return true             // RFC1918
        case (100, 64...127): return true      // CGNAT 100.64/10
        case (127, _): return true             // loopback
        case (169, 254): return true           // link-local
        case (172, 16...31): return true       // RFC1918
        case (192, 168): return true           // RFC1918
        default: return false
        }
    }

    private static func isPrivateIPv6Host(_ host: String) -> Bool {
        if host == "::" || host == "::1" { return true }
        let head = host.split(separator: ":", omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? ""
        guard head.count >= 3, let prefix = Int(head, radix: 16) else { return false }
        if prefix & 0xFFC0 == 0xFE80 { return true }   // fe80::/10 link-local
        if prefix & 0xFFC0 == 0xFEC0 { return true }   // fec0::/10 site-local（已废弃）
        if prefix & 0xFE00 == 0xFC00 { return true }   // fc00::/7 unique local
        if prefix & 0xFF00 == 0xFF00 { return true }   // ff00::/8 multicast
        return false
    }
}

nonisolated enum RemoteDestinationPolicyError: LocalizedError, Equatable, Sendable {
    case denied(RemoteDestinationPolicy.Denial, host: String)

    var errorDescription: String? {
        switch self {
        case .denied(let denial, let host):
            switch denial {
            case .unsupportedScheme:
                return "只允许 http / https 的远端地址：\(host)"
            case .invalidURL:
                return "远端地址无效：\(host)"
            case .privateNetwork:
                return "已阻止访问未配置的内网 / 回环地址：\(host)"
            }
        }
    }
}
