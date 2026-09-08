import Foundation
import NaturalLanguage

/// Apple's on-device transformer sentence embedding (`NLContextualEmbedding`),
/// used by the refine pass for taste/candidate similarity. Static word-vector
/// means can't tell "Apple event" from "apple pie"; the contextual model can.
///
/// Assets may need a one-time system download and the model load itself isn't
/// instant, so everything here is best-effort: `warmUp()` starts the work in
/// the background, and until `loadedModel()` returns non-nil the ranking pass
/// keeps using the word-embedding fallback. The two vector spaces are never
/// mixed within a pass.
nonisolated enum ContextualEmbedder {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var model: NLContextualEmbedding?
        var loadInFlight = false
        /// NSCache is itself thread-safe; it lives here so the shared instance
        /// passes strict-concurrency checking.
        let vectorCache: NSCache<NSString, NSArray> = {
            let cache = NSCache<NSString, NSArray>()
            cache.countLimit = 4_096
            return cache
        }()
    }

    private static let state = State()
    /// `NLContextualEmbedding` makes no thread-safety promises; the coarse and
    /// refine passes can overlap, so inference is serialized.
    private static let inferenceLock = NSLock()

    /// The loaded model, or nil while assets/loading are still pending.
    static func loadedModel() -> NLContextualEmbedding? {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.model
    }

    /// Kick off asset download + model load once; cheap no-op while a load is
    /// in flight or after one succeeded. A failed attempt (e.g. offline asset
    /// download) clears the flag so a later pass retries.
    static func warmUp() {
        state.lock.lock()
        let shouldLoad = state.model == nil && !state.loadInFlight
        if shouldLoad { state.loadInFlight = true }
        state.lock.unlock()
        guard shouldLoad else { return }

        Task.detached(priority: .utility) {
            finishLoad(await loadModel())
        }
    }

    private static func finishLoad(_ model: NLContextualEmbedding?) {
        state.lock.lock()
        state.model = model
        state.loadInFlight = false
        state.lock.unlock()
    }

    private static func loadModel() async -> NLContextualEmbedding? {
        guard let embedding = NLContextualEmbedding(language: .english) else { return nil }
        if !embedding.hasAvailableAssets {
            let available = await withCheckedContinuation { continuation in
                embedding.requestAssets { result, _ in
                    continuation.resume(returning: result == .available)
                }
            }
            guard available else { return nil }
        }
        do {
            try embedding.load()
            return embedding
        } catch {
            return nil
        }
    }

    /// Mean-pooled token vectors for `text`. Cached: the refine pass re-embeds
    /// the same taste docs and shortlist titles on every refresh.
    static func vector(for text: String, model: NLContextualEmbedding) -> [Double]? {
        let text = RecommendationWorkBudget.field(text)
        guard !text.isEmpty else { return nil }
        if let cached = state.vectorCache.object(forKey: text as NSString) as? [Double] {
            return cached
        }

        inferenceLock.lock()
        let result = try? model.embeddingResult(for: text, language: .english)
        inferenceLock.unlock()
        guard let result else { return nil }

        var sum: [Double] = []
        var count = 0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
            if sum.isEmpty {
                sum = vector
            } else if sum.count == vector.count {
                for index in vector.indices { sum[index] += vector[index] }
            }
            count += 1
            return true
        }
        guard count > 0, !sum.isEmpty else { return nil }
        let mean = sum.map { $0 / Double(count) }
        state.vectorCache.setObject(mean as NSArray, forKey: text as NSString)
        return mean
    }
}
