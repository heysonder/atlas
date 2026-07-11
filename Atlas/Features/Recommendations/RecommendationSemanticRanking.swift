import Foundation
import NaturalLanguage
import PipedKit

extension RecommendationEngine {
    // MARK: Strategy B — on-device semantic

    nonisolated static func rankByTopic(
        _ items: [StreamItem], profile: InterestProfile,
        sourcesByID: [String: Set<CandidateSource>] = [:],
        enrichment: [String: VideoSignals] = [:]
    ) -> [StreamItem] {
        let workItems = Array(items.prefix(RecommendationWorkBudget.maximumRankingItems))
        let remainder = Array(items.dropFirst(workItems.count))
        guard let embedding = NLEmbedding.wordEmbedding(for: .english) else { return items }

        // Only pure grammar words are dropped outright. Topical-but-common words
        // ("new", "best", "review") are KEPT — IDF below down-weights whatever turns
        // out to be ubiquitous in your actual pool, instead of guessing a blocklist.
        let stop: Set<String> = [
            "the", "and", "for", "you", "your", "with", "this", "that", "from", "but", "not",
            "are", "was", "has", "have", "had", "its", "our", "they", "them", "then", "than",
            "when", "who", "all", "what", "why", "how", "can", "will", "just", "out", "now", "get",
        ]

        func tokens(_ text: String) -> [String] {
            RecommendationWorkBudget.tokens(text, excluding: stop)
        }

        // The channel name is the strongest topic signal we have ("Veritasium",
        // "Fireship", "ThePrimeagen" *are* the topic) and survives when a title is
        // all jargon/proper-nouns the embedding can't see — so fold it into the text.
        func docTokens(title: String, channel: String?) -> [String] {
            tokens(channel.map { "\(title) \($0)" } ?? title)
        }

        func cosine(_ a: [Double], _ b: [Double]) -> Double {
            guard a.count == b.count else { return 0 }
            var dot = 0.0
            var na = 0.0
            var nb = 0.0
            for index in a.indices {
                dot += a[index] * b[index]
                na += a[index] * a[index]
                nb += b[index] * b[index]
            }
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
            (
                "tech",
                [
                    "technology", "software", "hardware", "gadget", "computer", "programming",
                    "developer", "app", "phone", "laptop", "processor", "coding", "startup", "silicon",
                ]
            ),
            (
                "science",
                [
                    "science", "physics", "chemistry", "biology", "space", "astronomy",
                    "research", "engineering", "mathematics",
                ]
            ),
            (
                "politics",
                [
                    "politics", "election", "president", "government", "senate", "congress",
                    "policy", "campaign", "vote", "democrat", "republican",
                ]
            ),
            (
                "war",
                [
                    "war", "military", "army", "troops", "missile", "invasion", "conflict",
                    "weapon", "soldier", "strike", "defense", "combat",
                ]
            ),
            ("news", ["news", "breaking", "report", "headline", "coverage", "reporter", "correspondent"]),
            ("finance", ["finance", "stocks", "market", "economy", "investing", "crypto", "trading", "inflation"]),
            ("gaming", ["gaming", "gameplay", "game", "esports", "speedrun", "multiplayer"]),
            ("entertainment", ["movie", "film", "celebrity", "music", "drama", "trailer", "song", "album"]),
            ("sports", ["sports", "football", "basketball", "soccer", "baseball", "league", "championship"]),
            ("lifestyle", ["vlog", "travel", "food", "cooking", "fitness", "fashion", "lifestyle"]),
            ("education", ["history", "documentary", "explained", "education", "tutorial", "lecture"]),
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
        var recent = profile.history.filter { $0.watchedAt >= cutoff }
        if recent.count < 15 { recent = Array(profile.history.prefix(30)) }
        recent = Array(recent.prefix(60))

        // Weight each watch by how much of it you finished: a video you watched to
        // the end joins your taste up to 4×, a half-watch once (as before). Repeating
        // the doc lets the "top-3 nearest" scoring below lean hard toward the topics
        // you actually finish — "suggest more like the things I watch all the way."
        let tasteDocs = recent.flatMap { entry -> [[String]] in
            let doc = docTokens(title: entry.title, channel: entry.uploader)
            let copies = max(
                1,
                Int(
                    watchWeight(
                        position: entry.positionSeconds,
                        duration: entry.durationSeconds
                    ).rounded()))
            return Array(repeating: doc, count: copies)
        }
        // Fold creator tags (when enriched) into the candidate's text — clean topical
        // keywords that sharpen both the similarity and the category classification.
        let candDocs = workItems.map { item -> [String] in
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
        let likedDocs = profile.feedback.prefix(200).filter { $0.signal > 0 }.map(feedbackDoc)
        let dislikedDocs = profile.feedback.prefix(200).filter { $0.signal < 0 }.map(feedbackDoc)

        // Deliberate signals beyond a passive watch: a playlist save is a strong
        // "keep this" — its title+channel joins your taste like a like. A recent
        // search is pure topical intent — the query string itself is the doc.
        let savedDocs = profile.saved.prefix(120).map { docTokens(title: $0.title, channel: $0.uploader) }
        let searchDocs = profile.searches.prefix(60).flatMap { signal -> [[String]] in
            let doc = tokens(signal.query)
            guard !doc.isEmpty else { return [] }
            return Array(repeating: doc, count: signal.copyCount)
        }

        // Your category distribution, learned from history + likes — no hardcoded
        // "news is bad". A candidate whose category you never watch gets gated; a
        // like on that category raises its share and lifts the gate.
        var catCount: [String: Int] = [:]
        var classified = 0
        for doc in tasteDocs + likedDocs + savedDocs + searchDocs {
            if let category = classify(doc) {
                catCount[category, default: 0] += 1
                classified += 1
            }
        }
        func categoryFit(_ category: String?) -> Double {
            guard classified > 0, let c = category else { return 1 }  // no signal → don't gate
            return Double(catCount[c] ?? 0) / Double(classified)
        }
        // How much of your taste is itself news/politics/war — decides whether to
        // trust YouTube's "News & politics" label as grounds to bury a candidate.
        let newsCategoryCount =
            (catCount["news"] ?? 0) + (catCount["politics"] ?? 0) + (catCount["war"] ?? 0)
        let newsShare =
            classified > 0
            ? Double(newsCategoryCount) / Double(classified)
            : 0
        // Categories you've explicitly thumbed-down — suppressed wholesale below.
        let dislikedCategories = Set(dislikedDocs.compactMap(classify))

        // IDF over the live pool: a word in every title (incl. "new"/"best"/"video")
        // earns weight ~1; a distinctive word earns more. Down-weight, never drop.
        var df: [String: Int] = [:]
        for doc in tasteDocs + candDocs + likedDocs + dislikedDocs + savedDocs + searchDocs {
            for word in Set(doc) {
                df[word, default: 0] += 1
            }
        }
        let total = Double(
            tasteDocs.count + candDocs.count + likedDocs.count + dislikedDocs.count
                + savedDocs.count + searchDocs.count)
        func idf(_ w: String) -> Double { log((total + 1) / Double((df[w] ?? 0) + 1)) + 1 }

        func vector(_ doc: [String]) -> [Double]? {
            var sum: [Double] = []
            var wsum = 0.0
            for w in doc {
                guard let v = embedding.vector(for: w) else { continue }
                let weight = idf(w)
                if sum.isEmpty { sum = v.map { $0 * weight } } else { for i in v.indices { sum[i] += v[i] * weight } }
                wsum += weight
            }
            guard wsum > 0 else { return nil }
            return sum.map { $0 / wsum }
        }

        // Likes, playlist saves, and recent searches are all interest signals — they
        // join your taste so similar videos rank up. A dislike forms a separate
        // "anti-taste" used to push down lookalikes.
        // Replicated copies (watch-weight, repeated searches) weight the category
        // distribution above, but the top-3-nearest similarity below must not see
        // them: one finished watch's copies would fill all three nearest slots —
        // exactly what the top-3 mean exists to prevent. Dedupe before vectorizing.
        let tasteVectors = deduplicatedDocs(tasteDocs + likedDocs + savedDocs + searchDocs)
            .compactMap(vector)
        let dislikedVectors = dislikedDocs.compactMap(vector)
        guard !tasteVectors.isEmpty else { return items }

        let maxAff = max(profile.channelAffinity.values.max() ?? 1, 1)

        func topThreeMeanSimilarity(to v: [Double], in candidates: [[Double]]) -> Double {
            var first = -Double.infinity
            var second = -Double.infinity
            var third = -Double.infinity
            var count = 0
            for candidate in candidates {
                let similarity = cosine(candidate, v)
                count += 1
                if similarity > first {
                    third = second
                    second = first
                    first = similarity
                } else if similarity > second {
                    third = second
                    second = similarity
                } else if similarity > third {
                    third = similarity
                }
            }
            guard count > 0 else { return 0 }
            let top = [first, second, third].prefix(min(3, count))
            return top.reduce(0, +) / Double(top.count)
        }

        let candidateFeatures = zip(workItems, candDocs).map { item, doc in
            let category = classify(doc)
            return (item: item, vector: vector(doc), category: category, fit: categoryFit(category))
        }

        func score(_ item: StreamItem, vector v: [Double], category: String?, fit: Double) -> Double {
            let id = item.videoID ?? ""
            let sources = sourcesByID[id] ?? []
            // Mean of your 3 NEAREST interests: as sharp as a single max, but one
            // stray off-topic watch can't single-handedly magnet a candidate up.
            let topicSim = topThreeMeanSimilarity(to: v, in: tasteVectors)
            // Categorical gate: collapse the score of a video whose category you
            // essentially never watch (e.g. war/news for an all-tech history). The
            // 0.15 floor keeps it soft, so a misclassification can't fully erase it.
            let gated = topicSim * (0.15 + 0.85 * fit)
            let aff = (profile.channelAffinity[item.uploaderName ?? ""] ?? 0) / maxAff
            // Following a channel is an explicit interest — lift its uploads on top
            // of the topic match, so your subs surface even on a quieter topic day.
            let sub = profile.subscribedIDs.contains(item.uploaderChannelID ?? "") ? 0.2 : 0
            let sourceBoost =
                (sources.contains(.saved) ? 0.12 : 0) + (sources.contains(.search) ? 0.10 : 0)
                + (sources.contains(.subscription) ? 0.08 : 0) + (sources.contains(.exploration) ? 0.03 : 0)
            var s = gated + aff * 0.25 + sub + sourceBoost
            // YouTube's own category is authoritative: if it says News & politics and
            // you don't watch news, bury it regardless of what the title words imply.
            if newsShare < 0.15,
                let cat = enrichment[id]?.category?.lowercased(),
                cat.contains("news") || cat.contains("politic")
            {
                s *= 0.05
            }
            // "Suggest less": push down anything resembling a thumbs-down, and bury a
            // whole category you've down-voted.
            if !dislikedVectors.isEmpty {
                let dislikeSim = dislikedVectors.map { cosine($0, v) }.max() ?? 0
                s -= 0.6 * max(0, dislikeSim)  // dislike weight: tunable knob
            }
            if !dislikedCategories.isEmpty, let c = category, dislikedCategories.contains(c) {
                s *= 0.2
            }
            return s
        }

        return
            candidateFeatures
            .map { feature in
                (
                    feature.item,
                    feature.vector.map {
                        score(feature.item, vector: $0, category: feature.category, fit: feature.fit)
                    } ?? -1
                )
            }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 } + remainder
    }

    /// Collapse exact-duplicate docs (watch-weight replication, repeated
    /// searches, a video both watched and saved) so nearest-neighbour scoring
    /// sees each distinct interest once. Order-preserving.
    nonisolated static func deduplicatedDocs(_ docs: [[String]]) -> [[String]] {
        var seen = Set<[String]>()
        return docs.filter { seen.insert($0).inserted }
    }

    nonisolated static func rankByTopicInBackground(
        _ items: [StreamItem],
        profile: InterestProfile,
        sourcesByID: [String: Set<CandidateSource>] = [:],
        enrichment: [String: VideoSignals] = [:]
    ) async -> [StreamItem] {
        await Task.detached(priority: .userInitiated) {
            rankByTopic(items, profile: profile, sourcesByID: sourcesByID, enrichment: enrichment)
        }.value
    }
}
