import SwiftUI
import PipedKit

struct CreatorChannel: Identifiable, Hashable, Sendable {
    var name: String
    var channelID: String?
    var avatarURL: String?
    var subtitle: String?
    var isVerified: Bool

    var id: String { channelID ?? name }

    init(name: String, channelID: String?, avatarURL: String?, subtitle: String? = nil,
         isVerified: Bool = false) {
        self.name = name
        self.channelID = channelID
        self.avatarURL = avatarURL
        self.subtitle = subtitle
        self.isVerified = isVerified
    }

    init?(_ creator: VideoCreator, isVerified: Bool = false) {
        guard let name = creator.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        self.init(name: name,
                  channelID: creator.channelID,
                  avatarURL: creator.avatar,
                  subtitle: nil,
                  isVerified: isVerified)
    }
}

extension Array where Element == VideoCreator {
    func creatorChannels(verifiedChannelID: String?, uploaderVerified: Bool) -> [CreatorChannel] {
        compactMap { creator in
            CreatorChannel(creator,
                           isVerified: uploaderVerified && creator.channelID == verifiedChannelID)
        }
    }
}

extension Array where Element == CreatorChannel {
    func needsCreatorFallback(expectedAdditionalCount: Int) -> Bool {
        let expectedCount = expectedAdditionalCount > 0 ? expectedAdditionalCount + 1 : 2
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

private extension CreatorChannel {
    func matches(_ other: CreatorChannel) -> Bool {
        if let channelID, let otherChannelID = other.channelID, channelID == otherChannelID {
            return true
        }
        return name.caseInsensitiveCompare(other.name) == .orderedSame
    }
}

/// Presentation metadata for a video's visible creator line.
struct CreatorSummary: Identifiable, Hashable {
    var displayName: String?
    var primaryName: String?
    var avatarURL: String?
    var channelID: String?
    var isVerified: Bool
    var subscriberCount: Int?
    var additionalCount: Int
    var collaborators: [CreatorChannel]

    init(primaryName: String?, displayName: String? = nil, avatarURL: String?,
         channelID: String?, isVerified: Bool = false, subscriberCount: Int? = nil,
         collaborators: [CreatorChannel] = []) {
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
        self.additionalCount = parsed.additionalCount
        self.collaborators = collaborators
    }

    var id: String { [visibleName, channelID, "\(additionalCount)"].compactMap(\.self).joined(separator: "|") }
    var hasMultipleCreators: Bool { additionalCount > 0 || collaborators.count > 1 }
    var visibleName: String? {
        if let displayName { return displayName }
        guard let primaryName else { return nil }
        let extraCount = max(additionalCount, collaborators.count - 1)
        return extraCount > 0 ? "\(primaryName) and \(extraCount) more" : primaryName
    }
    var visibleCollaborators: [CreatorChannel] {
        if !collaborators.isEmpty { return collaborators }
        guard let primaryName else { return [] }
        return [CreatorChannel(name: primaryName,
                               channelID: channelID,
                               avatarURL: avatarURL,
                               subtitle: nil,
                               isVerified: isVerified)]
    }

    private static func parseCollaboratorDisplayName(_ value: String?) -> (primaryName: String?, additionalCount: Int) {
        guard let value = cleaned(value) else { return (nil, 0) }
        guard value.hasSuffix(" more"),
              let andRange = value.range(of: " and ", options: .backwards) else {
            return (value, 0)
        }

        let countSlice = value[andRange.upperBound...].dropLast(" more".count)
        guard countSlice.allSatisfy(\.isNumber),
              let count = Int(countSlice),
              count > 0 else {
            return (value, 0)
        }

        return (cleaned(String(value[..<andRange.lowerBound])), count)
    }

    private static func cleaned(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

struct CreatorChannelControl<Content: View>: View {
    let summary: CreatorSummary
    private let label: () -> Content
    @State private var showingCollaborators = false

    init(summary: CreatorSummary, @ViewBuilder label: @escaping () -> Content) {
        self.summary = summary
        self.label = label
    }

    var body: some View {
        if summary.hasMultipleCreators {
            Button {
                showingCollaborators = true
            } label: {
                label()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Choose collaborator")
            .sheet(isPresented: $showingCollaborators) {
                CollaboratorPickerSheet(summary: summary)
            }
        } else if let channelID = summary.channelID {
            NavigationLink(value: channelID) {
                label()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open channel")
        } else {
            label()
        }
    }
}

private struct CollaboratorPickerSheet: View {
    let summary: CreatorSummary
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(summary.visibleCollaborators) { channel in
                if let channelID = channel.channelID {
                    NavigationLink(value: channelID) {
                        row(channel)
                    }
                } else {
                    row(channel)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Collaborators")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { id in
                ChannelDetailView(channelID: id)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func row(_ channel: CreatorChannel) -> some View {
        HStack(spacing: 12) {
            Avatar(url: channel.avatarURL, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(channel.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if channel.isVerified {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if let subtitle = channel.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

struct CreatorAvatarCluster: View {
    private let avatarURLs: [String?]
    var additionalCount: Int = 0
    var size: CGFloat = 40

    private var extraCount: Int { max(0, additionalCount) }
    private let colors: [Color] = [.blue, .pink, .teal, .orange]

    init(avatarURL: String?, collaboratorAvatarURLs: [String?] = [],
         additionalCount: Int = 0, size: CGFloat = 40) {
        let urls = collaboratorAvatarURLs.isEmpty ? [avatarURL] : collaboratorAvatarURLs
        self.avatarURLs = urls.isEmpty ? [avatarURL] : urls
        self.additionalCount = additionalCount
        self.size = size
    }

    var body: some View {
        if totalCount <= 1 {
            avatar(index: 0, size: size)
        } else {
            cluster
        }
    }

    private var totalCount: Int {
        max(avatarURLs.count, 1 + extraCount)
    }

    // MARK: Organic overlapping cluster

    /// What a single tile in the cluster renders.
    private enum Slot {
        case avatar(Int)
        case overflow(Int)
    }

    /// A tile's content plus its scattered placement, all relative to `size`.
    private struct Placement {
        let slot: Slot
        let dx: CGFloat       // horizontal offset (fraction of size)
        let dy: CGFloat       // vertical offset (fraction of size)
        let diameter: CGFloat // tile diameter (fraction of size)
        let rotation: Double  // degrees of casual tilt
    }

    private var cluster: some View {
        ZStack {
            // Rendered back-to-front: the primary avatar lands last, on top.
            ForEach(Array(placements.enumerated()), id: \.offset) { _, placement in
                tile(placement)
            }
        }
        .frame(width: side, height: side)
    }

    private var side: CGFloat { size * 1.34 }

    /// Back-to-front scatter — hand-tuned so it reads as a natural huddle, not a grid.
    private var placements: [Placement] {
        switch totalCount {
        case 2:
            return [
                place(.avatar(1), dx:  0.20, dy: -0.16, d: 0.68, rot:  8),
                place(.avatar(0), dx: -0.15, dy:  0.14, d: 0.74, rot: -6), // primary, front
            ]
        case 3:
            return [
                place(.avatar(1), dx:  0.30, dy: -0.18, d: 0.56, rot:  9),
                place(.avatar(2), dx: -0.30, dy: -0.10, d: 0.55, rot: -10),
                place(.avatar(0), dx:  0.02, dy:  0.18, d: 0.66, rot: -4), // primary, front
            ]
        default:
            let trailing: Slot = totalCount > 4 ? .overflow(totalCount - 3) : .avatar(3)
            return [
                place(.avatar(1), dx:  0.31, dy: -0.22, d: 0.52, rot:  9),
                place(.avatar(2), dx: -0.32, dy: -0.13, d: 0.52, rot: -9),
                place(trailing,   dx:  0.24, dy:  0.30, d: 0.50, rot:  6),
                place(.avatar(0), dx: -0.05, dy:  0.13, d: 0.64, rot: -5), // primary, front
            ]
        }
    }

    private func place(_ slot: Slot, dx: CGFloat, dy: CGFloat, d: CGFloat, rot: Double) -> Placement {
        Placement(slot: slot, dx: dx, dy: dy, diameter: d, rotation: rot)
    }

    @ViewBuilder private func tile(_ placement: Placement) -> some View {
        let diameter = size * placement.diameter
        content(for: placement.slot, diameter: diameter)
            .overlay {
                Circle().strokeBorder(ringColor, lineWidth: max(1.5, diameter * 0.07))
            }
            .rotationEffect(.degrees(placement.rotation))
            .shadow(color: .black.opacity(0.18), radius: diameter * 0.05, x: 0, y: diameter * 0.04)
            .offset(x: size * placement.dx, y: size * placement.dy)
    }

    @ViewBuilder private func content(for slot: Slot, diameter: CGFloat) -> some View {
        switch slot {
        case .avatar(let index): avatar(index: index, size: diameter)
        case .overflow(let count): countBubble(count, size: diameter)
        }
    }

    private var ringColor: Color { Color(.systemBackground) }

    @ViewBuilder private func avatar(index: Int, size: CGFloat) -> some View {
        if index < avatarURLs.count {
            Avatar(url: avatarURLs[index], size: size)
        } else {
            placeholder(index: index, size: size)
        }
    }

    private func placeholder(index: Int, size: CGFloat) -> some View {
        Circle()
            .fill(colors[index % colors.count])
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "person.fill")
                    .font(.system(size: max(8, size * 0.42), weight: .semibold))
                    .foregroundStyle(.white)
            }
    }

    private func countBubble(_ count: Int, size: CGFloat) -> some View {
        Circle()
            .fill(Color.secondary)
            .frame(width: size, height: size)
            .overlay {
                Text("+\(count)")
                    .font(.system(size: max(8, size * 0.34), weight: .bold))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.7)
            }
    }
}
