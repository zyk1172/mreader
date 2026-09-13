import Foundation
import Testing
@testable import mreader

struct RemoteInputHardeningTests {
    @Test
    func boundedResponseReaderCollectsMegabyteChunks() async throws {
        let chunks = AsyncStream<Data> { continuation in
            continuation.yield(Data(repeating: 0x5A, count: 1_048_576))
            continuation.yield(Data([0x01, 0x02, 0x03]))
            continuation.finish()
        }

        let data = try await BoundedHTTPResponseReader.collectChunks(
            chunks,
            maximumBytes: 1_048_579
        )
        #expect(data.count == 1_048_579)
        #expect(data.last == 0x03)
    }

    @Test
    func boundedResponseReaderRejectsAnOversizedDataChunk() async throws {
        let chunks = AsyncStream<Data> { continuation in
            continuation.yield(Data(repeating: 0x5A, count: 1_048_577))
            continuation.finish()
        }

        var didReject = false
        do {
            _ = try await BoundedHTTPResponseReader.collectChunks(
                chunks,
                maximumBytes: 1_048_576
            )
        } catch {
            didReject = error is BoundedHTTPResponseError
        }
        #expect(didReject)
    }

    @Test
    func boundedResponseReaderRejectsTheByteAfterTheConfiguredLimit() async throws {
        let bytes = AsyncStream<UInt8> { continuation in
            for byte in [UInt8(1), 2, 3, 4, 5] {
                continuation.yield(byte)
            }
            continuation.finish()
        }

        var didReject = false
        do {
            _ = try await BoundedHTTPResponseReader.collect(bytes, maximumBytes: 4)
        } catch {
            didReject = error is BoundedHTTPResponseError
        }
        #expect(didReject)
    }

    @Test
    func getWithoutContentLengthCompletesAfterHeaders() throws {
        let state = HTTPRequestReceiveState()
        defer { state.cleanup() }

        try state.append(Data(
            "GET /token/ HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n".utf8
        ))

        #expect(state.isComplete)
        #expect(state.contentLength == 0)
        #expect(state.receivedBodyBytes == 0)
    }

    @Test
    func postWithoutContentLengthCompletesForImmediateRejection() throws {
        let state = HTTPRequestReceiveState()
        defer { state.cleanup() }

        try state.append(Data(
            "POST /token/upload HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n".utf8
        ))

        #expect(state.isComplete)
        #expect(!state.hasContentLengthHeader)
        #expect(state.contentLength == -1)
    }

    @Test
    func remoteCacheIDsUseDigestAndReadLegacySanitizedPath() throws {
        let sourceID = UUID()
        let bookID = "series/../book?with spaces"
        let legacyRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MReaderRemoteImageCache", isDirectory: true)
            .appendingPathComponent(sourceID.uuidString, isDirectory: true)
            .appendingPathComponent("covers", isDirectory: true)
        let legacyURL = legacyRoot
            .appendingPathComponent(RemoteImageLoader.legacySafeFileName(bookID))
            .appendingPathExtension("img")
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        try Data([0x01, 0x02]).write(to: legacyURL)
        defer { try? FileManager.default.removeItem(at: legacyRoot.deletingLastPathComponent().deletingLastPathComponent()) }

        let hashed = RemoteImageLoader.safeFileName(bookID)
        #expect(hashed.count == 64)
        #expect(hashed.allSatisfy { "0123456789abcdef".contains($0) })
        #expect(RemoteImageLoader.cachedCoverPath(sourceID: sourceID, bookID: bookID) == legacyURL.path)
    }

