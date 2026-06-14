import Foundation

/// Warms the shared URLCache with thumbnail images so `AsyncImage` (which also
/// uses URLSession.shared / URLCache.shared) renders them instantly instead of
/// fetching when the row scrolls on screen.
actor ThumbnailPrefetcher {
    static let shared = ThumbnailPrefetcher()

    private var inFlight: Set<String> = []
    private var done: Set<String> = []
    private let session: URLSession = .shared

    /// Prefetch a batch of thumbnail URLs (deduplicated, capped concurrency).
    func prefetch(_ urls: [String?]) {
        for case let urlString? in urls {
            guard !done.contains(urlString), !inFlight.contains(urlString),
                  let url = URL(string: urlString) else { continue }
            inFlight.insert(urlString)
            Task { await self.load(url, key: urlString) }
        }
    }

    private func load(_ url: URL, key: String) async {
        defer { inFlight.remove(key) }
        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad
        _ = try? await session.data(for: request)
        done.insert(key)
    }
}
