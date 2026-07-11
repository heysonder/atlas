import PipedKit
import SwiftUI

struct ChannelHeaderView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let channel: Channel
    let isSubscribed: Bool
    let reduceMotion: Bool
    let onToggleSubscription: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if let banner = channel.bannerURL {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: 120)
                    .overlay {
                        Thumbnail(url: banner, networkScope: .selectedInstance)
                            .scaledToFill()
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal)
            }

            headerRow
                .padding(.horizontal)
        }
    }

    @ViewBuilder
    private var headerRow: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 12) {
                identity
                subscribeButton
            }
        } else {
            HStack(alignment: .center, spacing: 12) {
                identity
                Spacer(minLength: 8)
                subscribeButton
            }
        }
    }

    private var identity: some View {
        HStack(alignment: .center, spacing: 12) {
            Avatar(url: channel.avatarURL, size: 64, networkScope: .selectedInstance)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name ?? "Channel")
                    .font(.title3.weight(.semibold))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                if let subscribers = Format.subscribers(channel.subscriberCount) {
                    Text(subscribers)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var subscribeButton: some View {
        Button(action: onToggleSubscription) {
            Image(systemName: isSubscribed ? "checkmark" : "plus")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isSubscribed ? .secondary : Color.accentColor)
                .frame(width: 44, height: 44)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel(isSubscribed ? "Unsubscribe" : "Subscribe")
    }
}
