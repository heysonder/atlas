import SwiftUI

/// The bounded chat pane shared by live chat and chat replay. It follows the
/// newest message: pinned to the bottom while the reader is there, paused
/// when they scroll up to read back, and re-pinned once they scroll back to
/// the bottom (or tap the "Latest" pill).
///
/// Pinning is decided only when a user scroll gesture ends — never from
/// passive geometry, because appended messages grow the content before the
/// scroll catches up, which would read as "scrolled away" and cancel the
/// very scroll that keeps the pane pinned.
struct LiveChatTranscriptPane: View {
    let messages: [LiveChatMessageDisplay]
    var accessibilityLabel = "Chat messages"
    /// Fill the available height (the dedicated Chat page) instead of the
    /// fixed pane used inside the Info sheet.
    var fillsContainer = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPinnedToBottom = true
    @State private var position = ScrollPosition(edge: .bottom)

    private static let paneHeight: CGFloat = 420
    /// How close to the bottom (in points) still counts as "at the bottom".
    private static let pinThreshold: CGFloat = 32

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(messages) { message in
                    LiveChatMessageRow(message: message)
                }
            }
            .padding(.horizontal, fillsContainer ? 16 : 12)
            .padding(.vertical, 12)
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        .onScrollPhaseChange { _, phase, context in
            switch phase {
            case .interacting:
                isPinnedToBottom = false
            case .idle:
                isPinnedToBottom = Self.isNearBottom(context.geometry)
            default:
                break
            }
        }
        .onChange(of: messages.last?.id) { _, _ in
            guard isPinnedToBottom else { return }
            scrollToBottom()
        }
        .overlay(alignment: .bottomTrailing) {
            if !isPinnedToBottom {
                jumpToLatestButton
            }
        }
        .frame(height: fillsContainer ? nil : Self.paneHeight)
        .frame(maxWidth: .infinity, maxHeight: fillsContainer ? .infinity : nil)
        // The dedicated Chat page has no box of its own — the sheet/panel is
        // the surface. Inside other layouts the pane gets a solid card.
        .background {
            if !fillsContainer {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            }
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private var jumpToLatestButton: some View {
        Button {
            isPinnedToBottom = true
            scrollToBottom()
        } label: {
            Label("Latest", systemImage: "arrow.down")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .padding(12)
        .accessibilityLabel("Jump to latest message")
    }

    private static func isNearBottom(_ geometry: ScrollGeometry) -> Bool {
        geometry.contentSize.height - geometry.visibleRect.maxY < pinThreshold
    }

    private func scrollToBottom() {
        if reduceMotion {
            position.scrollTo(edge: .bottom)
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                position.scrollTo(edge: .bottom)
            }
        }
    }
}
