import Foundation
import SwiftData

/// Persisted summary of the local For You profile. The raw history/search/save
/// rows remain the source of truth; this snapshot saves the expensive selection
/// choices and channel-affinity map until those inputs change.
@Model
final class RecommendationProfileSnapshot {
    @Attribute(.unique) var id: String
    var signature: String
    var relatedSeedIDs: [String]
    var explorationSeedIDs: [String]
    var candidateSearchQueries: [String]
    var savedSeedIDs: [String]
    var channelAffinityKeys: [String]
    var channelAffinityValues: [Double]
    var updatedAt: Date

    init(id: String = "default", signature: String,
         relatedSeedIDs: [String], explorationSeedIDs: [String],
         candidateSearchQueries: [String], savedSeedIDs: [String],
         channelAffinityKeys: [String], channelAffinityValues: [Double],
         updatedAt: Date = .now) {
        self.id = id
        self.signature = signature
        self.relatedSeedIDs = relatedSeedIDs
        self.explorationSeedIDs = explorationSeedIDs
        self.candidateSearchQueries = candidateSearchQueries
        self.savedSeedIDs = savedSeedIDs
        self.channelAffinityKeys = channelAffinityKeys
        self.channelAffinityValues = channelAffinityValues
        self.updatedAt = updatedAt
    }

    var channelAffinity: [String: Double] {
        Dictionary(uniqueKeysWithValues: zip(channelAffinityKeys, channelAffinityValues))
    }

    @MainActor
    func update(signature: String, from profile: InterestProfile, at date: Date = .now) {
        self.signature = signature
        relatedSeedIDs = profile.relatedSeeds.map(\.videoID)
        explorationSeedIDs = profile.explorationSeeds.map(\.videoID)
        candidateSearchQueries = profile.candidateSearchQueries
        savedSeedIDs = profile.savedSeedIDs
        let affinity = profile.channelAffinity.sorted { $0.key < $1.key }
        channelAffinityKeys = affinity.map(\.key)
        channelAffinityValues = affinity.map(\.value)
        updatedAt = date
    }
}
