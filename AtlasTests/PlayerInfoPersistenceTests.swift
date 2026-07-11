import Testing

@testable import Atlas

@Test func playerInfoRetainsSubscriptionStateWhenPersistenceRejectsMutation() {
    var receivedRequest: Bool?

    let retainedState = PlayerInfoPersistence.retainedValue(
        current: false,
        requested: true
    ) { requested in
        receivedRequest = requested
        return false
    }

    #expect(receivedRequest == true)
    #expect(retainedState == false)
}

@Test func playerInfoRetainsFeedbackStateWhenPersistenceRejectsMutation() {
    var receivedRequest: Int?

    let retainedState = PlayerInfoPersistence.retainedValue(
        current: -1,
        requested: 1
    ) { requested in
        receivedRequest = requested
        return false
    }

    #expect(receivedRequest == 1)
    #expect(retainedState == -1)
}

@Test func playerInfoAdoptsStateWhenPersistenceAcceptsMutation() {
    let subscribed = PlayerInfoPersistence.retainedValue(
        current: false,
        requested: true,
        persist: { _ in true })
    let feedback = PlayerInfoPersistence.retainedValue(
        current: -1,
        requested: 0,
        persist: { _ in true })

    #expect(subscribed)
    #expect(feedback == 0)
}
