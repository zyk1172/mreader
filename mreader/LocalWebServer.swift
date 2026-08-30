import Foundation
import Network
import Combine

private enum HTTPRequestReceiveError: Error {
    case headerTooLarge
}

private enum LocalWebServerFileError: LocalizedError {
    case invalidRange
    case incompleteCopy

    var errorDescription: String? {
        switch self {
        case .invalidRange:
            return "上传文件范围无效"
        case .incompleteCopy:
            return "上传文件复制不完整"
        }
    }
}

/// 接收状态机：在 NWConnection 的全局队列回调里按连接串行使用，
/// 关键状态转换（markFinished / cleanup / 空闲超时）用 NSLock 保护，
/// 因此声明为 nonisolated 而不是默认的 MainActor 隔离；Sendable 由
/// 内部锁纪律保证（@unchecked）。
nonisolated final class HTTPRequestReceiveState: @unchecked Sendable {
    private static let maxHeaderBytes = 64 * 1024
    private var headerBuffer = Data()
    private var bodyHandle: FileHandle?
    private let lock = NSLock()
    private var idleWorkItem: DispatchWorkItem?
    private var didFinish = false
    private(set) var header: String?
    private(set) var method: String?
    private(set) var contentLength = 0
    private(set) var hasContentLengthHeader = false
    private(set) var receivedBodyBytes = 0
    private(set) var bodyFileURL: URL?

    var isComplete: Bool {
        guard header != nil else { return false }
        guard method == "POST" else { return true }
        guard hasContentLengthHeader, contentLength >= 0 else { return true }
        return receivedBodyBytes == contentLength
    }

    func append(_ data: Data) throws {
        if header == nil {
            headerBuffer.append(data)
            if headerBuffer.count > Self.maxHeaderBytes {
                throw HTTPRequestReceiveError.headerTooLarge
            }
            guard let headerEnd = headerBuffer.range(of: Data("\r\n\r\n".utf8)) else { return }
            let headerData = headerBuffer[..<headerEnd.lowerBound]
            header = String(data: headerData, encoding: .utf8) ?? ""
            method = HTTPRequestReceiveState.method(from: header ?? "")
            hasContentLengthHeader = HTTPRequestReceiveState.hasContentLengthHeader(in: header ?? "")
            // Only the upload endpoint accepts a request body. GET/HEAD and other
            // non-POST requests are complete as soon as their headers arrive;
            // a POST without Content-Length is rejected by respond() instead of
            // waiting for the client to close a keep-alive connection.
            contentLength = method == "POST"
                ? HTTPRequestReceiveState.contentLength(from: header ?? "") ?? -1
                : 0
            if contentLength > 0 {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("MReaderWebUpload-\(UUID().uuidString).body")
                FileManager.default.createFile(atPath: url.path, contents: nil)
                bodyFileURL = url
                bodyHandle = try FileHandle(forWritingTo: url)
                let bodyStart = headerEnd.upperBound
                if bodyStart < headerBuffer.count {
                    try appendBody(headerBuffer[bodyStart...])
                }
            }
            headerBuffer.removeAll(keepingCapacity: false)
        } else {
            try appendBody(data[...])
        }
    }

    func cleanup() {
        lock.lock()
        idleWorkItem?.cancel()
        idleWorkItem = nil
        lock.unlock()
        try? bodyHandle?.close()
        bodyHandle = nil
        if let bodyFileURL {
            try? FileManager.default.removeItem(at: bodyFileURL)
        }
    }

    func markFinished() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didFinish else { return false }
        didFinish = true
        idleWorkItem?.cancel()
        idleWorkItem = nil
        return true
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didFinish
    }

    func armIdleTimeout(after interval: TimeInterval, handler: @escaping () -> Void) {
        lock.lock()
        idleWorkItem?.cancel()
        guard !didFinish else {
            lock.unlock()
            return
        }
        let workItem = DispatchWorkItem(block: handler)
        idleWorkItem = workItem
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + interval, execute: workItem)
    }

    private func appendBody(_ body: Data.SubSequence) throws {
        guard !body.isEmpty else { return }
        let remaining = max(contentLength - receivedBodyBytes, 0)
        guard remaining > 0 else { return }
        let chunkCount = min(body.count, remaining)
        let chunk = body.prefix(chunkCount)
        if bodyHandle == nil {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("MReaderWebUpload-\(UUID().uuidString).body")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            bodyFileURL = url
            bodyHandle = try FileHandle(forWritingTo: url)
        }
        try bodyHandle?.write(contentsOf: Data(chunk))
        receivedBodyBytes += chunk.count
    }

    private static func contentLength(from header: String) -> Int? {
        header
            .components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "") }
    }

    private static func method(from header: String) -> String? {
        guard let firstLine = header.components(separatedBy: "\r\n").first else { return nil }
        return firstLine.split(separator: " ", omittingEmptySubsequences: true).first.map(String.init)?.uppercased()
    }

    private static func hasContentLengthHeader(in header: String) -> Bool {
        header.components(separatedBy: "\r\n").contains {
            $0.lowercased().hasPrefix("content-length:")
        }
    }
}

