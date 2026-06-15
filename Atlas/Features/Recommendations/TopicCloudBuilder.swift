import Foundation

struct TopicCloudEntry: Identifiable, Hashable {
    enum Polarity: String, Hashable {
        case positive
        case negative
    }

    let term: String
    let weight: Double
    let polarity: Polarity

    var id: String { "\(polarity.rawValue):\(term)" }
}

struct TopicCloudSummary {
    let positive: [TopicCloudEntry]
    let negative: [TopicCloudEntry]
}

enum TopicCloudBuilder {
    private static let stopWords: Set<String> = [
        "about", "after", "again", "against", "also", "another", "around", "because",
        "before", "being", "between", "could", "does", "doing", "down", "during",
        "every", "first", "from", "gets", "have", "into", "just", "last", "like",
        "live", "made", "make", "makes", "more", "most", "much", "need", "new",
        "official", "only", "over", "part", "really", "short", "shorts", "should",
        "show", "stream", "than", "that", "their", "them", "then", "there", "these",
        "they", "thing", "things", "this", "through", "today", "video", "videos",
        "watch", "what", "when", "where", "which", "while", "with", "would", "your"
    ]

    static func make(history: [HistoryEntry],
                     feedback: [Feedback],
                     saved: [PlaylistVideo],
                     searches: [SearchEntry],
                     cachedSignals: [VideoSignalCacheEntry],
                     now: Date = .now,
                     limit: Int = 48) -> TopicCloudSummary {
        var positive: [String: Double] = [:]
        var negative: [String: Double] = [:]
        let cacheByID = Dictionary(uniqueKeysWithValues: cachedSignals.map { ($0.videoID, $0) })

        func add(_ text: String?, weight: Double, to bucket: inout [String: Double]) {
            guard weight > 0, let text else { return }
            for token in tokens(text) {
                bucket[token, default: 0] += weight
            }
        }

        func add(_ tags: [String]?, weight: Double, to bucket: inout [String: Double]) {
            guard let tags else { return }
            for tag in tags {
                add(tag, weight: weight, to: &bucket)
            }
        }

        func addCachedSignals(for videoID: String, weight: Double, to bucket: inout [String: Double]) {
            guard let cached = cacheByID[videoID] else { return }
            add(cached.category, weight: weight * 0.85, to: &bucket)
            add(cached.tags, weight: weight, to: &bucket)
        }

        for entry in history.prefix(200) {
            let ageDays = max(0, now.timeIntervalSince(entry.watchedAt) / 86_400)
            let recency = max(0.2, 1 - ageDays / 90)
            let weight = RecommendationEngine.watchWeight(
                position: entry.positionSeconds,
                duration: entry.durationSeconds) * recency
            add(entry.title, weight: weight, to: &positive)
            add(entry.uploader, weight: weight * 0.35, to: &positive)
            addCachedSignals(for: entry.videoID, weight: weight * 0.8, to: &positive)
        }

        for video in saved.prefix(100) {
            let ageDays = max(0, now.timeIntervalSince(video.addedAt) / 86_400)
            let recency = max(0.35, 1 - ageDays / 180)
            let weight = 2.25 * recency
            add(video.title, weight: weight, to: &positive)
            add(video.uploader, weight: weight * 0.4, to: &positive)
            addCachedSignals(for: video.videoID, weight: weight * 0.8, to: &positive)
        }

        for search in searches.prefix(60) {
            let signal = SearchSignal(query: search.query, count: search.count,
                                      lastSearchedAt: search.lastSearchedAt, now: now)
            add(search.query, weight: signal.weight * 1.4, to: &positive)
        }

        for item in feedback {
            let isPositive = item.signal > 0
            let baseWeight = isPositive ? 4.0 : 3.5
            if isPositive {
                add(item.title, weight: baseWeight, to: &positive)
                add(item.uploader, weight: baseWeight * 0.35, to: &positive)
                add(item.category, weight: baseWeight * 0.85, to: &positive)
                add(item.tags, weight: baseWeight, to: &positive)
                addCachedSignals(for: item.videoID, weight: baseWeight * 0.75, to: &positive)
            } else {
                add(item.title, weight: baseWeight, to: &negative)
                add(item.uploader, weight: baseWeight * 0.35, to: &negative)
                add(item.category, weight: baseWeight * 0.85, to: &negative)
                add(item.tags, weight: baseWeight, to: &negative)
                addCachedSignals(for: item.videoID, weight: baseWeight * 0.75, to: &negative)
            }
        }

        return TopicCloudSummary(
            positive: entries(from: positive, dampenedBy: negative,
                              polarity: .positive, limit: limit),
            negative: entries(from: negative, dampenedBy: positive,
                              polarity: .negative, limit: min(24, limit)))
    }

    private static func entries(from primary: [String: Double],
                                dampenedBy opposing: [String: Double],
                                polarity: TopicCloudEntry.Polarity,
                                limit: Int) -> [TopicCloudEntry] {
        primary
            .map { term, weight in
                TopicCloudEntry(term: term,
                                weight: weight - (opposing[term] ?? 0) * 0.5,
                                polarity: polarity)
            }
            .filter { $0.weight >= 0.75 }
            .sorted {
                if $0.weight == $1.weight { return $0.term < $1.term }
                return $0.weight > $1.weight
            }
            .prefix(limit)
            .map { $0 }
    }

    private static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { token in
                guard token.count > 2 || token == "ai" else { return false }
                guard !stopWords.contains(token) else { return false }
                guard !token.allSatisfy(\.isNumber) else { return false }
                return true
            }
    }
}
