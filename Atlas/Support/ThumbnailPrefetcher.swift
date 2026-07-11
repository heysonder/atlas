import Foundation
import PipedKit

/// Warms the policy-aware URL cache so rows render without waiting on scroll.
actor ThumbnailPrefetcher {
    static let shared = ThumbnailPrefetcher()

    private var inFlight: Set<String> = []
    private struct Queued: Sendable {
        let url: URL
        let client: PolicyHTTPClient
        let key: String
    }
    private var queued: [Queued] = []
    private var queuedKeys: Set<String> = []
    private var done: Set<String> = []
    private var tasks: [String: Task<Void, Never>] = [:]
    private var activeGeneration: UInt64?
    private let maxConcurrent = 4
    private let doneLimit = 400

    /// Prefetch a batch of thumbnail URLs (deduplicated, capped concurrency).
    func prefetch(_ urls: [String?], client: PolicyHTTPClient, generation: UInt64) {
        guard activate(generation: generation) else { return }
        let namespace = "instance:\(generation)"
        for case let urlString? in urls {
            let key = namespace + "|" + urlString
            guard !done.contains(key), !inFlight.contains(key),
                !queuedKeys.contains(key),
                let url = URL(string: urlString)
            else { continue }
            queued.append(Queued(url: url, client: client, key: key))
            queuedKeys.insert(key)
        }
        drain()
    }

    /// Cancels queued and active work when the selected Piped instance changes.
    /// The next namespace remains active so a late completion from the previous
    /// generation cannot resume its queue.
    func reset(generation: UInt64) {
        _ = activate(generation: generation)
    }

    /// Returns false for a call that was queued by an older instance generation.
    /// This prevents a late actor hop from reversing a newer reset.
    private func activate(generation: UInt64) -> Bool {
        if let activeGeneration, generation < activeGeneration { return false }
        guard activeGeneration != generation else { return true }
        activeGeneration = generation
        queued.removeAll(keepingCapacity: true)
        queuedKeys.removeAll(keepingCapacity: true)
        for task in tasks.values { task.cancel() }
        done.removeAll(keepingCapacity: true)
        return true
    }

    private func drain() {
        while inFlight.count < maxConcurrent, !queued.isEmpty {
            let request = queued.removeFirst()
            let key = request.key
            queuedKeys.remove(key)
            guard !done.contains(key), !inFlight.contains(key) else { continue }
            inFlight.insert(key)
            tasks[key] = Task { await self.load(request) }
        }
    }

    private func load(_ queued: Queued) async {
        let key = queued.key
        defer {
            inFlight.remove(key)
            tasks[key] = nil
            drain()
        }
        guard !Task.isCancelled else { return }
        var request = URLRequest(url: queued.url)
        request.cachePolicy = .returnCacheDataElseLoad
        if let (_, response) = try? await queued.client.data(for: request),
            !Task.isCancelled,
            Self.isSuccessful(response)
        {
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
