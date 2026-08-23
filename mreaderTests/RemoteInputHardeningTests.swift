import Foundation
import Testing
@testable import mreader

struct RemoteInputHardeningTests {
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
}
