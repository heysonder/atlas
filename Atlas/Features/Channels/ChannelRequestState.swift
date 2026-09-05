import Foundation

/// Identifies the reload and page allowed to update a channel screen. A new
/// reload invalidates both successful and failed completions from older work.
struct ChannelRequestState {
    private(set) var loadID = UUID()
    private(set) var pageID: UUID?
    private(set) var isReloading = false
    private(set) var paginationError: String?

    var isLoadingPage: Bool { pageID != nil }

    mutating func beginLoad() -> UUID {
        loadID = UUID()
        isReloading = true
        pageID = nil
        paginationError = nil
        return loadID
    }

    mutating func finishLoad(_ id: UUID) {
        guard loadID == id else { return }
        isReloading = false
    }

    mutating func beginPage() -> UUID? {
        guard !isReloading, pageID == nil, paginationError == nil else { return nil }
        let id = UUID()
        pageID = id
        return id
    }

    func accepts(load: UUID, page: UUID? = nil) -> Bool {
        load == loadID && (page == nil || page == pageID)
    }

    mutating func finishPage(_ id: UUID, error: String? = nil) {
        guard pageID == id else { return }
        pageID = nil
        paginationError = error
    }

    mutating func retryPage() {
        paginationError = nil
    }
}
