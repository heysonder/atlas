import SwiftData
import Testing

@testable import Atlas

@MainActor
@Test func subscriptionStoreTogglesChannelRows() throws {
    let container = try makeTestContainer()
    let context = container.mainContext

    #expect(!SubscriptionStore.isSubscribed("c1", in: context))
    SubscriptionStore.setSubscribed(
        true, channelID: "c1",
        name: "Creator", avatarURL: "avatar", in: context)
    #expect(SubscriptionStore.isSubscribed("c1", in: context))
    SubscriptionStore.setSubscribed(
        false, channelID: "c1",
        name: nil, avatarURL: nil, in: context)
    #expect(!SubscriptionStore.isSubscribed("c1", in: context))
}
