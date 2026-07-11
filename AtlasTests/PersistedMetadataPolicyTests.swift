import SwiftData
import Testing

@testable import Atlas

@Test func persistedMetadataPolicyCountsUTF8BytesAtTheBoundary() throws {
    let exactIdentifier = String(repeating: "é", count: 256)
    let oversizedIdentifier = exactIdentifier + "é"

    try PersistedMetadataPolicy.requireIdentifier(exactIdentifier, field: "id")
    #expect(
        throws: PersistedMetadataPolicy.Violation.limitExceeded(
            field: "id", maximum: PersistedMetadataPolicy.maximumIdentifierBytes)
    ) {
        try PersistedMetadataPolicy.requireIdentifier(oversizedIdentifier, field: "id")
    }

    let exactText = String(repeating: "é", count: 2_048)
    try PersistedMetadataPolicy.requireText(exactText, field: "title")
    #expect(
        throws: PersistedMetadataPolicy.Violation.limitExceeded(
            field: "title", maximum: PersistedMetadataPolicy.maximumHumanTextBytes)
    ) {
        try PersistedMetadataPolicy.requireText(exactText + "é", field: "title")
    }
}

@Test func persistedMetadataPolicyChecksTimingTagsAndAggregateArithmetic() throws {
    try PersistedMetadataPolicy.requirePlaybackNumber(
        Double(PersistedMetadataPolicy.maximumPlaybackSeconds), field: "position")
    #expect(throws: PersistedMetadataPolicy.Violation.invalidValue(field: "position")) {
        try PersistedMetadataPolicy.requirePlaybackNumber(
            Double(PersistedMetadataPolicy.maximumPlaybackSeconds) + 1, field: "position")
    }
    #expect(throws: PersistedMetadataPolicy.Violation.invalidValue(field: "position")) {
        try PersistedMetadataPolicy.requirePlaybackNumber(.nan, field: "position")
    }

    let exactTags = Array(
        repeating: String(repeating: "a", count: 256),
        count: PersistedMetadataPolicy.maximumTags)
    try PersistedMetadataPolicy.requireTags(exactTags, field: "tags")
    #expect(
        throws: PersistedMetadataPolicy.Violation.limitExceeded(
            field: "tags", maximum: PersistedMetadataPolicy.maximumTags)
    ) {
        try PersistedMetadataPolicy.requireTags(exactTags + ["extra"], field: "tags")
    }
    #expect(
        throws: PersistedMetadataPolicy.Violation.limitExceeded(
            field: "tags[0]", maximum: PersistedMetadataPolicy.maximumTagBytes)
    ) {
        try PersistedMetadataPolicy.requireTags(
            [String(repeating: "a", count: PersistedMetadataPolicy.maximumTagBytes + 1)],
            field: "tags")
    }
    #expect(
        throws: PersistedMetadataPolicy.Violation.limitExceeded(
            field: "tags.bytes", maximum: PersistedMetadataPolicy.maximumAggregateTagBytes)
    ) {
        try PersistedMetadataPolicy.requireTags(
            Array(repeating: String(repeating: "a", count: 1_024), count: 33),
            field: "tags")
    }

    #expect(
        try PersistedMetadataPolicy.checkedSum(
            Int.max - 1, 1, maximum: Int.max, field: "records") == Int.max)
    #expect(
        throws: PersistedMetadataPolicy.Violation.limitExceeded(
            field: "records", maximum: Int.max)
    ) {
        try PersistedMetadataPolicy.checkedSum(
            Int.max, 1, maximum: Int.max, field: "records")
    }
}

@MainActor
@Test func liveStoresRejectUnexportableMetadataWithoutPartialRows() throws {
    let container = try makeTestContainer()
    let context = container.mainContext
    let oversizedID = String(repeating: "v", count: 513)
    let oversizedText = String(repeating: "t", count: 4_097)
    let oversizedURL = String(repeating: "u", count: 16_385)
    let oversizedTags = Array(repeating: "tag", count: 129)

    #expect(
        !PlaybackHistoryStore.record(
            videoID: "video", title: oversizedText, uploader: nil,
            thumbnailURL: nil, in: context))
    #expect(SearchHistoryStore.record(oversizedID, in: context) == nil)
    #expect(
        !SubscriptionStore.setSubscribed(
            true, channelID: "channel", name: "Creator",
            avatarURL: oversizedURL, in: context))
    #expect(
        !FeedbackStore.set(
            1, videoID: "video", title: "Title", uploader: nil,
            category: nil, tags: oversizedTags, in: context))
    #expect(
        PlaylistStore.addToFavorites(
            PlaylistVideoSnapshot(videoID: oversizedID, title: "Title"),
            in: context) == .missing)

    #expect(try context.fetch(FetchDescriptor<HistoryEntry>()).isEmpty)
    #expect(try context.fetch(FetchDescriptor<SearchEntry>()).isEmpty)
    #expect(try context.fetch(FetchDescriptor<SubscribedChannel>()).isEmpty)
    #expect(try context.fetch(FetchDescriptor<Feedback>()).isEmpty)
    #expect(try context.fetch(FetchDescriptor<Playlist>()).isEmpty)
    #expect(try context.fetch(FetchDescriptor<PlaylistVideo>()).isEmpty)

    context.insert(SubscribedChannel(channelID: oversizedID, name: "Legacy"))
    context.insert(Feedback(videoID: oversizedID, signal: 1, title: "Legacy"))
    #expect(
        SubscriptionStore.setSubscribed(
            false, channelID: oversizedID, name: nil, avatarURL: nil, in: context))
    #expect(
        FeedbackStore.set(
            0, videoID: oversizedID, title: "", uploader: nil,
            category: nil, tags: nil, in: context))
    #expect(try context.fetch(FetchDescriptor<SubscribedChannel>()).isEmpty)
    #expect(try context.fetch(FetchDescriptor<Feedback>()).isEmpty)
}