/// 局域网上传服务的 SwiftUI 门面：持有 @Published 状态（必须在主线程更新）
/// 和 NWListener 生命周期。连接处理委托给 `WebUploadServerCore`。
final class LocalWebServer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var address = ""
    @Published var errorMessage: String?

    private var listener: NWListener?
    private var serverCore: WebUploadServerCore?
    private let port: UInt16 = 8080

    nonisolated static func clearStaleBodyFiles() {
        let tempRoot = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: tempRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
        for file in files where file.lastPathComponent.hasPrefix("MReaderWebUpload-") && file.pathExtension == "body" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    func start(onUpload: @escaping (URL) -> Void) {
        stop()
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        Self.clearStaleBodyFiles()

        do {
            let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
            let core = WebUploadServerCore(token: token, onUpload: onUpload)
            listener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.isRunning = true
                        self.address = "http://\(Self.localIPAddress() ?? "127.0.0.1"):\(self.port)/\(token)/"
                        self.errorMessage = nil
                    case .failed(let error):
                        self.isRunning = false
                        self.errorMessage = "网页服务启动失败: \(error.localizedDescription)"
                    case .cancelled:
                        self.isRunning = false
                        self.address = ""
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { connection in
                core.handle(connection)
            }
            self.listener = listener
            self.serverCore = core
            listener.start(queue: .global(qos: .userInitiated))
        } catch {
            errorMessage = "网页服务启动失败: \(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        serverCore = nil
        isRunning = false
        address = ""
    }

    private static func localIPAddress() -> String? {
        var address: String?
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }

        for pointer in sequence(first: firstInterface, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            guard addrFamily == UInt8(AF_INET) else { continue }

            let name = String(cString: interface.ifa_name)
            guard name == "en0" || name == "en1" else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
            address = String(cString: hostname)
            break
        }
        return address
    }
}

