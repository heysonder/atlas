import Foundation

@testable import Atlas

func writeBackupTestData(_ data: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("atlas-backup-test-\(UUID().uuidString).json")
    try data.write(to: url, options: .atomic)
    return url
}

func encodedBackupForTest(_ backup: AtlasBackup) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(backup)
}
