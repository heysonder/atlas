import Foundation
import NaturalLanguage
import PipedKit

/// Per-video signals fetched from `/streams` to sharpen ranking: YouTube's own
/// category label ("News & politics", "Science & technology") and the creator's
/// tags — clean topical keywords with none of a description's ad/affiliate copy.
struct VideoSignals: Sendable {
    let category: String?
    let tags: [String]
}

/// A value-type snapshot of a `Feedback` row for the ranking functions: a
/// thumbs-up (+1) or thumbs-down (−1) plus the video's signature.
struct FeedbackSignal: Sendable {
    let signal: Int
    let title: String
    let uploader: String?
    let category: String?
    let tags: [String]
}

/// Shared candidate generation + the two ranking strategies.
@MainActor
struct RecommendationEngine {
    let app: AppModel

    /// Gather related videos from the user's recent watches, with a frequency
    /// count (how many source videos pointed at each candidate).
    func candidates(from recent: [HistoryEntry], excluding watched: Set<String>)
    async -> (items: [StreamItem], frequency: [String: Int]) {
        var frequency: [String: Int] = [:]
        var byID: [String: StreamItem] = [:]
        for entry in recent {
            let related = (try? await app.resolveStream(entry.videoID))?.relatedStreams ?? []
            for item in related where item.isVideo {
                guard let id = item.videoID, !watched.contains(id) else { continue }
                frequency[id, default: 0] += 1
                if byID[id] == nil { byID[id] = item }
            }
        }
        return (Array(byID.values), frequency)
    }

    // MARK: Per-video enrichment (YouTube category + tags)

    /// Re-rank a shortlist using YouTube's own category + tags, fetched per video.
    /// This is what hard-buries News & politics for an all-tech watcher and folds
    /// clean creator tags into the topic match. Runs after the instant on-device
    /// pass so the user sees results immediately, then an upgrade once it returns.
    func refineWithSignals(_ shortlist: [StreamItem], history: [HistoryEntry],
                           feedback: [FeedbackSignal] = []) async -> [StreamItem] {
        let signals = await fetchSignals(shortlist)
        return Self.rankByTopic(shortlist, history: history,
                                feedback: feedback, enrichment: signals)
    }

    /// Fetch `/streams` for the shortlist with bounded concurrency, so we never
    /// fire more than `cap` extractions at the instance at once. Cached + de-duped
    /// by `resolveStream`, so repeat refreshes are cheap.
    private func fetchSignals(_ items: [StreamItem]) async -> [String: VideoSignals] {
        let ids = items.compactMap(\.videoID)
        guard !ids.isEmpty else { return [:] }
        let cap = 8   // concurrent extractions per batch — tunable knob
        var out: [String: VideoSignals] = [:]
        for start in stride(from: 0, to: ids.count, by: cap) {
            // Kick off the batch together; since resolveStream awaits the network,
            // these main-actor tasks overlap their I/O waits, then we collect them.
            let tasks = ids[start..<min(start + cap, ids.count)].map { id in
                Task { @MainActor () -> (String, VideoSignals)? in
                    guard let d = try? await app.resolveStream(id) else { return nil }
                    return (id, VideoSignals(category: d.category, tags: d.tags ?? []))
                }
            }
            for task in tasks {
                if let (id, sig) = await task.value { out[id] = sig }
            }
        }
        return out
    }

    // MARK: Strategy A — heuristic

    static func rankRelated(_ items: [StreamItem], frequency: [String: Int],
                            history: [HistoryEntry]) -> [StreamItem] {
        // Channel affinity: how much you watch each channel.
        var affinity: [String: Double] = [:]
        for entry in history {
            if let u = entry.uploader { affinity[u, default: 0] += 1 }
        }
        let maxAff = max(affinity.values.max() ?? 1, 1)
        let now = Date().timeIntervalSince1970

        func freshness(_ uploaded: Int64?) -> Double {
            guard let uploaded, uploaded > 0 else { return 0 }
            let ageDays = (now - Double(uploaded) / 1000) / 86_400
            return max(0, 1 - ageDays / 60)   // decays over ~2 months
        }
        func score(_ item: StreamItem) -> Double {
            let freq = Double(frequency[item.videoID ?? ""] ?? 0)
            let aff = (affinity[item.uploaderName ?? ""] ?? 0) / maxAff
            return freq * 2.0 + aff * 1.5 + freshness(item.uploaded) * 0.5
        }
        return items.sorted { score($0) > score($1) }
    }

    // MARK: Strategy B — on-device semantic

