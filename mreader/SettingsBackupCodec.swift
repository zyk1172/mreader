import Foundation
import CryptoKit

nonisolated struct EncryptedSettingsBackupEnvelope: Codable, Sendable {
    static let format = "mreader.settings.encrypted.v1"

    let format: String
    let iterations: Int
    let salt: Data
    let sealedData: Data
}

nonisolated enum SettingsBackupCodecError: LocalizedError, Sendable {
    case invalidPassword
    case invalidFormat
    case credentialsRequireEncryption
    case encryptionFailed
    case decryptionFailed

    var errorDescription: String? {
        switch self {
        case .invalidPassword:
            return "备份密码至少需要 8 个字符"
        case .invalidFormat:
            return "设置备份格式无效"
        case .credentialsRequireEncryption:
            return "包含访问密钥的设置备份必须加密"
        case .encryptionFailed:
            return "无法加密设置备份"
        case .decryptionFailed:
            return "密码错误或加密备份已损坏"
        }
    }
}

nonisolated enum SettingsBackupCodec {
    private static let iterations = 100_000
    private static let saltByteCount = 16
    private static let maxEnvelopeBytes = 32 * 1024 * 1024
    private static let maxSealedDataBytes = 30 * 1024 * 1024

    static func encodePlain(_ backup: MReaderSettingsBackup) throws -> Data {
        guard !containsCredentials(backup) else {
            throw SettingsBackupCodecError.credentialsRequireEncryption
        }
        return try encodeRaw(backup)
    }

    private static func encodeRaw(_ backup: MReaderSettingsBackup) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(backup)
    }

    static func encodeEncrypted(_ backup: MReaderSettingsBackup, password: String) throws -> Data {
        guard password.count >= 8 else { throw SettingsBackupCodecError.invalidPassword }
        let plainData = try encodeRaw(backup)
        guard plainData.count <= maxSealedDataBytes else {
            throw SettingsBackupCodecError.encryptionFailed
        }
        let salt = randomData(count: saltByteCount)
        let key = deriveKey(password: password, salt: salt)
        guard let combined = try AES.GCM.seal(plainData, using: key).combined else {
            throw SettingsBackupCodecError.encryptionFailed
        }
        let envelope = EncryptedSettingsBackupEnvelope(
            format: EncryptedSettingsBackupEnvelope.format,
            iterations: iterations,
            salt: salt,
            sealedData: combined
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let encoded = try encoder.encode(envelope)
        guard encoded.count <= maxEnvelopeBytes else {
            throw SettingsBackupCodecError.encryptionFailed
        }
        return encoded
    }

    static func encodeEncryptedInBackground(_ backup: MReaderSettingsBackup, password: String) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try encodeEncrypted(backup, password: password)
        }.value
    }

    static func decode(_ data: Data, password: String? = nil) throws -> MReaderSettingsBackup {
        guard data.count <= maxEnvelopeBytes else {
            throw SettingsBackupCodecError.invalidFormat
        }
        if let envelope = try? JSONDecoder().decode(EncryptedSettingsBackupEnvelope.self, from: data),
           envelope.format == EncryptedSettingsBackupEnvelope.format {
            guard let password, password.count >= 8 else {
                throw SettingsBackupCodecError.invalidPassword
            }
            guard envelope.iterations == iterations,
                  envelope.salt.count == saltByteCount,
                  envelope.sealedData.count >= 28,
                  envelope.sealedData.count <= maxSealedDataBytes else {
                throw SettingsBackupCodecError.invalidFormat
            }
            do {
                let key = deriveKey(password: password, salt: envelope.salt)
                let sealedBox = try AES.GCM.SealedBox(combined: envelope.sealedData)
                let plainData = try AES.GCM.open(sealedBox, using: key)
                return try JSONDecoder().decode(MReaderSettingsBackup.self, from: plainData)
            } catch let error as SettingsBackupCodecError {
                throw error
            } catch {
                throw SettingsBackupCodecError.decryptionFailed
            }
        }
        do {
            return try JSONDecoder().decode(MReaderSettingsBackup.self, from: data)
        } catch {
            throw SettingsBackupCodecError.invalidFormat
        }
    }

    static func decodeInBackground(_ data: Data, password: String? = nil) async throws -> MReaderSettingsBackup {
        try await Task.detached(priority: .userInitiated) {
            try decode(data, password: password)
        }.value
    }

    static func isEncrypted(_ data: Data) -> Bool {
        guard data.count <= maxEnvelopeBytes else { return false }
        guard let envelope = try? JSONDecoder().decode(EncryptedSettingsBackupEnvelope.self, from: data) else {
            return false
        }
        return envelope.format == EncryptedSettingsBackupEnvelope.format
            && envelope.iterations == iterations
            && envelope.salt.count == saltByteCount
            && envelope.sealedData.count >= 28
            && envelope.sealedData.count <= maxSealedDataBytes
    }

    private static func randomData(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    private static func containsCredentials(_ backup: MReaderSettingsBackup) -> Bool {
        if hasValue(backup.openAIAPIKey) || backup.containsCredentials == true {
            return true
        }
        if backup.aiProviders?.contains(where: { hasValue($0.apiKey) }) == true {
            return true
        }
        return backup.mediaSources?.contains(where: { hasValue($0.apiKey) }) == true
    }

    private static func hasValue(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// PBKDF2-HMAC-SHA256 implemented with CryptoKit so the backup format has no third-party dependency.
    private static func deriveKey(password: String, salt: Data) -> SymmetricKey {
        let passwordKey = SymmetricKey(data: Data(password.utf8))
        var block = UInt32(1).bigEndian
        var initial = salt
        initial.append(Data(bytes: &block, count: MemoryLayout<UInt32>.size))

        var current = Data(HMAC<SHA256>.authenticationCode(for: initial, using: passwordKey))
        var result = current
        if iterations > 1 {
            for _ in 1..<iterations {
                current = Data(HMAC<SHA256>.authenticationCode(for: current, using: passwordKey))
                for index in result.indices {
                    result[index] ^= current[index]
                }
            }
        }
        return SymmetricKey(data: result.prefix(32))
    }
}
