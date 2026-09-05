import SwiftUI

/// A single chat message: small avatar, author with role badges, text.
/// Chat avatars come straight from YouTube's CDN (the instance doesn't proxy
/// them), so they load through the public-internet image scope.
struct LiveChatMessageRow: View {
    let message: LiveChatMessageDisplay

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Avatar(url: message.avatar, size: 24, networkScope: .publicInternet)

            VStack(alignment: .leading, spacing: 1) {
                authorLine
                Text(EmojiShortcodes.emojized(message.text))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
    }

    private var authorLine: some View {
        HStack(spacing: 4) {
            Text(message.author)
                .font(.caption.weight(.semibold))
                .foregroundStyle(message.isOwner ? AnyShapeStyle(.yellow) : AnyShapeStyle(.secondary))
                .lineLimit(1)
            if message.isVerified {
                Image(systemName: "checkmark.seal.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Verified")
            }
            if message.isOwner {
                Image(systemName: "crown.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                    .accessibilityLabel("Channel owner")
            }
            if message.isModerator {
                Image(systemName: "wrench.fill")
                    .font(.caption2)
                    .foregroundStyle(.blue)
                    .accessibilityLabel("Moderator")
            }
            if message.isSponsor {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .accessibilityLabel("Channel member")
            }
        }
    }
}
