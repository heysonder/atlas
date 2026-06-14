import SwiftUI
import PipedKit

/// A YouTube-style video row: thumbnail with duration pill, title, and meta line.
/// Tapping the thumbnail/title plays; tapping the avatar/channel name opens the
/// channel (via a NavigationLink, so the enclosing stack must register a
/// `navigationDestination(for: String.self)` mapping the channel id).
struct VideoRow: View {
    let item: StreamItem
    /// Used when the item itself carries no uploader avatar (e.g. a channel page).
    var avatarFallback: String? = nil
    /// Channel id to use when the item carries no uploader url (e.g. a channel page).
    var channelIDFallback: String? = nil
    /// Marks the thumbnail as already watched (dimmed, with a "Watched" badge).
    var watched: Bool = false
    var onPlay: () -> Void

    private var channelID: String? { item.uploaderChannelID ?? channelIDFallback }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Thumbnail(url: item.thumbnail)
                    .aspectRatio(16/9, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .opacity(watched ? 0.55 : 1)
                    .overlay(alignment: .topLeading) {
                        if watched { WatchedBadge().padding(8) }
                    }
                durationPill
            }
            .contentShape(Rectangle())
            .onTapGesture { onPlay() }

            HStack(alignment: .top, spacing: 10) {
                channelLink { Avatar(url: item.uploaderAvatar ?? avatarFallback, size: 34) }
                VStack(alignment: .leading, spacing: 3) {
                    title
                    metaRow
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var title: some View {
        Text(item.displayTitle)
            .font(.subheadline.weight(.semibold))
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .contentShape(Rectangle())
            .onTapGesture { onPlay() }
    }

    @ViewBuilder private var durationPill: some View {
        let d = Format.duration(item.duration)
        if !d.isEmpty {
            Text(d)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .foregroundStyle(.white)
                .glassEffect(.regular, in: Capsule())
                .padding(8)
        }
    }

    /// "639 views · 2 days ago", or just "2 days ago" when the video has fewer
    /// than 500 views (the count is noise at that scale).
    private var metaText: String {
        let timeAgo = Format.relativeTime(item.uploaded) ?? item.uploadedDate
        let viewsStr = (item.views ?? -1) >= 500 ? Format.views(item.views) : nil
        return Format.metaLine(viewsStr, timeAgo)
    }

    @ViewBuilder private var metaRow: some View {
        let meta = metaText
        HStack(spacing: 4) {
            if let name = item.uploaderName, !name.isEmpty {
                channelLink { Text(name) }
                if !meta.isEmpty {
                    Text("·")
                    Text(meta)
                }
            } else if !meta.isEmpty {
                Text(meta)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    /// Wraps a label in a channel NavigationLink when a channel id is known.
    @ViewBuilder private func channelLink<Label: View>(@ViewBuilder _ label: () -> Label) -> some View {
        if let channelID {
            NavigationLink(value: channelID) { label() }.buttonStyle(.plain)
        } else {
            label()
        }
    }
}
