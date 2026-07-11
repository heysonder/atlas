import Foundation
import PipedKit
import Testing

@testable import Atlas

@Test func streamItemIdentityKeepsStableFirstOccurrences() throws {
    let firstA = try streamItem(id: "a", title: "First A")
    let firstB = try streamItem(id: "b", title: "First B")
    let duplicateA = try streamItem(id: "a", title: "Duplicate A")

    let unique = StreamItemIdentity.firstOccurrences(
        in: [firstA, firstB, duplicateA])

    #expect(unique.map(\.id) == ["a", "b"])
    #expect(unique.map(\.title) == ["First A", "First B"])
}

@Test func streamItemIdentityUpdatesPaginationSeenSetWithinResponse() throws {
    let loaded = try streamItem(id: "loaded", title: "Already loaded")
    let firstNew = try streamItem(id: "new", title: "First new")
    let duplicateNew = try streamItem(id: "new", title: "Duplicate new")
    var seenIDs = Set([loaded.id])

    let unique = StreamItemIdentity.firstOccurrences(
        in: [loaded, firstNew, duplicateNew],
        seenIDs: &seenIDs)

    #expect(unique.map(\.id) == ["new"])
    #expect(unique.map(\.title) == ["First new"])
    #expect(seenIDs == Set(["loaded", "new"]))
}

@Test func groupedVideoListRejectsDuplicateIdentitiesAtItsBoundary() throws {
    let first = try streamItem(id: "video", title: "First")
    let duplicate = try streamItem(id: "video", title: "Duplicate")

    let list = GroupedVideoList(items: [first, duplicate]) { _ in }

    #expect(list.items.map(\.id) == ["video"])
    #expect(list.items.map(\.title) == ["First"])
}

private func streamItem(id: String, title: String) throws -> StreamItem {
    let data = """
        {
          "url": "/watch?v=\(id)",
          "type": "stream",
          "title": "\(title)"
        }
        """.data(using: .utf8)!
    return try JSONDecoder().decode(StreamItem.self, from: data)
}
