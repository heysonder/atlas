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

    init(
        id: String = "default", signature: String,
        relatedSeedIDs: [String], explorationSeedIDs: [String],
        candidateSearchQueries: [String], savedSeedIDs: [String],
        channelAffinityKeys: [String], channelAffinityValues: [Double],
        updatedAt: Date = .now
    ) {
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
        var result: [String: Double] = [:]
        for (key, value) in zip(channelAffinityKeys, channelAffinityValues)
        where !key.isEmpty && value.isFinite && value >= 0 {
            result[key] = max(result[key] ?? 0, value)
        }
        return result
    }

    @MainActor
    @discardableResult
    func update(signature: String, from profile: InterestProfile, at date: Date = .now) -> Bool {
        guard Self.isPersistable(signature: signature, profile: profile, at: date) else {
            return false
        }
        self.signature = signature
        relatedSeedIDs = profile.relatedSeeds.map(\.videoID)
        explorationSeedIDs = profile.explorationSeeds.map(\.videoID)
        candidateSearchQueries = profile.candidateSearchQueries
        savedSeedIDs = profile.savedSeedIDs
        let affinity = profile.channelAffinity.sorted { $0.key < $1.key }
        channelAffinityKeys = affinity.map(\.key)
        channelAffinityValues = affinity.map(\.value)
        updatedAt = date
        return true
    }

    static func isPersistable(
        signature: String,
        profile: InterestProfile,
        at date: Date = .now
    ) -> Bool {
        do {
            try PersistedMetadataPolicy.requireIdentifier(signature, field: "profile.signature")
            try PersistedMetadataPolicy.requireIdentifiers(
                profile.relatedSeeds.map(\.videoID), field: "profile.relatedSeedIDs")
            try PersistedMetadataPolicy.requireIdentifiers(
                profile.explorationSeeds.map(\.videoID), field: "profile.explorationSeedIDs")
            try PersistedMetadataPolicy.requireTextCollection(
                profile.candidateSearchQueries, field: "profile.candidateSearchQueries")
            try PersistedMetadataPolicy.requireIdentifiers(
                profile.savedSeedIDs, field: "profile.savedSeedIDs")
            let affinity = profile.channelAffinity.sorted { $0.key < $1.key }
            try PersistedMetadataPolicy.requireIdentifiers(
                affinity.map(\.key), field: "profile.channelAffinityKeys")
            guard affinity.allSatisfy({ $0.value.isFinite && $0.value >= 0 }) else {
                return false
            }
            try PersistedMetadataPolicy.requireFiniteDate(date, field: "profile.updatedAt")
            return true
        } catch {
            return false
        }
    }
}
