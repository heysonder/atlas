import Foundation

/// The persistence boundary for metadata originating outside Atlas.
///
/// These limits intentionally match backup import/export so every row Atlas
/// writes can later make a lossless round trip through a supported backup.
nonisolated enum PersistedMetadataPolicy {
    enum Violation: Error, Equatable {
        case invalidValue(field: String)
        case limitExceeded(field: String, maximum: Int)
        case duplicateValue(field: String)
    }

    static let maximumBackupBytes = 16 * 1_024 * 1_024
    static let maximumTotalRecords = 100_000
    static let maximumHistory = 25_000
    static let maximumSearches = 5_000
    static let maximumChannels = 5_000
    static let maximumPlaylists = 1_000
    static let maximumFeedback = 25_000
    static let maximumVideosPerPlaylist = 5_000
    static let maximumPlaylistVideos = 50_000

    static let maximumIdentifierBytes = 512
    static let maximumHumanTextBytes = 4_096
    static let maximumURLBytes = 16_384
    static let maximumCollectionValues = 512
    static let maximumTags = 128
    static let maximumTagBytes = 1_024
    static let maximumAggregateTagBytes = 32_768
    static let maximumPlaybackSeconds = 2_592_000

    static func requireCount(_ count: Int, maximum: Int, field: String) throws {
        guard count >= 0 else { throw Violation.invalidValue(field: field) }
        guard count <= maximum else {
            throw Violation.limitExceeded(field: field, maximum: maximum)
        }
    }

    static func requireIdentifier(_ value: String, field: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Violation.invalidValue(field: field)
        }
        try requireBytes(value, maximum: maximumIdentifierBytes, field: field)
    }

    static func requireNonemptyText(_ value: String, field: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Violation.invalidValue(field: field)
        }
        try requireText(value, field: field)
    }

    static func requireText(_ value: String, field: String) throws {
        try requireBytes(value, maximum: maximumHumanTextBytes, field: field)
    }

    static func requireOptionalText(_ value: String?, field: String) throws {
        if let value { try requireText(value, field: field) }
    }

    static func requireOptionalURL(_ value: String?, field: String) throws {
        guard let value else { return }
        try requireBytes(value, maximum: maximumURLBytes, field: field)
    }

    static func requireFiniteDate(_ value: Date, field: String) throws {
        guard value.timeIntervalSinceReferenceDate.isFinite else {
            throw Violation.invalidValue(field: field)
        }
    }

    static func requirePlaybackNumber(_ value: Double, field: String) throws {
        guard value.isFinite,
            value >= 0,
            value <= Double(maximumPlaybackSeconds)
        else {
            throw Violation.invalidValue(field: field)
        }
    }

    static func requirePlaybackDuration(_ value: Int, field: String) throws {
        guard (0...maximumPlaybackSeconds).contains(value) else {
            throw Violation.invalidValue(field: field)
        }
    }

    static func requireIdentifiers(
        _ values: [String],
        maximum: Int = maximumCollectionValues,
        field: String
    ) throws {
        try requireCount(values.count, maximum: maximum, field: field)
        var seen = Set<String>()
        for (index, value) in values.enumerated() {
            let valueField = "\(field)[\(index)]"
            try requireIdentifier(value, field: valueField)
            guard seen.insert(value).inserted else {
                throw Violation.duplicateValue(field: valueField)
            }
        }
    }

    static func requireTextCollection(
        _ values: [String],
        maximum: Int = maximumCollectionValues,
        field: String
    ) throws {
        try requireCount(values.count, maximum: maximum, field: field)
        for (index, value) in values.enumerated() {
            try requireText(value, field: "\(field)[\(index)]")
        }
    }

    static func requireTags(_ tags: [String]?, field: String) throws {
        guard let tags else { return }
        try requireCount(tags.count, maximum: maximumTags, field: field)
        var aggregateBytes = 0
        for (index, tag) in tags.enumerated() {
            let tagField = "\(field)[\(index)]"
            try requireBytes(tag, maximum: maximumTagBytes, field: tagField)
            aggregateBytes = try checkedSum(
                aggregateBytes, tag.utf8.count,
                maximum: maximumAggregateTagBytes,
                field: field + ".bytes")
        }
    }

    static func checkedSum(
        _ values: Int...,
        maximum: Int,
        field: String
    ) throws -> Int {
        var total = 0
        for value in values {
            guard value >= 0 else { throw Violation.invalidValue(field: field) }
            let (sum, overflow) = total.addingReportingOverflow(value)
            guard !overflow, sum <= maximum else {
                throw Violation.limitExceeded(field: field, maximum: maximum)
            }
            total = sum
        }
        return total
    }

    static func playlistNameKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive],
                locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func requireBytes(_ value: String, maximum: Int, field: String) throws {
        guard value.utf8.count <= maximum else {
            throw Violation.limitExceeded(field: field, maximum: maximum)
        }
    }
}
