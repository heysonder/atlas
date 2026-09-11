import PipedKit
import SwiftUI

struct ChannelHeaderView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var bannerWidth: CGFloat = 0

    let channel: Channel
    let isSubscribed: Bool
    let reduceMotion: Bool
    let onToggleSubscription: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if let banner = channel.bannerURL {
                // `Thumbnail` fills and crops to whatever frame it's given. Don't
                // add `.scaledToFill()` here: its ideal size is a 10×10 square,
                // so that laid the ~6:1 banner out as a 390×390 square and
                // clipped the middle band (stretched letters / a giant "B").
                Thumbnail(url: banner, networkScope: .selectedInstance)
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.bannerHeight(forWidth: bannerWidth))
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.width
                    } action: {
                        bannerWidth = $0
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .imageEdge(RoundedRectangle(cornerRadius: 14, style: .continuous), url: banner)
                    .padding(.horizontal)
            }

            headerRow
                .padding(.horizontal)
        }
    }

    /// YouTube banners are ~6.05:1 with the creator's content guaranteed inside
    /// a centre 3.65:1 "mobile safe area". Narrow layouts crop to that safe
    /// band; as the width grows (iPad, a resized window, an unfolded phone) the
    /// crop opens up toward the full banner, capped so it never becomes a wall.
    static func bannerHeight(forWidth width: CGFloat) -> CGFloat {
        guard width > 0 else { return 107 }
        let fullBanner = width / 6.05
        let safeBand = width / 3.65
        return min(200, max(fullBanner, min(safeBand, 120)))
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
