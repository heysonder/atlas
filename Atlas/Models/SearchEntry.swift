import Foundation
import SwiftData

/// A locally recorded search query, kept as a For You personalization signal.
/// Unique by normalized query, so re-running a search bumps `count` and the
/// timestamp instead of piling up duplicate rows — frequently searched topics
/// naturally weigh more, and stale intent ages out via `lastSearchedAt`.
@Model
final class SearchEntry {
    @Attribute(.unique) var query: String
    var displayQuery: String?
    var lastSearchedAt: Date
    var count: Int

    init(query: String, displayQuery: String? = nil, lastSearchedAt: Date = .now, count: Int = 1) {
        self.query = Self.normalize(query)
        self.displayQuery = Self.displayText(displayQuery ?? query)
        self.lastSearchedAt = lastSearchedAt
        self.count = count
    }

    var displayTitle: String {
        Self.displayText(displayQuery) ?? query
    }

    /// Collapse trivial differences (case, surrounding space) so "SwiftUI" and
    /// "swiftui " map to one row.
    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func displayText(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
