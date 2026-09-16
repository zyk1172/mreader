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

/// Per-connection parser state. Every mutation is confined to
/// `LocalWebServerWorker.queue`; `@unchecked Sendable` only allows Network/GCD
/// callbacks to retain the state while that queue provides the synchronization.
nonisolated final class HTTPRequestReceiveState: @unchecked Sendable {
    private static let maxHeaderBytes = 64 * 1024
    private var headerBuffer = Data()
    private var bodyHandle: FileHandle?
    private var didFinish = false
    private var idleTimeoutGeneration = 0

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

    var isFinished: Bool { didFinish }

    func append(_ data: Data) throws {
        if header == nil {
            headerBuffer.append(data)
            guard let headerEnd = headerBuffer.range(of: Data("\r\n\r\n".utf8)) else {
                if headerBuffer.count > Self.maxHeaderBytes {
                    throw HTTPRequestReceiveError.headerTooLarge
                }
                return
            }
            guard headerEnd.upperBound <= Self.maxHeaderBytes else {
                throw HTTPRequestReceiveError.headerTooLarge
            }
            let headerData = headerBuffer[..<headerEnd.lowerBound]
            header = String(data: headerData, encoding: .utf8) ?? ""
            method = Self.method(from: header ?? "")
            hasContentLengthHeader = Self.hasContentLengthHeader(in: header ?? "")
            // Only the upload endpoint accepts a request body. GET/HEAD and other
            // non-POST requests are complete as soon as their headers arrive;
            // a POST without Content-Length is rejected by respond() instead of
            // waiting for the client to close a keep-alive connection.
            contentLength = method == "POST"
                ? Self.contentLength(from: header ?? "") ?? -1
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
        invalidateIdleTimeout()
        try? bodyHandle?.close()
        bodyHandle = nil
        if let bodyFileURL {
            try? FileManager.default.removeItem(at: bodyFileURL)
            self.bodyFileURL = nil
        }
        headerBuffer.removeAll(keepingCapacity: false)
    }

    func markFinished() -> Bool {
        guard !didFinish else { return false }
        didFinish = true
        invalidateIdleTimeout()
        return true
    }

    /// Returns a monotonically increasing token. Delayed blocks validate the token
    /// before timing a request out, so re-arming never lets an older timeout win.
    func nextIdleTimeoutGeneration() -> Int {
        idleTimeoutGeneration &+= 1
        return idleTimeoutGeneration
    }

    func shouldFireIdleTimeout(generation: Int) -> Bool {
        !didFinish && generation == idleTimeoutGeneration
    }

    private func invalidateIdleTimeout() {
        idleTimeoutGeneration &+= 1
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

@MainActor
final class LocalWebServer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var address = ""
    @Published var errorMessage: String?

    private var worker: LocalWebServerWorker?
    private var generation = UUID()
    private var onUpload: ((URL) -> Void)?

    /// Startup maintenance uses the same cleanup entry point as before the worker
    /// split. It is intentionally nonisolated because it performs only filesystem
    /// cleanup and never touches observable UI state.
    nonisolated static func clearStaleBodyFiles() {
        LocalWebServerWorker.clearStaleBodyFiles()
    }

    func start(onUpload: @escaping (URL) -> Void) {
        stop()
        self.onUpload = onUpload
        errorMessage = nil

        let generation = UUID()
        self.generation = generation
        let worker = LocalWebServerWorker(
            stateHandler: { [weak self] state in
                guard let self, self.generation == generation else { return }
                switch state {
                case .ready(let address):
                    self.isRunning = true
                    self.address = address
                    self.errorMessage = nil
                case .failed(let message):
                    self.isRunning = false
                    self.address = ""
                    self.errorMessage = message
                case .cancelled:
                    self.isRunning = false
                    self.address = ""
                }
            },
            uploadHandler: { [weak self] url in
                guard let self, self.generation == generation else { return }
                self.onUpload?(url)
            }
        )
        self.worker = worker
        worker.start()
    }

    func stop() {
        generation = UUID()
        worker?.stop()
        worker = nil
        onUpload = nil
        isRunning = false
        address = ""
    }
}

/// Network.framework callbacks, request parsing and all upload file I/O live on
/// one shared dedicated serial queue. Sharing the queue across worker generations
/// guarantees an old listener is stopped before a replacement binds the same port,
/// while still keeping every 64 KB receive callback and large multipart copy away
/// from MainActor / SwiftUI rendering.
nonisolated private final class LocalWebServerWorker: @unchecked Sendable {
    enum State: Sendable {
        case ready(address: String)
        case failed(message: String)
        case cancelled
    }

    private struct ActiveConnection {
        let connection: NWConnection
        let state: HTTPRequestReceiveState
    }

    private static let sharedQueue = DispatchQueue(
        label: "com.mreader.local-web-server",
        qos: .userInitiated
    )
    private let queue: DispatchQueue
    private let stateHandler: @MainActor @Sendable (State) -> Void
    private let uploadHandler: @MainActor @Sendable (URL) -> Void

    private var listener: NWListener?
    private var token = ""
    private var activeConnections: [ObjectIdentifier: ActiveConnection] = [:]
    private var isStopped = true

    private let port: UInt16 = 8080
    private let maxUploadSize = 300 * 1024 * 1024
    private let maximumConnections = 4
    private let idleTimeout: TimeInterval = 30
    private let allowedUploadExtensions: Set<String> = [
        "zip", "cbz", "epub", "pdf", "jpg", "jpeg", "png", "webp", "gif", "heic", "heif"
    ]

    init(
        stateHandler: @escaping @MainActor @Sendable (State) -> Void,
        uploadHandler: @escaping @MainActor @Sendable (URL) -> Void
    ) {
        self.queue = Self.sharedQueue
        self.stateHandler = stateHandler
        self.uploadHandler = uploadHandler
    }

    func start() {
        queue.async { [self] in
            startOnQueue()
        }
    }

    func stop() {
        queue.async { [self] in
            stopOnQueue(notify: true)
        }
    }

    private func startOnQueue() {
        guard isStopped else { return }
        isStopped = false
        token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        Self.clearStaleBodyFiles()

        do {
            guard let port = NWEndpoint.Port(rawValue: port) else {
                emit(.failed(message: "网页服务启动失败: 无效端口"))
                isStopped = true
                return
            }
            let listener = try NWListener(using: .tcp, on: port)
            listener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state)
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            isStopped = true
            emit(.failed(message: "网页服务启动失败: \(error.localizedDescription)"))
        }
    }

    private func stopOnQueue(notify: Bool) {
        guard !isStopped || listener != nil || !activeConnections.isEmpty else {
            if notify { emit(.cancelled) }
            return
        }
        isStopped = true

        if let listener {
            listener.stateUpdateHandler = nil
            listener.newConnectionHandler = nil
            listener.cancel()
            self.listener = nil
        }

        for active in activeConnections.values {
            if active.state.markFinished() {
                active.state.cleanup()
            }
            active.connection.cancel()
        }
        activeConnections.removeAll()
        if notify { emit(.cancelled) }
    }

    private func handleListenerState(_ state: NWListener.State) {
        guard !isStopped else { return }
        switch state {
        case .ready:
            let ip = Self.localIPAddress() ?? "127.0.0.1"
            emit(.ready(address: "http://\(ip):\(port)/\(token)/"))
        case .failed(let error):
            let message = "网页服务启动失败: \(error.localizedDescription)"
            stopOnQueue(notify: false)
            emit(.failed(message: message))
        case .cancelled:
            stopOnQueue(notify: false)
            emit(.cancelled)
        default:
            break
        }
    }

    private func handle(_ connection: NWConnection) {
        guard !isStopped else {
            connection.cancel()
            return
        }
        guard activeConnections.count < maximumConnections else {
            connection.start(queue: queue)
            sendResponse(
                httpResponse(
                    status: "503 Service Unavailable",
                    contentType: "text/plain; charset=utf-8",
                    body: "连接数已达到上限"
                ),
                on: connection
            )
            return
        }

        let state = HTTPRequestReceiveState()
        activeConnections[ObjectIdentifier(connection)] = ActiveConnection(
            connection: connection,
            state: state
        )
        connection.start(queue: queue)
        armIdleTimeout(for: connection, state: state)
        receive(on: connection, state: state)
    }

    private func receive(on connection: NWConnection, state: HTTPRequestReceiveState) {
        guard !state.isFinished, !isStopped else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            self?.handleReceive(
                data: data,
                isComplete: isComplete,
                error: error,
                on: connection,
                state: state
            )
        }
    }

    private func handleReceive(
        data: Data?,
        isComplete: Bool,
        error: NWError?,
        on connection: NWConnection,
        state: HTTPRequestReceiveState
    ) {
        guard !state.isFinished, !isStopped else { return }

        if let data, !data.isEmpty {
            do {
                try state.append(data)
            } catch let receiveError {
                let response: Data
                if case HTTPRequestReceiveError.headerTooLarge = receiveError {
                    response = httpResponse(
                        status: "431 Request Header Fields Too Large",
                        contentType: "text/plain; charset=utf-8",
                        body: "请求头过大"
                    )
                } else {
                    response = httpResponse(
                        status: "500 Internal Server Error",
                        contentType: "text/plain; charset=utf-8",
                        body: "接收上传数据失败: \(receiveError.localizedDescription)"
                    )
                }
                finish(state: state, response: response, on: connection)
                return
            }
        }

        if state.contentLength > maxUploadSize {
            finish(
                state: state,
                response: httpResponse(
                    status: "413 Payload Too Large",
                    contentType: "text/plain; charset=utf-8",
                    body: "上传文件过大，最大支持 300MB。"
                ),
                on: connection
            )
            return
        }

        if error != nil {
            finish(
                state: state,
                response: httpResponse(
                    status: "400 Bad Request",
                    contentType: "text/plain; charset=utf-8",
                    body: "请求读取失败"
                ),
                on: connection
            )
            return
        }

        if state.isComplete || isComplete {
            respond(to: state, on: connection)
        } else {
            armIdleTimeout(for: connection, state: state)
            receive(on: connection, state: state)
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
                    response = httpResponse(
                        status: "411 Length Required",
                        contentType: "text/plain; charset=utf-8",
                        body: "上传请求必须提供 Content-Length。"
                    )
                } else if state.contentLength < 0 || state.receivedBodyBytes != state.contentLength {
                    response = httpResponse(
                        status: "400 Bad Request",
                        contentType: "text/plain; charset=utf-8",
                        body: "上传请求的 Content-Length 无效。"
                    )
                } else if state.contentLength > maxUploadSize {
                    response = httpResponse(
                        status: "413 Payload Too Large",
                        contentType: "text/plain; charset=utf-8",
                        body: "上传文件过大，最大支持 300MB。"
                    )
                } else {
                    response = handleUpload(header: requestText, bodyURL: state.bodyFileURL)
                }
            } else if request.method != "POST",
                      request.path == "/\(token)" || request.path == "/\(token)/" {
                response = httpResponse(
                    status: "200 OK",
                    contentType: "text/html; charset=utf-8",
                    body: uploadPage()
                )
            } else {
                response = httpResponse(
                    status: "403 Forbidden",
                    contentType: "text/plain; charset=utf-8",
                    body: "Forbidden"
                )
            }
        } else {
            response = httpResponse(
                status: "400 Bad Request",
                contentType: "text/plain; charset=utf-8",
                body: "请求格式不正确"
            )
        }

        state.cleanup()
        activeConnections.removeValue(forKey: ObjectIdentifier(connection))
        sendResponse(response, on: connection)
    }

    private func armIdleTimeout(for connection: NWConnection, state: HTTPRequestReceiveState) {
        let generation = state.nextIdleTimeoutGeneration()
        queue.asyncAfter(deadline: .now() + idleTimeout) { [weak self, weak connection] in
            guard let self,
                  let connection,
                  state.shouldFireIdleTimeout(generation: generation),
                  state.markFinished() else { return }
            state.cleanup()
            self.activeConnections.removeValue(forKey: ObjectIdentifier(connection))
            connection.cancel()
        }
    }

    private func finish(state: HTTPRequestReceiveState, response: Data, on connection: NWConnection) {
        guard state.markFinished() else {
            connection.cancel()
            return
        }
        state.cleanup()
        activeConnections.removeValue(forKey: ObjectIdentifier(connection))
        sendResponse(response, on: connection)
    }

    private func sendResponse(_ response: Data, on connection: NWConnection) {
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func handleUpload(header: String, bodyURL: URL?) -> Data {
        guard let bodyURL,
              let boundary = boundary(from: header) else {
            return httpResponse(
                status: "400 Bad Request",
                contentType: "text/plain; charset=utf-8",
                body: "上传格式不正确"
            )
        }

        guard let uploadedFile = extractFile(fromBodyFile: bodyURL, boundary: boundary) else {
            return httpResponse(
                status: "400 Bad Request",
                contentType: "text/plain; charset=utf-8",
                body: "没有找到上传文件"
            )
        }
        guard allowedUploadExtensions.contains(
            URL(fileURLWithPath: uploadedFile.fileName).pathExtension.lowercased()
        ) else {
            return httpResponse(
                status: "415 Unsupported Media Type",
                contentType: "text/plain; charset=utf-8",
                body: "仅支持 ZIP、CBZ、EPUB、PDF、JPG、PNG、WebP、HEIC。"
            )
        }
        guard uploadedFile.byteCount <= maxUploadSize else {
            return httpResponse(
                status: "413 Payload Too Large",
                contentType: "text/plain; charset=utf-8",
                body: "上传文件过大，最大支持 300MB。"
            )
        }

        do {
            let uploadRoot = ComicManager.webUploadTemporaryRoot()
            try FileManager.default.createDirectory(at: uploadRoot, withIntermediateDirectories: true)
            let destinationURL = uploadRoot.appendingPathComponent(uploadedFile.fileName)
            try? FileManager.default.removeItem(at: destinationURL)
            try copyFileRange(from: bodyURL, range: uploadedFile.range, to: destinationURL)

            Task { @MainActor [uploadHandler] in
                uploadHandler(destinationURL)
            }

            return httpResponse(
                status: "200 OK",
                contentType: "text/html; charset=utf-8",
                body: successPage(fileName: uploadedFile.fileName)
            )
        } catch {
            return httpResponse(
                status: "500 Internal Server Error",
                contentType: "text/plain; charset=utf-8",
                body: "保存上传文件失败: \(error.localizedDescription)"
            )
        }
    }

    private func emit(_ state: State) {
        Task { @MainActor [stateHandler] in
            stateHandler(state)
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

    private func extractFile(
        fromBodyFile bodyURL: URL,
        boundary: String
    ) -> (fileName: String, range: Range<UInt64>, byteCount: UInt64)? {
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

    private func copyFileRange(
        from sourceURL: URL,
        range: Range<UInt64>,
        to destinationURL: URL
    ) throws {
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

    private static func requestLine(from header: String) -> (method: String, path: String)? {
        guard let firstLine = header.components(separatedBy: "\r\n").first else { return nil }
        let parts = firstLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return nil }
        return (parts[0].uppercased(), parts[1])
    }

    fileprivate static func clearStaleBodyFiles() {
        let tempRoot = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: tempRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for file in files
        where file.lastPathComponent.hasPrefix("MReaderWebUpload-") && file.pathExtension == "body" {
            try? FileManager.default.removeItem(at: file)
        }
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
            getnameinfo(
                interface.ifa_addr,
                socklen_t(interface.ifa_addr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            address = String(cString: hostname)
            break
        }
        return address
    }
}