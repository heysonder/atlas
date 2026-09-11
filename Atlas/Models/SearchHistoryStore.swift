import Foundation
import SwiftData

@MainActor
enum SearchHistoryStore {
    /// Only the recent-search presentation is limited to 15. Retained queries
    /// continue to inform recommendations and sync until explicitly deleted.
    static let limit = 15

    static func recent(_ entries: [SearchEntry]) -> [SearchEntry] {
        Array(
            entries.sorted {
                if $0.lastSearchedAt != $1.lastSearchedAt { return $0.lastSearchedAt > $1.lastSearchedAt }
                return $0.query < $1.query
            }.prefix(limit))
    }

    /// Kept for existing callers. A presentation limit never deletes user data.
    static func prune(in context: ModelContext) {}

    @discardableResult
    static func record(_ raw: String, in context: ModelContext, now: Date = .now) -> SearchEntry? {
        guard let display = SearchEntry.displayText(raw) else { return nil }
        let key = SearchEntry.normalize(display)
        do {
            try PersistedMetadataPolicy.requireIdentifier(key, field: "search.query")
            try PersistedMetadataPolicy.requireText(display, field: "search.displayQuery")
            try PersistedMetadataPolicy.requireFiniteDate(now, field: "search.lastSearchedAt")
            var descriptor = FetchDescriptor<SearchEntry>(predicate: #Predicate { $0.query == key })
            descriptor.fetchLimit = 1
            let existing = try context.fetch(descriptor).first
            var evictions: [SearchEntry] = []
            if existing == nil {
                guard PersistedMetadataCapacity.allowsAddingTopLevelRecord(in: context) else { return nil }
                // At the retained-query cap, the least recently used query makes room
                // (a journaled deletion, so other devices drop it too) rather than the
                // new search silently vanishing.
                let overflow =
                    try context.fetchCount(FetchDescriptor<SearchEntry>())
                    - PersistedMetadataPolicy.maximumSearches + 1
                if overflow > 0 {
                    var oldest = FetchDescriptor<SearchEntry>(sortBy: [SortDescriptor(\.lastSearchedAt)])
                    oldest.fetchLimit = overflow
                    evictions = try context.fetch(oldest)
                }
            }
            let entry = existing ?? SearchEntry(query: key, displayQuery: display, lastSearchedAt: now)
            try LibrarySyncJournal.transaction(in: context, captureChanges: false) {
                for evicted in evictions {
                    try LibraryDeletionJournal.record(kind: .search, entityID: evicted.query, in: context)
                    context.delete(evicted)
                }
                if existing != nil {
                    entry.incrementCount()
                    entry.lastSearchedAt = now
                    entry.displayQuery = display
                } else {
                    context.insert(entry)
                }
                try LibrarySyncJournal.captureSearch(query: key, isNew: existing == nil, in: context)
            }
            return entry
        } catch {
            return nil
        }
    }

    @discardableResult
    static func delete(_ entry: SearchEntry, in context: ModelContext) -> Bool {
        do {
            try LibrarySyncJournal.transaction(in: context, captureChanges: false) {
                try LibraryDeletionJournal.record(
                    kind: .search, entityID: entry.query, in: context)
                context.delete(entry)
            }
            return true
        } catch { return false }
    }

    /// A clear covers retained searches too, even when the caller only has a
    /// recent-search projection. The category barrier fences offline activity.
    @discardableResult
    static func clear(_ entries: [SearchEntry], in context: ModelContext) -> Bool {
        clear(in: context)
    }

    @discardableResult
    static func clear(in context: ModelContext) -> Bool {
        do {
            try LibrarySyncJournal.transaction(in: context, captureChanges: false) {
                try LibrarySyncJournal.clear(kind: .search, in: context)
            }
            return true
        } catch { return false }
    }
}