    static func rankByTopic(_ items: [StreamItem], history: [HistoryEntry],
                            feedback: [FeedbackSignal] = [],
                            enrichment: [String: VideoSignals] = [:]) -> [StreamItem] {
        guard let embedding = NLEmbedding.wordEmbedding(for: .english) else { return items }

        // Only pure grammar words are dropped outright. Topical-but-common words
        // ("new", "best", "review") are KEPT — IDF below down-weights whatever turns
        // out to be ubiquitous in your actual pool, instead of guessing a blocklist.
        let stop: Set<String> = [
            "the","and","for","you","your","with","this","that","from","but","not",
            "are","was","has","have","had","its","our","they","them","then","than",
            "when","who","all","what","why","how","can","will","just","out","now","get"
        ]

        func tokens(_ text: String) -> [String] {
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 2 && !stop.contains($0) }
        }

        // The channel name is the strongest topic signal we have ("Veritasium",
        // "Fireship", "ThePrimeagen" *are* the topic) and survives when a title is
        // all jargon/proper-nouns the embedding can't see — so fold it into the text.
        func docTokens(title: String, channel: String?) -> [String] {
            tokens(channel.map { "\(title) \($0)" } ?? title)
        }

        func cosine(_ a: [Double], _ b: [Double]) -> Double {
            guard a.count == b.count else { return 0 }
            var dot = 0.0, na = 0.0, nb = 0.0
            for i in a.indices { dot += a[i]*b[i]; na += a[i]*a[i]; nb += b[i]*b[i] }
            let denom = (na.squareRoot() * nb.squareRoot())
            return denom == 0 ? 0 : dot / denom
        }

        // Plain (un-weighted) mean vector — used for category classification, where
        // IDF would be counterproductive: it'd suppress the very category words (like
        // "war") that are common in a news-heavy candidate pool.
        func meanVector(_ doc: [String]) -> [Double]? {
            var sum: [Double] = []
            var n = 0
            for w in doc {
                guard let v = embedding.vector(for: w) else { continue }
                if sum.isEmpty { sum = v } else { for i in v.indices { sum[i] += v[i] } }
                n += 1
            }
            guard n > 0 else { return nil }
            return sum.map { $0 / Double(n) }
        }

        // Zero-shot topic categories: each is a prototype vector built from seed
        // words; a video is assigned to its nearest prototype. Splitting politics
        // from war matters — a "Trump phone" review may brush politics, but it's
        // nowhere near "war", so Iran/Ukraine content still gets gated below.
        let categorySeeds: [(String, [String])] = [
            ("tech", ["technology","software","hardware","gadget","computer","programming","developer","app","phone","laptop","processor","coding","startup","silicon"]),
            ("science", ["science","physics","chemistry","biology","space","astronomy","research","engineering","mathematics"]),
            ("politics", ["politics","election","president","government","senate","congress","policy","campaign","vote","democrat","republican"]),
            ("war", ["war","military","army","troops","missile","invasion","conflict","weapon","soldier","strike","defense","combat"]),
            ("news", ["news","breaking","report","headline","coverage","reporter","correspondent"]),
            ("finance", ["finance","stocks","market","economy","investing","crypto","trading","inflation"]),
            ("gaming", ["gaming","gameplay","game","esports","speedrun","multiplayer"]),
            ("entertainment", ["movie","film","celebrity","music","drama","trailer","song","album"]),
            ("sports", ["sports","football","basketball","soccer","baseball","league","championship"]),
            ("lifestyle", ["vlog","travel","food","cooking","fitness","fashion","lifestyle"]),
            ("education", ["history","documentary","explained","education","tutorial","lecture"]),
        ]
        let prototypes: [(name: String, vec: [Double])] = categorySeeds.compactMap { name, seeds in
            meanVector(seeds).map { (name, $0) }
        }
        func classify(_ doc: [String]) -> String? {
            guard let v = meanVector(doc), !prototypes.isEmpty else { return nil }
            return prototypes.max { cosine($0.vec, v) < cosine($1.vec, v) }?.name
        }

        // Taste = your watches from the last 7 days. With nearest-match scoring
        // (below) a bigger sample only helps, so widen it — but floor it when you've
        // had a quiet week, and cap it so the math stays cheap.
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        var recent = history.filter { $0.watchedAt >= cutoff }
        if recent.count < 15 { recent = Array(history.prefix(30)) }
        recent = Array(recent.prefix(60))

        let tasteDocs = recent.map { docTokens(title: $0.title, channel: $0.uploader) }
        // Fold creator tags (when enriched) into the candidate's text — clean topical
        // keywords that sharpen both the similarity and the category classification.
        let candDocs = items.map { item -> [String] in
            var t = docTokens(title: item.displayTitle, channel: item.uploaderName)
            if let tags = enrichment[item.videoID ?? ""]?.tags, !tags.isEmpty {
                t += tokens(tags.joined(separator: " "))
            }
            return t
        }

