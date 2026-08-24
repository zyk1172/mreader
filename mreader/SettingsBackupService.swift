import Foundation

/// 设置导入/导出的运行时边界；格式与密码学实现继续由 SettingsBackupCodec 维护。
nonisolated enum SettingsBackupService {
    static func encodeEncrypted(_ backup: MReaderSettingsBackup, password: String) async throws -> Data {
        try await SettingsBackupCodec.encodeEncryptedInBackground(backup, password: password)
    }

    static func decode(_ data: Data, password: String? = nil) async throws -> MReaderSettingsBackup {
        try await SettingsBackupCodec.decodeInBackground(data, password: password)
    }

    static func decodePlain(_ data: Data) throws -> MReaderSettingsBackup {
        try SettingsBackupCodec.decode(data)
    }

    static func isEncrypted(_ data: Data) -> Bool {
        SettingsBackupCodec.isEncrypted(data)
    }
}
