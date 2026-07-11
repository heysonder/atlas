import Foundation

enum BackupFileCodec {
    static func encode(_ backup: AtlasBackup) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(backup)
        } catch {
            throw BackupExportError.cannotEncode
        }
    }

    static func write(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("atlas-backup.json")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw BackupExportError.cannotWrite
        }
        return url
    }

    static func read(from url: URL, maximumBytes: Int) throws -> Data {
        guard maximumBytes >= 0 else {
            throw BackupRestoreError.fileTooLarge(maximumBytes: 0)
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw BackupRestoreError.cannotReadFile
        }
        defer { try? handle.close() }

        do {
            let size = try handle.seekToEnd()
            guard size <= UInt64(maximumBytes) else {
                throw BackupRestoreError.fileTooLarge(maximumBytes: maximumBytes)
            }
            try handle.seek(toOffset: 0)
            let readLimit = maximumBytes == Int.max ? Int.max : maximumBytes + 1
            let data = try handle.read(upToCount: readLimit) ?? Data()
            guard data.count <= maximumBytes else {
                throw BackupRestoreError.fileTooLarge(maximumBytes: maximumBytes)
            }
            return data
        } catch let error as BackupRestoreError {
            throw error
        } catch {
            throw BackupRestoreError.cannotReadFile
        }
    }

    static func decode(_ data: Data) throws -> AtlasBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(AtlasBackup.self, from: data)
        } catch {
            throw BackupRestoreError.malformedBackup
        }
    }
}
