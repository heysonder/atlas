import Foundation

enum BackupRestoreError: Error, LocalizedError, Equatable {
    case cannotReadFile
    case fileTooLarge(maximumBytes: Int)
    case malformedBackup
    case unsupportedVersion(Int)
    case limitExceeded(field: String, maximum: Int)
    case invalidValue(field: String)
    case duplicateValue(field: String)
    case cannotSave

    var errorDescription: String? {
        switch self {
        case .cannotReadFile:
            "Atlas couldn't read that backup file."
        case .fileTooLarge(let maximumBytes):
            "That backup is larger than the supported \(maximumBytes / 1_048_576) MB limit."
        case .malformedBackup:
            "That file isn't a valid Atlas backup."
        case .unsupportedVersion(let version):
            "This backup uses unsupported version \(version)."
        case .limitExceeded(let field, let maximum):
            "The backup exceeds the supported limit at \(field) (maximum \(maximum))."
        case .invalidValue(let field):
            "The backup contains an invalid value at \(field)."
        case .duplicateValue(let field):
            "The backup contains a duplicate value at \(field)."
        case .cannotSave:
            "Atlas couldn't save the imported data. Your library was not changed."
        }
    }
}

enum BackupExportError: Error, LocalizedError, Equatable {
    case invalidStoredValue(field: String)
    case storedLimitExceeded(field: String, maximum: Int)
    case duplicateStoredValue(field: String)
    case encodedFileTooLarge(maximumBytes: Int)
    case cannotEncode
    case cannotWrite

    var errorDescription: String? {
        switch self {
        case .invalidStoredValue(let field):
            "Atlas can't export because stored data at \(field) is invalid. "
                + "Remove the affected library item and try again."
        case .storedLimitExceeded(let field, let maximum):
            "Atlas can't export because stored data at \(field) exceeds the supported "
                + "limit of \(maximum). Remove the affected library item and try again."
        case .duplicateStoredValue(let field):
            "Atlas can't export because stored data at \(field) conflicts with another item. "
                + "Rename or remove the duplicate and try again."
        case .encodedFileTooLarge(let maximumBytes):
            "Atlas can't export more than \(maximumBytes / 1_048_576) MB. "
                + "Remove some history, playlists, or ratings and try again."
        case .cannotEncode:
            "Atlas couldn't encode your data. Your library was not changed."
        case .cannotWrite:
            "Atlas couldn't write the temporary backup file. Your library was not changed."
        }
    }

    init(_ restoreError: BackupRestoreError) {
        switch restoreError {
        case .limitExceeded(let field, let maximum):
            self = .storedLimitExceeded(field: field, maximum: maximum)
        case .invalidValue(let field):
            self = .invalidStoredValue(field: field)
        case .duplicateValue(let field):
            self = .duplicateStoredValue(field: field)
        default:
            self = .cannotEncode
        }
    }
}
