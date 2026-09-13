import Foundation

nonisolated enum BoundedHTTPResponseError: Error {
    case invalidMaximum
    case missingResponse
    case tooLarge
}

nonisolated enum BoundedHTTPResponseReader {
    /// - Parameter redirectPolicy: 重定向逐跳判定（审查 #11）。返回 `.denied` 时请求会被取消，
    ///   避免“首次请求已通过”把后续跳转一并放行。传 nil 表示不做目标策略检查。
    static func data(
        for request: URLRequest,
        maximumBytes: Int,
        using session: URLSession = .shared,
        redirectPolicy: (@Sendable (URL) -> RemoteDestinationPolicy.Decision)? = nil
    ) async throws -> (Data, URLResponse) {
        guard maximumBytes >= 0 else {
            throw BoundedHTTPResponseError.invalidMaximum
        }
        let delegate = BoundedHTTPResponseDelegate(
            maximumBytes: maximumBytes,
            redirectPolicy: redirectPolicy
        )
        return try await withTaskCancellationHandler {
            try await delegate.run(request: request, configuration: session.configuration)
        } onCancel: {
            delegate.cancel()
        }
    }

    /// Byte-oriented compatibility helper for callers that already expose an
    /// AsyncSequence<UInt8>. Network responses use the chunk-based delegate below.
    static func collect<Bytes: AsyncSequence>(
        _ bytes: Bytes,
        maximumBytes: Int,
        expectedContentLength: Int64? = nil
    ) async throws -> Data where Bytes.Element == UInt8 {
        guard maximumBytes >= 0 else {
            throw BoundedHTTPResponseError.invalidMaximum
        }
        var data = Data()
        if let expectedContentLength, expectedContentLength > 0 {
            data.reserveCapacity(min(Int(expectedContentLength), maximumBytes))
        }
        for try await byte in bytes {
            try append(Data([byte]), to: &data, maximumBytes: maximumBytes)
        }
        return data
    }

    static func collectChunks<Chunks: AsyncSequence>(
        _ chunks: Chunks,
        maximumBytes: Int,
        expectedContentLength: Int64? = nil
    ) async throws -> Data where Chunks.Element == Data {
        guard maximumBytes >= 0 else {
            throw BoundedHTTPResponseError.invalidMaximum
        }
        var data = Data()
        if let expectedContentLength, expectedContentLength > 0 {
            data.reserveCapacity(min(Int(expectedContentLength), maximumBytes))
        }
        for try await chunk in chunks {
            try append(chunk, to: &data, maximumBytes: maximumBytes)
        }
        return data
    }

    fileprivate static func append(
        _ chunk: Data,
        to data: inout Data,
        maximumBytes: Int
    ) throws {
        guard chunk.count <= maximumBytes - data.count else {
            throw BoundedHTTPResponseError.tooLarge
        }
        data.append(chunk)
    }
}

private final class BoundedHTTPResponseDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maximumBytes: Int
    private let redirectPolicy: (@Sendable (URL) -> RemoteDestinationPolicy.Decision)?
    private var data = Data()
    private var response: URLResponse?
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var didFinish = false

    init(
        maximumBytes: Int,
        redirectPolicy: (@Sendable (URL) -> RemoteDestinationPolicy.Decision)? = nil
    ) {
        self.maximumBytes = maximumBytes
        self.redirectPolicy = redirectPolicy
    }

    func run(
        request: URLRequest,
        configuration: URLSessionConfiguration
    ) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
            self.continuation = continuation
            let delegateQueue = OperationQueue()
            delegateQueue.maxConcurrentOperationCount = 1
            let session = URLSession(
                configuration: configuration,
                delegate: self,
                delegateQueue: delegateQueue
            )
            self.session = session
            let task = session.dataTask(with: request)
            self.task = task
            task.resume()
        }
    }

    func cancel() {
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard response.expectedContentLength <= Int64(maximumBytes) else {
            completionHandler(.cancel)
            finish(.failure(BoundedHTTPResponseError.tooLarge))
            return
        }
        self.response = response
        if response.expectedContentLength > 0 {
            data.reserveCapacity(min(Int(response.expectedContentLength), maximumBytes))
        }
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        do {
            try BoundedHTTPResponseReader.append(data, to: &self.data, maximumBytes: maximumBytes)
        } catch {
            dataTask.cancel()
            finish(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let redirectPolicy, let url = request.url else {
            completionHandler(request)
            return
        }
        // 每一跳都重新判定：跨源或私网跳转不能被“首次请求已通过”豁免。
        if case .denied(let denial) = redirectPolicy(url) {
            completionHandler(nil)
            finish(.failure(RemoteDestinationPolicyError.denied(
                denial,
                host: RemoteDestinationPolicy.normalizedHost(of: url) ?? ""
            )))
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(.failure(error))
            return
        }
        guard let response else {
            finish(.failure(BoundedHTTPResponseError.missingResponse))
            return
        }
        finish(.success((data, response)))
    }

    private func finish(_ result: Result<(Data, URLResponse), Error>) {
        guard !didFinish else { return }
        didFinish = true
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(with: result)
        session?.finishTasksAndInvalidate()
    }
}