    @Test
    func backupRejectsUntrustedPBKDFParameters() throws {
        let envelope = EncryptedSettingsBackupEnvelope(
            format: EncryptedSettingsBackupEnvelope.format,
            iterations: 1,
            salt: Data(repeating: 0, count: 16),
            sealedData: Data(repeating: 0, count: 28)
        )
        let data = try JSONEncoder().encode(envelope)

        #expect(throws: SettingsBackupCodecError.self) {
            _ = try SettingsBackupCodec.decode(data, password: "valid-password")
        }
    }

    @Test
    func oversizedBackupIsRejectedBeforeDecoding() {
        let oversizedData = Data(repeating: 0, count: 32 * 1024 * 1024 + 1)

        #expect(throws: SettingsBackupCodecError.self) {
            _ = try SettingsBackupCodec.decode(oversizedData)
        }
    }

    // MARK: - 明文备份凭据校验（审查 #9）

    /// 手工构造一个明文备份文件。直接喂 JSON 才能模拟“被篡改过的导入文件”，
    /// 因为 `encodePlain` 本来就会拦截凭据。
    private func plainBackupJSON(_ extraFields: String) -> Data {
        Data("""
        {
          "version": 10,
          "openAIBaseURL": "https://attacker.example/v1",
          "openAIModel": "gpt-4o-mini",
          "translationTargetLanguage": "简体中文",
          "isHapticFeedbackEnabled": true\(extraFields.isEmpty ? "" : ",\n  " + extraFields)
        }
        """.utf8)
    }

    @Test
    func plainBackupWithProviderAPIKeyIsRejectedOnDecode() {
        let data = plainBackupJSON("\"openAIAPIKey\": \"sk-plain-injected\"")

        #expect(throws: SettingsBackupCodecError.credentialsRequireEncryption) {
            _ = try SettingsBackupCodec.decode(data)
        }
        #expect(throws: SettingsBackupCodecError.credentialsRequireEncryption) {
            _ = try SettingsBackupService.decodePlain(data)
        }
    }

    @Test
    func plainBackupWithMediaSourceAPIKeyIsRejectedOnDecode() {
        let data = plainBackupJSON(
            """
            "mediaSources": [
                {
                  "id": "11111111-1111-1111-1111-111111111111",
                  "name": "NAS",
                  "type": "komga",
                  "baseURL": "http://192.168.1.10:8080",
                  "createdAt": 0,
                  "isEnabled": true,
                  "apiKey": "injected-media-key"
                }
              ]
            """
        )

        #expect(throws: SettingsBackupCodecError.credentialsRequireEncryption) {
            _ = try SettingsBackupCodec.decode(data)
        }
    }

    @Test
    func plainBackupClaimingCredentialsIsRejectedEvenWithoutKeys() {
        let data = plainBackupJSON("\"containsCredentials\": true")

        #expect(throws: SettingsBackupCodecError.credentialsRequireEncryption) {
            _ = try SettingsBackupCodec.decode(data)
        }
    }

    @Test
    func plainBackupWithoutCredentialsStillImports() throws {
        let backup = try SettingsBackupCodec.decode(plainBackupJSON(""))

        #expect(backup.openAIBaseURL == "https://attacker.example/v1")
        #expect(backup.openAIAPIKey == nil)
        #expect(!SettingsBackupCodec.backupContainsCredentials(backup))
    }

    @Test
    func encryptedBackupMayCarryCredentials() throws {
        let credentialJSON = Data("""
        {
          "version": 10,
          "openAIAPIKey": "sk-secret",
          "openAIBaseURL": "https://example.com/v1",
          "openAIModel": "gpt-4o-mini",
          "translationTargetLanguage": "简体中文",
          "isHapticFeedbackEnabled": true
        }
        """.utf8)
        let backup = try JSONDecoder().decode(MReaderSettingsBackup.self, from: credentialJSON)
        #expect(SettingsBackupCodec.backupContainsCredentials(backup))

        let encrypted = try SettingsBackupCodec.encodeEncrypted(backup, password: "valid-password")
        let restored = try SettingsBackupCodec.decode(encrypted, password: "valid-password")
        #expect(restored.openAIAPIKey == "sk-secret")
        #expect(!(String(data: encrypted, encoding: .utf8) ?? "").contains("sk-secret"))
    }
}
