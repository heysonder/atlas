import SwiftUI
import PipedKit

/// A self-contained 9:16 poster for a YouTube Short: the title is laid over the
/// bottom of the thumbnail (channel/views/time are dropped — they don't matter
/// for a Short). Flexible width, so two can sit side by side in a row.
///
/// The source is YouTube's 16:9 blur-extended frame, so the image keeps its real
/// 16:9 aspect (`.fill`) while the card's 9:16 box crops the centre — leaving the
/// portrait content with no blurred side bars.
struct ShortPoster: View {
    let item: StreamItem
    /// Marks the poster as already watched (dimmed, with a "Watched" badge).
    var watched: Bool = false
    var onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            Color.clear
                .aspectRatio(9/16, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay {
                    Thumbnail(url: item.thumbnail)
                        .aspectRatio(16/9, contentMode: .fill)
                        .opacity(watched ? 0.55 : 1)
                }
                .overlay {
                    LinearGradient(colors: [.clear, .black.opacity(0.8)],
                                   startPoint: .center, endPoint: .bottom)
                }
                .overlay(alignment: .bottomLeading) {
                    Text(item.displayTitle)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.leading)
                        .shadow(radius: 3)
                        .padding(10)
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .topLeading) {
                    Image(systemName: "play.square.stack.fill")
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(8)
                }
                .overlay(alignment: .topTrailing) {
                    if watched { WatchedBadge().padding(8) }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.displayTitle)
    }
}