        // Explicit feedback. Likes act like strong watches (added to taste + your
        // category profile); dislikes drive an active penalty below.
        func feedbackDoc(_ f: FeedbackSignal) -> [String] {
            var t = docTokens(title: f.title, channel: f.uploader)
            if !f.tags.isEmpty { t += tokens(f.tags.joined(separator: " ")) }
            return t
        }
        let likedDocs = feedback.filter { $0.signal > 0 }.map(feedbackDoc)
        let dislikedDocs = feedback.filter { $0.signal < 0 }.map(feedbackDoc)

        // Your category distribution, learned from history + likes — no hardcoded
        // "news is bad". A candidate whose category you never watch gets gated; a
        // like on that category raises its share and lifts the gate.
        var catCount: [String: Int] = [:]
        var classified = 0
        for doc in tasteDocs + likedDocs { if let c = classify(doc) { catCount[c, default: 0] += 1; classified += 1 } }
        func categoryFit(_ doc: [String]) -> Double {
            guard classified > 0, let c = classify(doc) else { return 1 }  // no signal → don't gate
            return Double(catCount[c] ?? 0) / Double(classified)
        }
        // How much of your taste is itself news/politics/war — decides whether to
        // trust YouTube's "News & politics" label as grounds to bury a candidate.
        let newsShare = classified > 0
            ? Double((catCount["news"] ?? 0) + (catCount["politics"] ?? 0) + (catCount["war"] ?? 0)) / Double(classified)
            : 0
        // Categories you've explicitly thumbed-down — suppressed wholesale below.
        let dislikedCategories = Set(dislikedDocs.compactMap(classify))

        // IDF over the live pool: a word in every title (incl. "new"/"best"/"video")
        // earns weight ~1; a distinctive word earns more. Down-weight, never drop.
        var df: [String: Int] = [:]
        for doc in tasteDocs + candDocs + likedDocs + dislikedDocs { for w in Set(doc) { df[w, default: 0] += 1 } }
        let total = Double(tasteDocs.count + candDocs.count + likedDocs.count + dislikedDocs.count)
        func idf(_ w: String) -> Double { log((total + 1) / Double((df[w] ?? 0) + 1)) + 1 }

        func vector(_ doc: [String]) -> [Double]? {
            var sum: [Double] = []
            var wsum = 0.0
            for w in doc {
                guard let v = embedding.vector(for: w) else { continue }
                let weight = idf(w)
                if sum.isEmpty { sum = v.map { $0 * weight } }
                else { for i in v.indices { sum[i] += v[i] * weight } }
                wsum += weight
            }
            guard wsum > 0 else { return nil }
            return sum.map { $0 / wsum }
        }

        // A like is a strong interest signal — it joins your taste so similar videos
        // rank up. A dislike forms a separate "anti-taste" used to push down lookalikes.
        let tasteVectors = (tasteDocs + likedDocs).compactMap(vector)
        let dislikedVectors = dislikedDocs.compactMap(vector)
        guard !tasteVectors.isEmpty else { return items }

        // Channel affinity: a candidate from a channel you actually watch gets a nudge.
        var affinity: [String: Int] = [:]
        for entry in history { if let u = entry.uploader { affinity[u, default: 0] += 1 } }
        let maxAff = Double(max(affinity.values.max() ?? 1, 1))

        func score(_ item: StreamItem, _ doc: [String]) -> Double {
            guard let v = vector(doc) else { return -1 }
            // Mean of your 3 NEAREST interests: as sharp as a single max, but one
            // stray off-topic watch can't single-handedly magnet a candidate up.
            let top = tasteVectors.map { cosine($0, v) }.sorted(by: >).prefix(3)
            let topicSim = top.isEmpty ? 0 : top.reduce(0, +) / Double(top.count)
            // Categorical gate: collapse the score of a video whose category you
            // essentially never watch (e.g. war/news for an all-tech history). The
            // 0.15 floor keeps it soft, so a misclassification can't fully erase it.
            let gated = topicSim * (0.15 + 0.85 * categoryFit(doc))
            let aff = Double(affinity[item.uploaderName ?? ""] ?? 0) / maxAff
            var s = gated + aff * 0.25   // affinity weight: tunable knob
            // YouTube's own category is authoritative: if it says News & politics and
            // you don't watch news, bury it regardless of what the title words imply.
            if newsShare < 0.15,
               let cat = enrichment[item.videoID ?? ""]?.category?.lowercased(),
               cat.contains("news") || cat.contains("politic") {
                s *= 0.05
            }
            // "Suggest less": push down anything resembling a thumbs-down, and bury a
            // whole category you've down-voted.
            if !dislikedVectors.isEmpty {
                let dislikeSim = dislikedVectors.map { cosine($0, v) }.max() ?? 0
                s -= 0.6 * max(0, dislikeSim)   // dislike weight: tunable knob
            }
            if !dislikedCategories.isEmpty, let c = classify(doc), dislikedCategories.contains(c) {
                s *= 0.2
            }
            return s
        }

        return zip(items, candDocs)
            .map { (item, doc) in (item, score(item, doc)) }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
    }
}
