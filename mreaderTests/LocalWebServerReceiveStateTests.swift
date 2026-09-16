import Foundation
import Testing
@testable import mreader

struct LocalWebServerReceiveStateTests {
    @Test
    func fragmentedHeaderDoesNotCountBodyBytesTowardHeaderLimit() throws {
        let state = HTTPRequestReceiveState()
        defer { state.cleanup() }

        var firstChunk = Data("POST /token/upload HTTP/1.1\r\nHost: localhost\r\nX-Padding: ".utf8)
        firstChunk.append(Data(repeating: 0x41, count: 32 * 1024))
        try state.append(firstChunk)

        let body = Data(repeating: 0x42, count: 40 * 1024)
        var secondChunk = Data("\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        secondChunk.append(body)
        try state.append(secondChunk)

        #expect(state.isComplete)
        #expect(state.contentLength == body.count)
        #expect(state.receivedBodyBytes == body.count)
    }

    @Test
    func incompleteHeaderStillRejectsBytesBeyondConfiguredLimit() throws {
        let state = HTTPRequestReceiveState()
        defer { state.cleanup() }

        var didReject = false
        do {
            try state.append(Data(repeating: 0x41, count: 64 * 1024 + 1))
        } catch {
            didReject = true
        }
        #expect(didReject)
    }
}
