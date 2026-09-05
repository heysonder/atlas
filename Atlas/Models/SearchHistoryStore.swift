import Foundation
import SwiftData

@MainActor
enum SearchHistoryStore {
    /// Recent searches kept; adding beyond this evicts the least recent.
    static let limit = 15

    /// Trims the history down to `limit`, least-recent first.
    static func prune(in context: ModelContext) {
        let descriptor = FetchDescriptor<SearchEntry>(
            sortBy: [SortDescriptor(\.lastSearchedAt, order: .reverse)])
        guard let entries = try? context.fetch(descriptor), entries.count > limit else { return }
        for entry in entries.dropFirst(limit) {
            context.delete(entry)
        }
    }

    @discardableResult
    static func record(_ raw: String, in context: ModelContext, now: Date = .now) -> SearchEntry? {
        guard let display = SearchEntry.displayText(raw) else { return nil }
        let key = SearchEntry.normalize(display)
        guard !key.isEmpty else { return nil }
        do {
            try PersistedMetadataPolicy.requireIdentifier(key, field: "search.query")
            try PersistedMetadataPolicy.requireText(display, field: "search.displayQuery")
            try PersistedMetadataPolicy.requireFiniteDate(now, field: "search.lastSearchedAt")
        } catch {
            return nil
        }

        var descriptor = FetchDescriptor<SearchEntry>(
            predicate: #Predicate { $0.query == key })
        descriptor.fetchLimit = 1

        do {
            if let existing = try context.fetch(descriptor).first {
                existing.incrementCount()
                existing.lastSearchedAt = now
                existing.displayQuery = display
                return existing
            }
        } catch {
            return nil
        }

        guard PersistedMetadataCapacity.allowsAddingTopLevelRecord(in: context) else { return nil }
        let entry = SearchEntry(query: key, displayQuery: display, lastSearchedAt: now)
        context.insert(entry)
        prune(in: context)
        return entry
    }

    static func delete(_ entry: SearchEntry, in context: ModelContext) {
        context.delete(entry)
    }

    static func clear(_ entries: [SearchEntry], in context: ModelContext) {
        for entry in entries {
            context.delete(entry)
        }
    }
}
