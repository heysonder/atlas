import CryptoKit
import Foundation

extension RecommendationEngine {
    // MARK: Local profile

    @MainActor
    static func makeProfile(
        history: [HistoryEntry], feedback: [FeedbackSignal],
        saved: [PlaylistVideo], searches: [SearchSignal],
        subscribedIDs: Set<String>,
        snapshot: RecommendationProfileSnapshot? = nil,
        signature: String? = nil
    ) -> InterestProfile {
        makeProfile(
            history: history.map(HistorySignal.init),
            feedback: feedback,
            saved: saved.map(SavedVideoSignal.init),
            searches: searches,
            subscribedIDs: subscribedIDs,
            snapshot: snapshot,
            signature: signature)
    }

    static func makeProfile(
        history: [HistorySignal], feedback: [FeedbackSignal],
        saved: [SavedVideoSignal], searches: [SearchSignal],
        subscribedIDs: Set<String>,
        snapshot: RecommendationProfileSnapshot? = nil,
        signature: String? = nil
    ) -> InterestProfile {
        let history = Array(history.prefix(200))
        let feedback = Array(feedback.prefix(200))
        let saved = Array(saved.prefix(120))
        let searches = Array(searches.prefix(60))
        let affinity =
            snapshot.flatMap { cached in
                signature == cached.signature ? cached.channelAffinity : nil
            } ?? channelAffinity(history: history, saved: saved)

        if let snapshot, signature == snapshot.signature {
            let historyByID = Dictionary(uniqueKeysWithValues: history.map { ($0.videoID, $0) })
            let relatedSeeds = snapshot.relatedSeedIDs.compactMap { historyByID[$0] }
            let explorationSeeds = snapshot.explorationSeedIDs.compactMap { historyByID[$0] }
            return InterestProfile(
                history: history, feedback: feedback, saved: saved, searches: searches,
                subscribedIDs: subscribedIDs, relatedSeeds: relatedSeeds,
                explorationSeeds: explorationSeeds, channelAffinity: affinity,
                candidateSearchQueriesOverride: snapshot.candidateSearchQueries,
                savedSeedIDsOverride: snapshot.savedSeedIDs)
        }

        // One timestamp for the whole ranking pass, so both seed selections score
        // recency against the same "now".
        let now = Date()
        let relatedSeeds = selectHistorySeeds(history, limit: 8, channelCap: 2, now: now)
        let relatedIDs = Set(relatedSeeds.map(\.videoID))
        let explorationSeeds = selectHistorySeeds(
            history, limit: 3, excludedIDs: relatedIDs, channelCap: 1, now: now)

        return InterestProfile(
            history: history, feedback: feedback, saved: saved,
            searches: searches, subscribedIDs: subscribedIDs,
            relatedSeeds: relatedSeeds,
            explorationSeeds: explorationSeeds,
            channelAffinity: affinity)
    }

    @MainActor
    static func profileSignature(
        history: [HistoryEntry], feedback: [FeedbackSignal],
        saved: [PlaylistVideo], searches: [SearchSignal],
        subscribedIDs: Set<String>
    ) -> String {
        profileSignature(
            history: history.map(HistorySignal.init),
            feedback: feedback,
            saved: saved.map(SavedVideoSignal.init),
            searches: searches,
            subscribedIDs: subscribedIDs)
    }

    static func profileSignature(
        history: [HistorySignal], feedback: [FeedbackSignal],
        saved: [SavedVideoSignal], searches: [SearchSignal],
        subscribedIDs: Set<String>
    ) -> String {
        let canonical = canonicalProfileSignature(
            history: history,
            feedback: feedback,
            saved: saved,
            searches: searches,
            subscribedIDs: subscribedIDs)
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func canonicalProfileSignature(
        history: [HistorySignal],
        feedback: [FeedbackSignal],
        saved: [SavedVideoSignal],
        searches: [SearchSignal],
        subscribedIDs: Set<String>
    ) -> String {
        let historyPart = history.prefix(80).map {
            "\($0.videoID):\(signatureInteger($0.watchedAt.timeIntervalSince1970)):"
                + "\(signatureInteger($0.positionSeconds)):\(signatureInteger($0.durationSeconds)):\($0.uploader ?? "")"
        }.joined(separator: "|")
        let feedbackPart = feedback.prefix(200).sorted { $0.title < $1.title }.map {
            "\($0.signal):\($0.title):\($0.uploader ?? ""):\($0.category ?? ""):\($0.tags.joined(separator: ","))"
        }.joined(separator: "|")
        let savedPart = saved.prefix(60).map {
            "\($0.videoID):\(signatureInteger($0.addedAt.timeIntervalSince1970)):\($0.uploader ?? "")"
        }.joined(separator: "|")
        let searchPart = searches.prefix(60).map {
            "\($0.query):\($0.count):\(signatureInteger($0.lastSearchedAt.timeIntervalSince1970))"
        }.joined(separator: "|")
        let subPart = subscribedIDs.sorted().prefix(200).joined(separator: "|")
        return [historyPart, feedbackPart, savedPart, searchPart, subPart].joined(separator: "\n")
    }

    private static func signatureInteger(_ value: Double) -> String {
        guard value.isFinite else { return "invalid" }
        let rounded = value.rounded(.towardZero)
        guard let integer = Int64(exactly: rounded) else { return "invalid" }
        return String(integer)
    }

    nonisolated private static func channelAffinity(
        history: [HistorySignal],
        saved: [SavedVideoSignal]
    ) -> [String: Double] {
        var affinity: [String: Double] = [:]
        for entry in history {
            if let u = entry.uploader {
                affinity[u, default: 0] += watchWeight(
                    position: entry.positionSeconds,
                    duration: entry.durationSeconds)
            }
        }
        for video in saved {
            if let u = video.uploader { affinity[u, default: 0] += 1.5 }
        }
        return affinity
    }

    /// Strong-watch seed selection: prefer videos the user actually spent time
    /// with, keep some recency, and avoid letting one channel own all seed slots.
    nonisolated private static func selectHistorySeeds(
        _ history: [HistorySignal], limit: Int,
        excludedIDs: Set<String> = [],
        channelCap: Int, now: Date
    ) -> [HistorySignal] {
        let ranked =
            history
            .filter { !excludedIDs.contains($0.videoID) }
            .map { ($0, historySeedScore($0, now: now)) }
            .sorted {
                if $0.1 == $1.1 { return $0.0.watchedAt > $1.0.watchedAt }
                return $0.1 > $1.1
            }

        var chosen: [HistorySignal] = []
        var channels: [String: Int] = [:]
        for (entry, _) in ranked where chosen.count < limit {
            let key = entry.uploader ?? entry.videoID
            guard channels[key, default: 0] < channelCap else { continue }
            chosen.append(entry)
            channels[key, default: 0] += 1
        }
        if chosen.count < limit {
            let chosenIDs = Set(chosen.map(\.videoID))
            for (entry, _) in ranked where chosen.count < limit && !chosenIDs.contains(entry.videoID) {
                chosen.append(entry)
            }
        }
        return chosen
    }

    nonisolated private static func historySeedScore(_ entry: HistorySignal, now: Date) -> Double {
        let elapsed = now.timeIntervalSince(entry.watchedAt)
        let ageDays = elapsed.isFinite ? max(0, elapsed / 86_400) : .infinity
        let recency = ageDays.isFinite ? max(0.2, 1 - ageDays / 45) : 0.2
        return watchWeight(position: entry.positionSeconds, duration: entry.durationSeconds) * recency
    }
}
