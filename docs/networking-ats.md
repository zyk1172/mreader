# mReader 网络与 ATS 边界

mReader 的远程源是用户主动配置的 Komga / OPDS 地址，使用场景包含家庭 NAS、192.168.x.x、IPv6 局域网地址、局域网 hostname 和 .local 主机。公网地址仍应优先使用 HTTPS；项目不会因为 ATS 审查而把所有 HTTP 地址判定为非法，也不会把用户配置的局域网源改写成公网地址。

iOS Target 使用生成的 Info.plist 配置：

    NSAppTransportSecurity
    └── NSAllowsLocalNetworking = YES

这是局域网范围的窄例外，用于保留显式配置的 IP、.local 和未限定主机名的家庭服务器 HTTP 能力。项目没有设置 NSAllowsArbitraryLoads = YES，因此公网 HTTP 仍然受 ATS 约束。自签名 HTTPS 也不会因为这项配置而绕过系统 TLS 证书校验；需要自签名证书时，后续应单独设计用户可理解、范围受限的信任方案。

URL 是否属于允许访问的远端目标仍由现有的远端目标策略和各 Provider 的来源校验负责。本次只收口 Target 的 ATS 声明，没有改变远端目标策略、重定向判定或凭据发送边界。
