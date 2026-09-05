import Testing

@testable import Atlas

@Test func channelRefreshRejectsAnOlderPageResponse() throws {
    var requests = ChannelRequestState()
    let oldLoad = requests.beginLoad()
    requests.finishLoad(oldLoad)
    let startedOldPage = requests.beginPage()
    let oldPage = try #require(startedOldPage)
    let refreshedLoad = requests.beginLoad()
    #expect(!requests.accepts(load: oldLoad, page: oldPage))
    #expect(requests.accepts(load: refreshedLoad))
}

@Test func oldChannelPageFailureCannotStopNewPagination() throws {
    var requests = ChannelRequestState()
    let oldLoad = requests.beginLoad()
    requests.finishLoad(oldLoad)
    let startedOldPage = requests.beginPage()
    let oldPage = try #require(startedOldPage)
    let newLoad = requests.beginLoad()
    #expect(requests.beginPage() == nil)
    requests.finishLoad(oldLoad)
    #expect(requests.isReloading)
    requests.finishLoad(newLoad)
    let startedNewPage = requests.beginPage()
    let newPage = try #require(startedNewPage)

    // An old instance fails after the replacement instance starts its page.
    requests.finishPage(oldPage, error: "Old instance timed out")
    #expect(requests.paginationError == nil)
    #expect(requests.isLoadingPage)
    #expect(requests.beginPage() == nil)
    #expect(requests.accepts(load: newLoad, page: newPage))

    requests.finishPage(newPage, error: "New instance timed out")
    #expect(!requests.isLoadingPage)
    #expect(requests.paginationError == "New instance timed out")
    // Late cleanup must also preserve an error from the current request.
    requests.finishPage(oldPage)
    #expect(requests.paginationError == "New instance timed out")
    requests.retryPage()
    #expect(requests.beginPage() != nil)
}
