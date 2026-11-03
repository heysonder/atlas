import SwiftUI

/// A rounded card showing the comment count and the top (pinned, or
/// currently-timestamped) comment. Tapping it opens the full comments pane.
struct EmbeddedCommentCard: View {
    let loader: CommentsLoader?
    let currentPlaybackSeconds: Double?
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 10) {
                header
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!canOpen)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(canOpen ? "Opens all comments" : "")
    }

    private var canOpen: Bool {
        guard let loader else { return false }
        return !loader.disabled && (loader.didLoad && !loader.comments.isEmpty || loader.loadFailed)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Comments")
                .font(.subheadline.weight(.semibold))
            if let loader, loader.commentCount > 0, let count = Format.compact(loader.commentCount) {
                Text(count)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if canOpen {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let loader {
            if loader.disabled {
                notice("Comments are turned off.")
            } else if loader.loadFailed {
                notice("Couldn’t load comments. Tap to retry.")
            } else if !loader.didLoad {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    notice("Loading comments…")
                }
            } else if let comment = featuredComment(loader) {
                HStack(alignment: .top, spacing: 10) {
                    Avatar(url: comment.thumbnail, size: 26, networkScope: .selectedInstance)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            if comment.pinned == true {
                                Image(systemName: "pin.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text(comment.author ?? "Unknown")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Text(comment.plainText)
                            .font(.callout)
                            .lineLimit(2)
                            .foregroundStyle(.primary)
                    }
                }
            } else {
                notice("No comments yet.")
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                notice("Loading comments…")
            }
        }
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    /// A timestamped comment that matches the playhead wins, then the pinned
    /// one, then the first.
    private func featuredComment(_ loader: CommentsLoader) -> CommentDisplay? {
        if let active = loader.activeTimestampComment(at: currentPlaybackSeconds) {
            return active
        }
        return loader.comments.first(where: { $0.pinned == true }) ?? loader.comments.first
    }

    private var accessibilityLabel: String {
        guard let loader, loader.didLoad, let comment = featuredComment(loader) else { return "Comments" }
        let count = Format.compact(loader.commentCount).map { "\($0) comments. " } ?? "Comments. "
        return count + "\(comment.author ?? "Unknown"): \(comment.plainText)"
    }
}
