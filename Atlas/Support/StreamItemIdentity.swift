import PipedKit

enum StreamItemIdentity {
    /// Preserves response order while keeping only the first item for each SwiftUI identity.
    nonisolated static func firstOccurrences(
        in items: [StreamItem],
        excludingIDs: Set<String> = []
    ) -> [StreamItem] {
        var seenIDs = excludingIDs
        return firstOccurrences(in: items, seenIDs: &seenIDs)
    }

    /// The caller-owned set lets paginated loaders reject both previously rendered ids and
    /// duplicates later in the same response.
    nonisolated static func firstOccurrences(
        in items: [StreamItem],
        seenIDs: inout Set<String>
    ) -> [StreamItem] {
        items.filter { seenIDs.insert($0.id).inserted }
    }
}
