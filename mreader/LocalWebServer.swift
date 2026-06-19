import Foundation
import Network
import Combine

final class LocalWebServer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var address = ""
    @Published var errorMessage: String?

    private var listener: NWListener?
    private var onUpload: ((URL) -> Void)?
    private let port: UInt16 = 8080
    private let maxUploadSize = 300 * 1024 * 1024
    private let allowedUploadExtensions: Set<String> = ["zip", "cbz", "rar", "cbr", "7z", "pdf", "jpg", "jpeg", "png", "webp", "gif", "heic", "heif"]

    func start(onUpload: @escaping (URL) -> Void) {
        self.onUpload = onUpload
        stop()

        do {
            let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
            listener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.isRunning = true
                        self.address = "http://\(Self.localIPAddress() ?? "127.0.0.1"):\(self.port)"
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
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            self.listener = listener
            listener.start(queue: .global(qos: .userInitiated))
        } catch {
            errorMessage = "网页服务启动失败: \(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        address = ""
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var requestData = buffer
            if let data {
                requestData.append(data)
            }

            if requestData.count > self.maxUploadSize + 8192 {
                self.sendResponse(
                    self.httpResponse(status: "413 Payload Too Large", contentType: "text/plain; charset=utf-8", body: "上传文件过大，最大支持 300MB。"),
                    on: connection
                )
                return
            }

            if error != nil || isComplete {
                self.respond(to: requestData, on: connection)
                return
            }

            if self.hasCompleteHTTPRequest(requestData) {
                self.respond(to: requestData, on: connection)
            } else {
                self.receive(on: connection, buffer: requestData)
            }
        }
    }

    private func hasCompleteHTTPRequest(_ data: Data) -> Bool {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return false }
        let headerData = data[..<headerEnd.lowerBound]
        guard let header = String(data: headerData, encoding: .utf8) else { return false }
        let contentLength = header
            .components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0
        return data.count >= headerEnd.upperBound + contentLength
    }

    private func respond(to requestData: Data, on connection: NWConnection) {
        let response: Data
        if let requestText = String(data: requestData.prefix(4096), encoding: .utf8),
           requestText.hasPrefix("POST /upload") {
            if (contentLength(from: requestText) ?? 0) > maxUploadSize {
                response = httpResponse(status: "413 Payload Too Large", contentType: "text/plain; charset=utf-8", body: "上传文件过大，最大支持 300MB。")
            } else {
                response = handleUpload(requestData)
            }
        } else {
            response = httpResponse(status: "200 OK", contentType: "text/html; charset=utf-8", body: uploadPage())
        }

        sendResponse(response, on: connection)
    }

    private func sendResponse(_ response: Data, on connection: NWConnection) {
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func handleUpload(_ requestData: Data) -> Data {
        guard let headerEnd = requestData.range(of: Data("\r\n\r\n".utf8)),
              let header = String(data: requestData[..<headerEnd.lowerBound], encoding: .utf8),
              let boundary = boundary(from: header) else {
            return httpResponse(status: "400 Bad Request", contentType: "text/plain; charset=utf-8", body: "上传格式不正确")
        }

        let body = requestData[headerEnd.upperBound...]
        guard let uploadedFile = extractFile(from: Data(body), boundary: boundary) else {
            return httpResponse(status: "400 Bad Request", contentType: "text/plain; charset=utf-8", body: "没有找到上传文件")
        }
        guard allowedUploadExtensions.contains(URL(fileURLWithPath: uploadedFile.fileName).pathExtension.lowercased()) else {
            return httpResponse(status: "415 Unsupported Media Type", contentType: "text/plain; charset=utf-8", body: "仅支持 ZIP、CBZ、PDF、JPG、PNG、WebP、HEIC。")
        }
        guard uploadedFile.data.count <= maxUploadSize else {
            return httpResponse(status: "413 Payload Too Large", contentType: "text/plain; charset=utf-8", body: "上传文件过大，最大支持 300MB。")
        }

        do {
            let uploadRoot = FileManager.default.temporaryDirectory.appendingPathComponent("MReaderWebUploads", isDirectory: true)
            try FileManager.default.createDirectory(at: uploadRoot, withIntermediateDirectories: true)
            let destinationURL = uploadRoot.appendingPathComponent(uploadedFile.fileName)
            try uploadedFile.data.write(to: destinationURL, options: .atomic)

            DispatchQueue.main.async { [weak self] in
                self?.onUpload?(destinationURL)
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

    private func contentLength(from header: String) -> Int? {
        header
            .components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "") }
    }

    private func extractFile(from body: Data, boundary: String) -> (fileName: String, data: Data)? {
        let separator = Data("\r\n\r\n".utf8)
        guard let partHeaderEnd = body.range(of: separator) else { return nil }
        let partHeaderData = body[..<partHeaderEnd.lowerBound]
        guard let partHeader = String(data: partHeaderData, encoding: .utf8),
              let rawFileName = fileName(from: partHeader) else { return nil }

        let safeFileName = sanitizedFileName(rawFileName)
        let fileStart = partHeaderEnd.upperBound
        let endMarker = Data("\r\n--\(boundary)".utf8)
        guard let fileEnd = body[fileStart...].range(of: endMarker) else { return nil }

        return (safeFileName, Data(body[fileStart..<fileEnd.lowerBound]))
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
        <p>选择 ZIP、CBZ 或包含图片的压缩包上传。上传完成后 app 会自动加入书架。</p>
        <form method="post" action="/upload" enctype="multipart/form-data">
        <input name="file" type="file" accept=".zip,.cbz,.rar,.cbr,.7z,.pdf,.jpg,.jpeg,.png,.webp,.gif,.heic,.heif" required>
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
        <p><a href="/">继续上传</a></p>
        </main></body></html>
        """
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
