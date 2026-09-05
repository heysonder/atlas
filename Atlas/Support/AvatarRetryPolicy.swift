import Foundation

/// Bounded retry budget for channel avatars that fail to load.
///
/// A failed avatar retries a couple of times while the row is still on
/// screen (short backoff), and every URL carries a global failure budget so a
/// dead image never turns feed scrolling into a request storm against the
/// Piped instance. Once the budget is spent the URL is left alone until the
/// cooldown elapses, after which a single fresh attempt is allowed again.
actor AvatarRetryPolicy {
    static let shared = AvatarRetryPolicy()

    struct Configuration: Sendable {
        /// Extra attempts a single on-screen view makes after its first failure.
        var inViewRetries = 2
        /// Delay before the n-th in-view retry (n = 0, 1, ...). Kept short so a
        /// transient hiccup recovers before the user scrolls on.
        var inViewDelays: [Duration] = [.seconds(1.5), .seconds(4)]
        /// Total failed attempts allowed per URL before it goes cold.
        var failureBudget = 4
        /// How long a cold URL stays untouched before one fresh attempt is allowed.
        var cooldown: TimeInterval = 10 * 60
    }

    private struct Record {
        var failures = 0
        var lastFailure: TimeInterval = 0
    }

    let configuration: Configuration
    private var records: [String: Record] = [:]
    private let now: @Sendable () -> TimeInterval

    init(
        configuration: Configuration = Configuration(),
        now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }
    ) {
        self.configuration = configuration
        self.now = now
    }

    /// Whether a load for `url` may hit the network right now.
    func shouldAttempt(_ url: String) -> Bool {
        guard let record = records[url] else { return true }
        guard record.failures >= configuration.failureBudget else { return true }
        if now() - record.lastFailure >= configuration.cooldown {
            // One fresh attempt after cooling off; a failure re-arms the cooldown.
            records[url] = Record(failures: configuration.failureBudget - 1, lastFailure: record.lastFailure)
            return true
        }
        return false
    }

    func recordFailure(_ url: String) {
        var record = records[url] ?? Record()
        record.failures += 1
        record.lastFailure = now()
        records[url] = record
    }

    func recordSuccess(_ url: String) {
        records.removeValue(forKey: url)
    }

    /// Delay before in-view retry number `attempt` (0-based), or nil once the
    /// per-view retries are exhausted.
    nonisolated func inViewDelay(forRetry attempt: Int) -> Duration? {
        guard attempt < configuration.inViewRetries else { return nil }
        let delays = configuration.inViewDelays
        guard !delays.isEmpty else { return .seconds(2) }
        return delays[min(attempt, delays.count - 1)]
    }

    func failureCount(_ url: String) -> Int {
        records[url]?.failures ?? 0
    }
}
