import Foundation

/// A strictly parsed HTTP `Content-Range` value for byte responses.
nonisolated struct HTTPByteContentRange: Equatable, Sendable {
    let range: ClosedRange<Int64>?
    let totalByteCount: Int64?

    init?(_ response: HTTPURLResponse) {
        guard let value = response.value(forHTTPHeaderField: "Content-Range") else {
            return nil
        }
        self.init(headerValue: value)
    }

    init?(headerValue: String) {
        let pieces = headerValue.split(whereSeparator: \Character.isWhitespace)
        guard pieces.count == 2, pieces[0].lowercased() == "bytes" else {
            return nil
        }

        let rangeAndTotal = pieces[1].split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard rangeAndTotal.count == 2 else { return nil }

        if rangeAndTotal[1] == "*" {
            totalByteCount = nil
        } else {
            guard let total = Int64(rangeAndTotal[1]), total >= 0 else {
                return nil
            }
            totalByteCount = total
        }

        if rangeAndTotal[0] == "*" {
            range = nil
            return
        }

        let bounds = rangeAndTotal[0].split(
            separator: "-",
            omittingEmptySubsequences: false
        )
        guard bounds.count == 2,
            let lowerBound = Int64(bounds[0]),
            lowerBound >= 0,
            let upperBound = Int64(bounds[1]),
            upperBound >= lowerBound
        else {
            return nil
        }
        range = lowerBound...upperBound
    }

    static func byteCount(of range: ClosedRange<Int64>) -> Int64? {
        let (distance, subtractionOverflow) = range.upperBound.subtractingReportingOverflow(
            range.lowerBound
        )
        let (byteCount, additionOverflow) = distance.addingReportingOverflow(1)
        return subtractionOverflow || additionOverflow ? nil : byteCount
    }
}
