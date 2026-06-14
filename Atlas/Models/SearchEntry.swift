import Foundation
import SwiftData

/// A locally recorded search query, kept as a For You personalization signal.
/// Unique by normalized query, so re-running a search bumps `count` and the
/// timestamp instead of piling up duplicate rows — frequently searched topics
/// naturally weigh more, and stale intent ages out via `lastSearchedAt`.
@Model
final class SearchEntry {
    @Attribute(.unique) var query: String
    var lastSearchedAt: Date
    var count: Int

    init(query: String, lastSearchedAt: Date = .now, count: Int = 1) {
        self.query = query
        self.lastSearchedAt = lastSearchedAt
        self.count = count
    }

    /// Collapse trivial differences (case, surrounding space) so "SwiftUI" and
    /// "swiftui " map to one row.
    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
