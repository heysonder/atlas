import Foundation

/// Warms the shared URLCache with thumbnail images so `AsyncImage` (which also
/// uses URLSession.shared / URLCache.shared) renders them instantly instead of
/// fetching when the row scrolls on screen.
actor ThumbnailPrefetcher {
    static let shared = ThumbnailPrefetcher()

    private var inFlight: Set<String> = []
    private var queued: [URL] = []
    private var queuedKeys: Set<String> = []
    private var done: Set<String> = []
    private let session: URLSession = .shared
    private let maxConcurrent = 4
    private let doneLimit = 400

    /// Prefetch a batch of thumbnail URLs (deduplicated, capped concurrency).
    func prefetch(_ urls: [String?]) {
        for case let urlString? in urls {
            guard !done.contains(urlString), !inFlight.contains(urlString),
                  !queuedKeys.contains(urlString),
                  let url = URL(string: urlString) else { continue }
            queued.append(url)
            queuedKeys.insert(urlString)
        }
        drain()
    }

    private func drain() {
        while inFlight.count < maxConcurrent, !queued.isEmpty {
            let url = queued.removeFirst()
            let key = url.absoluteString
            queuedKeys.remove(key)
            guard !done.contains(key), !inFlight.contains(key) else { continue }
            inFlight.insert(key)
            Task { await self.load(url, key: key) }
        }
    }

    private func load(_ url: URL, key: String) async {
        defer {
            inFlight.remove(key)
            drain()
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad
        if let (_, response) = try? await session.data(for: request),
           Self.isSuccessful(response) {
            rememberDone(key)
        }
    }

    private func rememberDone(_ key: String) {
        done.insert(key)
        if done.count > doneLimit {
            done.remove(done.randomElement() ?? key)
        }
    }

    private static func isSuccessful(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse else { return true }
        return (200..<300).contains(http.statusCode)
    }
}
