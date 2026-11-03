import SwiftUI

/// Replaces the comments card while a stream is live: the newest chat
/// message, and a tap opens the full transcript. The loader is driven by the
/// watch page (one poller), not by this card.
struct EmbeddedLiveChatCard: View {
    let loader: LiveChatLoader
    let onOpen: () -> Void

    private var canOpen: Bool {
        loader.availability == .active || loader.availability == .ended
    }

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
        .accessibilityHint(canOpen ? "Opens the live chat" : "")
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(loader.availability == .active ? Color(.systemRed) : Color.secondary)
                .frame(width: 7, height: 7)
            Text(loader.availability == .ended ? "Live Chat ended" : "Live Chat")
                .font(.subheadline.weight(.semibold))
            Spacer()
            if canOpen {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch loader.availability {
        case .unknown:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                notice("Connecting to live chat…")
            }
        case .unavailable:
            notice("This instance doesn’t provide live chat.")
        case .active, .ended:
            if let message = loader.messages.last {
                HStack(alignment: .top, spacing: 10) {
                    Avatar(url: message.avatar, size: 26, networkScope: .selectedInstance)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(message.author)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(message.text)
                            .font(.callout)
                            .lineLimit(2)
                            .foregroundStyle(.primary)
                    }
                }
                .id(message.id)
                .transition(.opacity)
            } else {
                notice("No chat messages yet.")
            }
        }
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private var accessibilityLabel: String {
        guard let message = loader.messages.last else { return "Live chat" }
        return "Live chat. Latest: \(message.author): \(message.text)"
    }
}

/// The live transcript inside the slide-up pane. The transcript follows the
/// newest message and offers a "Latest" pill when scrolled back.
struct EmbeddedLiveChatPaneContent: View {
    let loader: LiveChatLoader

    private var emptyText: String {
        loader.availability == .unavailable
            ? "This instance doesn’t provide live chat."
            : "No chat messages yet."
    }

    var body: some View {
        if loader.messages.isEmpty {
            Text(emptyText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            LiveChatTranscriptPane(
                messages: loader.messages,
                accessibilityLabel: "Live chat messages",
                fillsContainer: true)
        }
    }
}
