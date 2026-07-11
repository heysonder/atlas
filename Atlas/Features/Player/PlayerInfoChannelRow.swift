import SwiftUI

struct PlayerInfoChannelRow<VideoActions: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let creator: CreatorSummary
    let canSubscribe: Bool
    @Binding var isSubscribed: Bool
    let reduceMotion: Bool
    let onToggleSubscribe: (Bool) -> Bool
    let videoActions: VideoActions

    init(
        creator: CreatorSummary,
        canSubscribe: Bool,
        isSubscribed: Binding<Bool>,
        reduceMotion: Bool,
        onToggleSubscribe: @escaping (Bool) -> Bool,
        @ViewBuilder videoActions: () -> VideoActions
    ) {
        self.creator = creator
        self.canSubscribe = canSubscribe
        _isSubscribed = isSubscribed
        self.reduceMotion = reduceMotion
        self.onToggleSubscribe = onToggleSubscribe
        self.videoActions = videoActions()
    }

    @ViewBuilder
    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 12) {
                creatorControl
                actions
            }
        } else {
            HStack(spacing: 12) {
                creatorControl
                Spacer(minLength: 8)
                actions
            }
        }
    }

    private var creatorControl: some View {
        CreatorChannelControl(summary: creator) {
            HStack(spacing: 12) {
                CreatorAvatarCluster(
                    avatarURL: creator.avatarURL,
                    collaboratorAvatarURLs: creator.collaborators.map(\.avatarURL),
                    additionalCount: creator.additionalCount,
                    size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(creator.visibleName ?? "Channel")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        if creator.isVerified {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Verified creator")
                        }
                    }
                    if let subscribers = Format.subscribers(creator.subscriberCount) {
                        Text(subscribers)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            videoActions
            if canSubscribe {
                subscribeButton
            }
        }
    }

    private var subscribeButton: some View {
        Button {
            let requestedSubscription = !isSubscribed
            isSubscribed = PlayerInfoPersistence.retainedValue(
                current: isSubscribed,
                requested: requestedSubscription,
                persist: onToggleSubscribe)
        } label: {
            Image(systemName: isSubscribed ? "checkmark" : "plus")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isSubscribed ? .secondary : .primary)
                .frame(width: 44, height: 44)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel(isSubscribed ? "Unsubscribe" : "Subscribe")
    }
}
