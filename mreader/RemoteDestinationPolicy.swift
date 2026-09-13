import Foundation
import Darwin

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
/// 3. 其它跨源公网地址 → 必须先解析 DNS；只有全部解析结果仍为公网地址才可达，且绝不携带 source 凭据；
/// 4. **非用户配置目标**的 loopback / link-local / 私网 / CGNAT 地址（包括 DNS 解析结果）→ 拒绝，
///    避免恶意 feed 把客户端当成内网探测跳板（SSRF / DNS rebinding）。
///
/// `Context.decision(for:)` 是生产入口：每次初始请求和每一跳重定向都必须重新判定。
nonisolated enum RemoteDestinationPolicy {

    typealias HostResolver = @Sendable (String) throws -> [String]

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

        /// 被拒绝时的原因，便于构造错误（允许时返回 nil）。
        var denial: Denial? {
            if case .denied(let denial) = self { return denial }
            return nil
        }
    }

    enum Denial: String, Equatable, Sendable {
        /// 只允许 http / https。
        case unsupportedScheme
        case invalidURL
        /// 非用户配置目标的 loopback / link-local / 私网地址。
        case privateNetwork
        /// 非可信跨源主机必须成功解析后才能访问；解析失败时 fail closed。
        case hostResolutionFailed
    }

    /// 一次远端请求的判定上下文：该 source 的配置地址、跨源白名单与 DNS 解析器。
    struct Context: Sendable {
        /// 用户显式配置的地址（baseURL、lanURL 等）。
        let originURLs: [URL]
        /// 该 source 允许的额外跨源主机（小写）。
        let allowlistHosts: Set<String>
        private let hostResolver: HostResolver

        init(
            originURLs: [URL],
            allowlistHosts: Set<String> = [],
            hostResolver: @escaping HostResolver = { try RemoteHostResolver.shared.resolve($0) }
        ) {
            self.originURLs = originURLs
            self.allowlistHosts = Set(allowlistHosts.map { $0.lowercased() })
            self.hostResolver = hostResolver
        }

        /// 从媒体源构造上下文：baseURL + lanURL 都是用户显式配置的可信目标。
        init(
            source: MediaSource,
            allowlistHosts: Set<String> = [],
            hostResolver: @escaping HostResolver = { try RemoteHostResolver.shared.resolve($0) }
        ) {
            var origins: [URL] = []
            if let baseURL = URL(string: source.baseURL) {
                origins.append(baseURL)
            }
            if let lanURL = source.lanURL, !lanURL.isEmpty, let url = URL(string: lanURL) {
                origins.append(url)
            }
            self.init(
                originURLs: origins,
                allowlistHosts: allowlistHosts,
                hostResolver: hostResolver
            )
        }

        /// 生产请求的完整判定：非可信跨源 hostname 必须先解析 DNS，
        /// 任意一个解析结果落入私网 / 回环 / link-local / CGNAT 都拒绝。
        func decision(for url: URL) -> Decision {
            RemoteDestinationPolicy.resolvedDecision(
                for: url,
                originURLs: originURLs,
                allowlistHosts: allowlistHosts,
                hostResolver: hostResolver
            )
        }

        /// 仅按 URL / origin / 字面 IP 判断，不触发 DNS。只供诊断和纯逻辑测试使用。
        func urlDecision(for url: URL) -> Decision {
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

    /// 第一层：只根据 URL 本身判断。hostname 看起来是公网时暂时返回 `.crossOriginPublic`，
    /// 生产网络路径还必须继续调用 `resolvedDecision`。
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

    /// 第二层：对非可信跨源 hostname 解析 DNS 后再判定。
    ///
    /// 这里采用“任一地址私网即拒绝”而不是“只要有一个公网就允许”，避免攻击者返回
    /// public + private 混合记录后让系统连接选择落到内网地址。解析失败也 fail closed；
    /// 用户显式配置的 NAS/LAN origin 在第一层已是 `.trustedOrigin`，不会经过 DNS 阻断。
    static func resolvedDecision(
        for url: URL,
        originURLs: [URL],
        allowlistHosts: Set<String> = [],
        hostResolver: HostResolver = { try RemoteHostResolver.shared.resolve($0) }
    ) -> Decision {
        let initial = decision(
            for: url,
            originURLs: originURLs,
            allowlistHosts: allowlistHosts
        )
        guard initial == .crossOriginPublic else { return initial }
        guard let host = normalizedHost(of: url), !host.isEmpty else {
            return .denied(.invalidURL)
        }

        // 公网字面 IP 已经由第一层完成地址范围判断，无需再走 DNS。
        if isIPAddressLiteral(host) {
            return .crossOriginPublic
        }

        let resolvedAddresses: [String]
        do {
            resolvedAddresses = try hostResolver(host)
        } catch {
            return .denied(.hostResolutionFailed)
        }
        guard !resolvedAddresses.isEmpty else {
            return .denied(.hostResolutionFailed)
        }
        if resolvedAddresses.contains(where: isPrivateNetworkHost) {
            return .denied(.privateNetwork)
        }
        return .crossOriginPublic
    }

    /// 跨源跳转必须**显式**剥离凭据，不能依赖 URLSession 的隐式行为（审查 #5）。
    static func sanitizedRedirectRequest(
        _ request: URLRequest,
        for decision: Decision
    ) -> URLRequest {
        guard !decision.mayUseCredentials else { return request }
        var sanitized = request
        for header in ["Authorization", "Proxy-Authorization", "Cookie", "Cookie2"] {
            sanitized.setValue(nil, forHTTPHeaderField: header)
        }
        return sanitized
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
        if let separator = host.firstIndex(of: "%") {
            host = String(host[host.startIndex..<separator])
        }
        guard !host.isEmpty else { return true }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") {
            return true
        }
        if host.hasPrefix("::ffff:") {
            return isPrivateIPv4Host(String(host.dropFirst("::ffff:".count)))
        }
        if host.contains(":") {
            return isPrivateIPv6Host(host)
        }
        return isPrivateIPv4Host(host)
    }

    static func isIPAddressLiteral(_ host: String) -> Bool {
        var ipv4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            return true
        }
        var ipv6 = in6_addr()
        return host.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1
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

/// 系统 DNS 解析器。只服务于“未配置的跨源 hostname”；用户显式配置的 NAS/LAN 不会走这里。
/// 使用短 TTL 缓存避免一页多个 CDN 资源重复 getaddrinfo，同时仍会周期性重新校验解析结果。
nonisolated private final class RemoteHostResolver: @unchecked Sendable {
    static let shared = RemoteHostResolver()

    private struct CacheEntry {
        let addresses: [String]
        let expiresAt: Date
    }

    private enum ResolutionFailure: Error {
        case getaddrinfo(Int32)
        case noAddresses
    }

    private let lock = NSLock()
    private var cache: [String: CacheEntry] = [:]
    private let cacheTTL: TimeInterval = 60

    func resolve(_ rawHost: String) throws -> [String] {
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty else { throw ResolutionFailure.noAddresses }

        let now = Date()
        lock.lock()
        if let cached = cache[host], cached.expiresAt > now {
            lock.unlock()
            return cached.addresses
        }
        cache[host] = nil
        lock.unlock()

        let addresses = try Self.resolveUncached(host)
        guard !addresses.isEmpty else { throw ResolutionFailure.noAddresses }

        lock.lock()
        cache[host] = CacheEntry(
            addresses: addresses,
            expiresAt: now.addingTimeInterval(cacheTTL)
        )
        lock.unlock()
        return addresses
    }

    private static func resolveUncached(_ host: String) throws -> [String] {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: 0,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let first = result else {
            throw ResolutionFailure.getaddrinfo(status)
        }
        defer { freeaddrinfo(first) }

        var addresses = Set<String>()
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let current = cursor {
            let info = current.pointee
            if let socketAddress = info.ai_addr {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let nameStatus = getnameinfo(
                    socketAddress,
                    info.ai_addrlen,
                    &buffer,
                    socklen_t(buffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                if nameStatus == 0 {
                    addresses.insert(String(cString: buffer))
                }
            }
            cursor = info.ai_next
        }
        return addresses.sorted()
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
            case .hostResolutionFailed:
                return "无法安全解析未配置的跨源地址：\(host)"
            }
        }
    }
}
