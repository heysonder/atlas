import Foundation
import SwiftData

@MainActor
enum SearchHistoryStore {
    @discardableResult
    static func record(_ raw: String, in context: ModelContext, now: Date = .now) -> SearchEntry? {
        guard let display = SearchEntry.displayText(raw) else { return nil }
        let key = SearchEntry.normalize(display)
        guard !key.isEmpty else { return nil }

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

        let entry = SearchEntry(query: key, displayQuery: display, lastSearchedAt: now)
        context.insert(entry)
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
