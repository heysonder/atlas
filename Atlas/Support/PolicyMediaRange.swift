import Foundation

extension PolicyMediaAssetFactory {
    enum MediaError: Error, LocalizedError, Sendable, Equatable {
        case invalidRange
        case mediaTooLarge(maximumBytes: Int64)

        var errorDescription: String? {
            switch self {
            case .invalidRange:
                "The media server returned an inconsistent byte range."
            case .mediaTooLarge(let maximumBytes):
                "The media exceeded the \(maximumBytes) byte playback limit."
            }
        }
    }

    nonisolated static func finiteMediaRange(
        offset: Int64,
        remaining: Int64
    ) throws -> ClosedRange<Int64> {
        guard offset >= 0, offset < maximumMediaBytes, remaining > 0 else {
            throw MediaError.invalidRange
        }
        let length = min(mediaChunkBytes, remaining, maximumMediaBytes - offset)
        let (endExclusive, overflow) = offset.addingReportingOverflow(length)
        guard !overflow, endExclusive > offset else { throw MediaError.invalidRange }
        return offset...(endExclusive - 1)
    }
}
