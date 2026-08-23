import Foundation

nonisolated enum BoundedHTTPResponseError: Error {
    case tooLarge
}

nonisolated enum BoundedHTTPResponseReader {
    static func data(
        for request: URLRequest,
        maximumBytes: Int,
        using session: URLSession = .shared
    ) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        if response.expectedContentLength > Int64(maximumBytes) {
            throw BoundedHTTPResponseError.tooLarge
        }

        var data = Data()
        data = try await collect(bytes, maximumBytes: maximumBytes, expectedContentLength: response.expectedContentLength)
        return (data, response)
    }

    static func collect<Bytes: AsyncSequence>(
        _ bytes: Bytes,
        maximumBytes: Int,
        expectedContentLength: Int64? = nil
    ) async throws -> Data where Bytes.Element == UInt8 {
        var data = Data()
        if let expectedContentLength, expectedContentLength > 0 {
            data.reserveCapacity(min(Int(expectedContentLength), maximumBytes))
        }
        for try await byte in bytes {
            guard data.count < maximumBytes else {
                throw BoundedHTTPResponseError.tooLarge
            }
            data.append(byte)
        }
        return data
    }
}