/// 上传服务的连接处理核心：所有回调都运行在 NWListener / NWConnection 的
/// 全局队列上。连接计数由 NSLock 保护；token / onUpload 在服务启动后写后
/// 只读，因此以 @unchecked Sendable + nonisolated 声明其真实并发语义。
nonisolated final class WebUploadServerCore: @unchecked Sendable {
    private let token: String
    private let onUpload: (URL) -> Void
    private let maxUploadSize = 300 * 1024 * 1024
    private let maximumConnections = 4
    private let idleTimeout: TimeInterval = 30
    private let connectionLock = NSLock()
    private var activeConnectionCount = 0
    private let allowedUploadExtensions: Set<String> = ["zip", "cbz", "epub", "pdf", "jpg", "jpeg", "png", "webp", "gif", "heic", "heif"]

    init(token: String, onUpload: @escaping (URL) -> Void) {
        self.token = token
        self.onUpload = onUpload
    }

    func handle(_ connection: NWConnection) {
        guard acquireConnection() else {
            connection.start(queue: .global(qos: .utility))
            sendResponse(
                httpResponse(status: "503 Service Unavailable", contentType: "text/plain; charset=utf-8", body: "连接数已达到上限"),
                on: connection
            )
            return
        }
        connection.start(queue: .global(qos: .userInitiated))
        let state = HTTPRequestReceiveState()
        armIdleTimeout(for: connection, state: state)
        receive(on: connection, state: state)
    }

    private func receive(on connection: NWConnection, state: HTTPRequestReceiveState) {
        guard !state.isFinished else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard !state.isFinished else { return }
            if let data, !data.isEmpty {
                do {
                    try state.append(data)
                } catch let receiveError {
                    let response: Data
                    if case HTTPRequestReceiveError.headerTooLarge = receiveError {
                        response = self.httpResponse(status: "431 Request Header Fields Too Large", contentType: "text/plain; charset=utf-8", body: "请求头过大")
                    } else {
                        response = self.httpResponse(status: "500 Internal Server Error", contentType: "text/plain; charset=utf-8", body: "接收上传数据失败: \(receiveError.localizedDescription)")
                    }
                    self.finish(state: state, response: response, on: connection)
                    return
                }
            }

            if state.contentLength > self.maxUploadSize {
                self.finish(
                    state: state,
                    response: self.httpResponse(status: "413 Payload Too Large", contentType: "text/plain; charset=utf-8", body: "上传文件过大，最大支持 300MB。"),
                    on: connection
                )
                return
            }

            if error != nil {
                self.finish(
                    state: state,
                    response: self.httpResponse(status: "400 Bad Request", contentType: "text/plain; charset=utf-8", body: "请求读取失败"),
                    on: connection
                )
                return
            }

            if state.isComplete || isComplete {
                self.respond(to: state, on: connection)
            } else {
                self.armIdleTimeout(for: connection, state: state)
                self.receive(on: connection, state: state)
            }
        }
    }

    private func respond(to state: HTTPRequestReceiveState, on connection: NWConnection) {
        guard state.markFinished() else {
            connection.cancel()
            return
        }

        let response: Data
        if let requestText = state.header,
           let request = Self.requestLine(from: requestText) {
            let uploadPath = "/\(token)/upload"
            if request.method == "POST", request.path == uploadPath {
                if !state.hasContentLengthHeader {
                    response = httpResponse(status: "411 Length Required", contentType: "text/plain; charset=utf-8", body: "上传请求必须提供 Content-Length。")
                } else if state.contentLength < 0 || state.receivedBodyBytes != state.contentLength {
                    response = httpResponse(status: "400 Bad Request", contentType: "text/plain; charset=utf-8", body: "上传请求的 Content-Length 无效。")
                } else if state.contentLength > maxUploadSize {
                    response = httpResponse(status: "413 Payload Too Large", contentType: "text/plain; charset=utf-8", body: "上传文件过大，最大支持 300MB。")
                } else {
                    response = handleUpload(header: requestText, bodyURL: state.bodyFileURL)
                }
            } else if request.method != "POST",
                      request.path == "/\(token)" || request.path == "/\(token)/" {
                response = httpResponse(status: "200 OK", contentType: "text/html; charset=utf-8", body: uploadPage())
            } else {
                response = httpResponse(status: "403 Forbidden", contentType: "text/plain; charset=utf-8", body: "Forbidden")
            }
        } else {
            response = httpResponse(status: "400 Bad Request", contentType: "text/plain; charset=utf-8", body: "请求格式不正确")
        }

        state.cleanup()
        releaseConnection()
        sendResponse(response, on: connection)
    }

    private func acquireConnection() -> Bool {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        guard activeConnectionCount < maximumConnections else { return false }
        activeConnectionCount += 1
        return true
    }

    private func releaseConnection() {
        connectionLock.lock()
        activeConnectionCount = max(activeConnectionCount - 1, 0)
        connectionLock.unlock()
    }

    private func armIdleTimeout(for connection: NWConnection, state: HTTPRequestReceiveState) {
        state.armIdleTimeout(after: idleTimeout) { [weak self, weak connection] in
            guard let self,
                  let connection,
                  state.markFinished() else { return }
            state.cleanup()
            self.releaseConnection()
            connection.cancel()
        }
    }

    private func finish(state: HTTPRequestReceiveState, response: Data, on connection: NWConnection) {
        guard state.markFinished() else {
            connection.cancel()
            return
        }
        state.cleanup()
        releaseConnection()
        sendResponse(response, on: connection)
    }

    private static func requestLine(from header: String) -> (method: String, path: String)? {
        guard let firstLine = header.components(separatedBy: "\r\n").first else { return nil }
        let parts = firstLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return nil }
        return (parts[0].uppercased(), parts[1])
    }

    private func sendResponse(_ response: Data, on connection: NWConnection) {
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func handleUpload(header: String, bodyURL: URL?) -> Data {
        guard let bodyURL,
              let boundary = boundary(from: header) else {
            return httpResponse(status: "400 Bad Request", contentType: "text/plain; charset=utf-8", body: "上传格式不正确")
        }

        guard let uploadedFile = extractFile(fromBodyFile: bodyURL, boundary: boundary) else {
            return httpResponse(status: "400 Bad Request", contentType: "text/plain; charset=utf-8", body: "没有找到上传文件")
        }
        guard allowedUploadExtensions.contains(URL(fileURLWithPath: uploadedFile.fileName).pathExtension.lowercased()) else {
            return httpResponse(status: "415 Unsupported Media Type", contentType: "text/plain; charset=utf-8", body: "仅支持 ZIP、CBZ、EPUB、PDF、JPG、PNG、WebP、HEIC。")
        }
        guard uploadedFile.byteCount <= maxUploadSize else {
            return httpResponse(status: "413 Payload Too Large", contentType: "text/plain; charset=utf-8", body: "上传文件过大，最大支持 300MB。")
        }

        do {
            let uploadRoot = ComicManager.webUploadTemporaryRoot()
            try FileManager.default.createDirectory(at: uploadRoot, withIntermediateDirectories: true)
            let destinationURL = uploadRoot.appendingPathComponent(uploadedFile.fileName)
            try? FileManager.default.removeItem(at: destinationURL)
            try copyFileRange(from: bodyURL, range: uploadedFile.range, to: destinationURL)

            DispatchQueue.main.async { [onUpload] in
                onUpload(destinationURL)
            }

            return httpResponse(status: "200 OK", contentType: "text/html; charset=utf-8", body: successPage(fileName: uploadedFile.fileName))
        } catch {
            return httpResponse(status: "500 Internal Server Error", contentType: "text/plain; charset=utf-8", body: "保存上传文件失败: \(error.localizedDescription)")
        }
    }

    private func boundary(from header: String) -> String? {
        header
            .components(separatedBy: "\r\n")
            .first { $0.lowercased().contains("boundary=") }?
            .components(separatedBy: "boundary=")
            .last?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
    }

    private func extractFile(fromBodyFile bodyURL: URL, boundary: String) -> (fileName: String, range: Range<UInt64>, byteCount: UInt64)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: bodyURL.path),
              let fileSize = attributes[.size] as? NSNumber else { return nil }
        let totalBytes = fileSize.uint64Value
        guard totalBytes > 0 else { return nil }

        let head = readFileChunk(bodyURL, offset: 0, length: min(Int(totalBytes), 256 * 1024))
        let separator = Data("\r\n\r\n".utf8)
        guard let partHeaderEnd = head.range(of: separator) else { return nil }
        let partHeaderData = head[..<partHeaderEnd.lowerBound]
        guard let partHeader = String(data: partHeaderData, encoding: .utf8),
              let rawFileName = fileName(from: partHeader) else { return nil }

        let safeFileName = sanitizedFileName(rawFileName)
        let fileStart = UInt64(partHeaderEnd.upperBound)
        let endMarker = Data("\r\n--\(boundary)".utf8)
        let tailLength = min(Int(totalBytes), 512 * 1024)
        let tailOffset = totalBytes - UInt64(tailLength)
        let tail = readFileChunk(bodyURL, offset: tailOffset, length: tailLength)
        guard let fileEndInTail = tail.range(of: endMarker, options: .backwards) else { return nil }
        let fileEnd = tailOffset + UInt64(fileEndInTail.lowerBound)
        guard fileEnd >= fileStart else { return nil }

        return (safeFileName, fileStart..<fileEnd, fileEnd - fileStart)
    }

    private func readFileChunk(_ url: URL, offset: UInt64, length: Int) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: length) ?? Data()
        } catch {
            return Data()
        }
    }

    private func copyFileRange(from sourceURL: URL, range: Range<UInt64>, to destinationURL: URL) throws {
        guard range.lowerBound <= range.upperBound,
              let attributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path),
              let sourceSize = (attributes[.size] as? NSNumber)?.uint64Value,
              range.upperBound <= sourceSize else {
            throw LocalWebServerFileError.invalidRange
        }
        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        let source = try FileHandle(forReadingFrom: sourceURL)
        let destination = try FileHandle(forWritingTo: destinationURL)
        defer {
            try? source.close()
            try? destination.close()
        }
        try source.seek(toOffset: range.lowerBound)
        var remaining = range.upperBound - range.lowerBound
        while remaining > 0 {
            let readSize = min(Int(remaining), 1024 * 1024)
            guard let chunk = try source.read(upToCount: readSize), !chunk.isEmpty else { break }
            try destination.write(contentsOf: chunk)
            remaining -= UInt64(chunk.count)
        }
        guard remaining == 0 else {
            throw LocalWebServerFileError.incompleteCopy
        }
    }

    private func fileName(from partHeader: String) -> String? {
        let marker = "filename=\""
        guard let range = partHeader.range(of: marker) else { return nil }
        let remainder = partHeader[range.upperBound...]
        guard let end = remainder.firstIndex(of: "\"") else { return nil }
        return String(remainder[..<end])
    }

    private func sanitizedFileName(_ fileName: String) -> String {
        let fallback = "upload-\(UUID().uuidString).zip"
        let lastComponent = URL(fileURLWithPath: fileName).lastPathComponent
        let allowed = lastComponent.filter { $0.isLetter || $0.isNumber || ".-_ ".contains($0) }
        return allowed.isEmpty ? fallback : allowed
    }

    private func httpResponse(status: String, contentType: String, body: String) -> Data {
        let bodyData = Data(body.utf8)
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(bodyData.count)\r\n"
        header += "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(bodyData)
        return response
    }

    private func uploadPage() -> String {
        """
        <!doctype html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>MReader 上传</title>
        <style>
        body{font-family:-apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif;margin:32px;background:#f5f5f7;color:#111}
        main{max-width:520px;margin:auto;background:white;border-radius:16px;padding:24px;box-shadow:0 12px 40px rgba(0,0,0,.08)}
        h1{font-size:28px;margin:0 0 8px}
        p{color:#666;line-height:1.5}
        input,button{font-size:18px;width:100%;box-sizing:border-box;margin-top:16px}
        button{border:0;border-radius:12px;background:#007aff;color:white;padding:14px;font-weight:700}
        </style>
        </head>
        <body><main>
        <h1>MReader 网页导入</h1>
        <p>选择 ZIP、CBZ、EPUB、PDF 或图片上传。上传完成后 app 会自动加入书架。</p>
        <form method="post" action="/\(token)/upload" enctype="multipart/form-data">
        <input name="file" type="file" accept=".zip,.cbz,.epub,.pdf,.jpg,.jpeg,.png,.webp,.gif,.heic,.heif" required>
        <button type="submit">上传到 MReader</button>
        </form>
        </main></body></html>
        """
    }

    private func successPage(fileName: String) -> String {
        """
        <!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <body style="font-family:-apple-system,BlinkMacSystemFont,sans-serif;margin:32px;background:#f5f5f7;color:#111">
        <main style="max-width:520px;margin:auto;background:white;border-radius:16px;padding:24px">
        <h1>上传完成</h1><p>\(fileName) 已发送到 MReader，可以回到 app 查看导入结果。</p>
        <p><a href="/\(token)/">继续上传</a></p>
        </main></body></html>
        """
    }
}
