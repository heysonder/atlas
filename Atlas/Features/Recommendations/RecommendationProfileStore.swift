import Foundation
import SwiftData

@MainActor
enum RecommendationProfileStore {
    private static let snapshotID = "default"

    static func loadOrBuild(in context: ModelContext,
                            history: [HistoryEntry],
                            feedback: [FeedbackSignal],
                            saved: [PlaylistVideo],
                            searches: [SearchSignal],
                            subscribedIDs: Set<String>) -> InterestProfile {
        let signature = RecommendationEngine.profileSignature(
            history: history, feedback: feedback, saved: saved,
            searches: searches, subscribedIDs: subscribedIDs)
        let snapshot = fetchSnapshot(in: context)
        let profile = RecommendationEngine.makeProfile(
            history: history, feedback: feedback, saved: saved, searches: searches,
            subscribedIDs: subscribedIDs, snapshot: snapshot, signature: signature)

        if snapshot?.signature != signature {
            upsert(profile, signature: signature, existing: snapshot, in: context)
        }
        return profile
    }

    private static func fetchSnapshot(in context: ModelContext) -> RecommendationProfileSnapshot? {
        let descriptor = FetchDescriptor<RecommendationProfileSnapshot>(
            predicate: #Predicate { $0.id == snapshotID })
        return try? context.fetch(descriptor).first
    }

    private static func upsert(_ profile: InterestProfile, signature: String,
                               existing: RecommendationProfileSnapshot?,
                               in context: ModelContext) {
        if let existing {
            existing.update(signature: signature, from: profile)
        } else {
            let affinity = profile.channelAffinity.sorted { $0.key < $1.key }
            context.insert(RecommendationProfileSnapshot(
                id: snapshotID,
                signature: signature,
                relatedSeedIDs: profile.relatedSeeds.map(\.videoID),
                explorationSeedIDs: profile.explorationSeeds.map(\.videoID),
                candidateSearchQueries: profile.candidateSearchQueries,
                savedSeedIDs: profile.savedSeedIDs,
                channelAffinityKeys: affinity.map(\.key),
                channelAffinityValues: affinity.map(\.value)))
        }
    }
}
