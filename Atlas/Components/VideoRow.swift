import SwiftUI
import PipedKit

/// A YouTube-style video row: thumbnail with duration pill, title, and meta line.
/// Tapping the thumbnail/title plays; tapping the avatar/channel name opens the
/// channel (via a NavigationLink, so the enclosing stack must register a
/// `navigationDestination(for: String.self)` mapping the channel id).
struct VideoRow: View {
    @Environment(AppModel.self) private var app

    let item: StreamItem
    /// Used when the item itself carries no uploader avatar (e.g. a channel page).
    var avatarFallback: String? = nil
    /// Channel id to use when the item carries no uploader url (e.g. a channel page).
    var channelIDFallback: String? = nil
    /// Marks the thumbnail as already watched (dimmed, with a "Watched" badge).
    var watched: Bool = false
    /// Reserves space for a full two-line title even when the title is one line,
    /// so cards keep a uniform height when tiled in a grid — otherwise short
    /// titles leave ragged gaps and the columns drift into a masonry look.
    var reservesTitleSpace: Bool = false
    var onPlay: () -> Void
    @State private var collaborators: [CreatorChannel] = []
    @State private var resolvedIsLive: Bool?

    private var channelID: String? { item.uploaderChannelID ?? channelIDFallback }
    private var creator: CreatorSummary {
        CreatorSummary(primaryName: item.uploaderName,
                       avatarURL: item.uploaderAvatar ?? avatarFallback,
                       channelID: channelID,
                       isVerified: item.uploaderVerified ?? false,
                       collaborators: collaborators)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onPlay) {
                ZStack(alignment: .bottomTrailing) {
                    Thumbnail(url: item.thumbnail)
                        .aspectRatio(16/9, contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .opacity(watched ? 0.55 : 1)
                        .shadow(color: .black.opacity(0.16), radius: 5, x: 0, y: 2)
                        .overlay(alignment: .topLeading) {
                            if watched { WatchedBadge().padding(8) }
                        }
                    playbackStatePill
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.displayTitle)

            HStack(alignment: .top, spacing: 10) {
                CreatorChannelControl(summary: creator) {
                    CreatorAvatarCluster(avatarURL: creator.avatarURL,
                                         collaboratorAvatarURLs: creator.collaborators.map(\.avatarURL),
                                         additionalCount: creator.additionalCount,
                                         size: 34)
                }
                VStack(alignment: .leading, spacing: 3) {
                    title
                    metaRow
                }
                Spacer(minLength: 0)
            }
        }
        .task(id: item.videoID) {
            resolvedIsLive = nil
            await loadResolvedMetadataIfNeeded()
        }
    }

    private var title: some View {
        Button(action: onPlay) {
            Text(item.displayTitle)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2, reservesSpace: reservesTitleSpace)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var playbackStatePill: some View {
        let d = Format.duration(item.duration)
        if item.isLive || resolvedIsLive == true {
            LiveBadge()
                .padding(8)
        } else if !d.isEmpty {
            ThumbnailChip {
                Text(d)
            }
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
        let rowCreator = creator
        HStack(spacing: 4) {
            if let name = rowCreator.visibleName, !name.isEmpty {
                CreatorChannelControl(summary: rowCreator) {
                    Text(name)
                }
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

    private func loadResolvedMetadataIfNeeded() async {
        let shouldLoadCollaborators = collaborators.isEmpty && creator.hasMultipleCreators
        let shouldResolveLiveStatus = item.needsLiveStatusResolution
        guard shouldLoadCollaborators || shouldResolveLiveStatus,
              let videoID = item.videoID else { return }
        guard let detail = try? await app.resolveStream(videoID) else { return }

        if shouldResolveLiveStatus {
            resolvedIsLive = detail.livestream == true
        }

        if shouldLoadCollaborators {
            var loaded = detail.creators?.creatorChannels(verifiedChannelID: detail.channelID,
                                                          uploaderVerified: detail.uploaderVerified ?? false) ?? []

            if loaded.needsCreatorFallback(expectedAdditionalCount: creator.additionalCount) {
                loaded = loaded.enriched(with: await YouTubeCollaborators.channels(for: videoID))
            }

            if !loaded.isEmpty {
                collaborators = loaded
            }
        }
    }
}
