import Foundation
import SwiftData
import Testing

@testable import Atlas

@MainActor
@Test func searchEntryClampsCounts() {
    let empty = SearchEntry(query: "swiftui", count: 0)
    let excessive = SearchEntry(query: "swiftui", count: SearchEntry.maximumCount + 1)

    #expect(empty.count == 1)
    #expect(excessive.count == SearchEntry.maximumCount)
    excessive.incrementCount()
    #expect(excessive.count == SearchEntry.maximumCount)
}

@MainActor
@Test func searchHistoryStoreUpsertsNormalizedQueries() throws {
    let container = try makeTestContainer()
    let context = container.mainContext
    let first = Date(timeIntervalSince1970: 100)
    let second = Date(timeIntervalSince1970: 200)

    SearchHistoryStore.record(" SwiftUI ", in: context, now: first)
    SearchHistoryStore.record("SWIFTUI", in: context, now: second)

    let entries = try context.fetch(FetchDescriptor<SearchEntry>())
    #expect(entries.count == 1)
    #expect(entries.first?.query == "swiftui")
    #expect(entries.first?.displayTitle == "SWIFTUI")
    #expect(entries.first?.count == 2)
    #expect(entries.first?.lastSearchedAt == second)
}
