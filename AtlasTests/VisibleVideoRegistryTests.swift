import Testing

@testable import Atlas

@MainActor
@Test func visibleRegistryBoundsFieldsAndEvictsByAggregateBytes() {
    let registry = VisibleVideoRegistry(cap: 10, byteCap: 12_000)
    registry.record(
        VideoEntity(
            id: "first",
            title: String(repeating: "a", count: 8_000),
            uploader: String(repeating: "u", count: 2_000),
            thumbnail: String(repeating: "x", count: 5_000)))

    let first = registry.entity(for: "first")
    #expect(first?.title.utf8.count == VisibleVideoRegistry.maximumTitleBytes)
    #expect(first?.uploader?.utf8.count == VisibleVideoRegistry.maximumUploaderBytes)
    #expect(first?.thumbnail == nil)

    registry.record(
        VideoEntity(
            id: "second", title: String(repeating: "b", count: 4_000),
            uploader: nil, thumbnail: nil))
    registry.record(
        VideoEntity(
            id: "third", title: String(repeating: "c", count: 4_000),
            uploader: nil, thumbnail: nil))
    #expect(registry.entity(for: "first") == nil)
    #expect(registry.entity(for: "third") != nil)

    registry.record(
        VideoEntity(
            id: String(repeating: "i", count: VisibleVideoRegistry.maximumIDBytes + 1),
            title: "rejected", uploader: nil, thumbnail: nil))
    #expect(registry.entity(for: String(repeating: "i", count: 257)) == nil)
}
