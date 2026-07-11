import Foundation
import PipedKit

nonisolated struct CreatorChannel: Identifiable, Hashable, Sendable {
    let name: String
    var channelID: String?
    var avatarURL: String?
    var subtitle: String?
    var isVerified: Bool

    var id: String { channelID ?? name }

    init(
        name: String,
        channelID: String?,
        avatarURL: String?,
        subtitle: String? = nil,
        isVerified: Bool = false
    ) {
        self.name = name
        self.channelID = channelID
        self.avatarURL = avatarURL
        self.subtitle = subtitle
        self.isVerified = isVerified
    }

    init?(_ creator: VideoCreator, isVerified: Bool = false) {
        guard let name = creator.name?.trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty
        else {
            return nil
        }
        self.init(
            name: name,
            channelID: creator.channelID,
            avatarURL: creator.avatar,
            subtitle: nil,
            isVerified: isVerified)
    }
}

extension Array where Element == VideoCreator {
    func creatorChannels(verifiedChannelID: String?, uploaderVerified: Bool) -> [CreatorChannel] {
        compactMap { creator in
            CreatorChannel(
                creator,
                isVerified: uploaderVerified && creator.channelID == verifiedChannelID)
        }
    }
}

extension Array where Element == CreatorChannel {
    func needsCreatorFallback(expectedAdditionalCount: Int) -> Bool {
        let expectedCount = CreatorCountPolicy.expectedTotal(expectedAdditionalCount)
        if count < expectedCount { return true }
        return contains { cleaned($0.avatarURL) == nil }
    }

    func enriched(with fallback: [CreatorChannel]) -> [CreatorChannel] {
        guard !fallback.isEmpty else { return self }
        guard !isEmpty else { return fallback }

        var output = self
        for fallbackChannel in fallback {
            if let index = output.firstIndex(where: { $0.matches(fallbackChannel) }) {
                if cleaned(output[index].avatarURL) == nil {
                    output[index].avatarURL = fallbackChannel.avatarURL
                }
                if cleaned(output[index].channelID) == nil {
                    output[index].channelID = fallbackChannel.channelID
                }
                if cleaned(output[index].subtitle) == nil {
                    output[index].subtitle = fallbackChannel.subtitle
                }
                output[index].isVerified = output[index].isVerified || fallbackChannel.isVerified
            } else {
                output.append(fallbackChannel)
            }
        }
        return output
    }

    private func cleaned(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

extension CreatorChannel {
    fileprivate func matches(_ other: CreatorChannel) -> Bool {
        if let channelID,
            let otherChannelID = other.channelID,
            channelID == otherChannelID
        {
            return true
        }
        return name.caseInsensitiveCompare(other.name) == .orderedSame
    }
}

/// Presentation metadata for a video's visible creator line.
struct CreatorSummary: Identifiable, Hashable {
    let displayName: String?
    let primaryName: String?
    let avatarURL: String?
    let channelID: String?
    let isVerified: Bool
    let subscriberCount: Int?
    let additionalCount: Int
    let collaborators: [CreatorChannel]

    var id: String {
        [visibleName, channelID, "\(additionalCount)"]
            .compactMap(\.self)
            .joined(separator: "|")
    }

    var hasMultipleCreators: Bool {
        additionalCount > 0 || collaborators.count > 1
    }

    var visibleName: String? {
        if let displayName { return displayName }
        guard let primaryName else { return nil }
        let extraCount = max(
            CreatorCountPolicy.additional(additionalCount),
            collaborators.count - 1)
        return extraCount > 0 ? "\(primaryName) and \(extraCount) more" : primaryName
    }

    var visibleCollaborators: [CreatorChannel] {
        if !collaborators.isEmpty { return collaborators }
        guard let primaryName else { return [] }
        return [
            CreatorChannel(
                name: primaryName,
                channelID: channelID,
                avatarURL: avatarURL,
                subtitle: nil,
                isVerified: isVerified)
        ]
    }

    init(
        primaryName: String?,
        displayName: String? = nil,
        avatarURL: String?,
        channelID: String?,
        isVerified: Bool = false,
        subscriberCount: Int? = nil,
        collaborators: [CreatorChannel] = []
    ) {
        let cleanedDisplayName = Self.cleaned(displayName)
        let cleanedPrimaryName = Self.cleaned(primaryName)
        let parsed = Self.parseCollaboratorDisplayName(cleanedDisplayName ?? cleanedPrimaryName)
        self.displayName = cleanedDisplayName ?? cleanedPrimaryName
        if let cleanedPrimaryName, cleanedPrimaryName != self.displayName {
            self.primaryName = cleanedPrimaryName
        } else {
            self.primaryName = parsed.primaryName ?? cleanedPrimaryName
        }
        self.avatarURL = Self.cleaned(avatarURL)
        self.channelID = Self.cleaned(channelID)
        self.isVerified = isVerified
        self.subscriberCount = subscriberCount
        self.additionalCount = CreatorCountPolicy.additional(parsed.additionalCount)
        self.collaborators = collaborators
    }

    private static func parseCollaboratorDisplayName(
        _ value: String?
    ) -> (primaryName: String?, additionalCount: Int) {
        guard let value = cleaned(value) else { return (nil, 0) }
        guard value.hasSuffix(" more"),
            let andRange = value.range(of: " and ", options: .backwards)
        else {
            return (value, 0)
        }

        let countSlice = value[andRange.upperBound...].dropLast(" more".count)
        guard countSlice.allSatisfy(\.isNumber),
            let count = Int(countSlice),
            count > 0
        else {
            return (value, 0)
        }

        return (cleaned(String(value[..<andRange.lowerBound])), count)
    }

    private static func cleaned(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

enum CreatorCountPolicy {
    static let maximumAdditionalCount = 999

    static func additional(_ value: Int) -> Int {
        min(max(0, value), maximumAdditionalCount)
    }

    static func expectedTotal(_ additionalCount: Int) -> Int {
        additionalCount > 0 ? total(primaryCount: 1, additionalCount: additionalCount) : 2
    }

    static func total(primaryCount: Int, additionalCount: Int) -> Int {
        let primary = max(0, primaryCount)
        let additional = additional(additionalCount)
        let (sum, overflow) = primary.addingReportingOverflow(additional)
        return overflow ? Int.max : sum
    }
}
