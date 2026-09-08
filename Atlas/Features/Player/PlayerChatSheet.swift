import SwiftUI

/// Chat-only content shared by the portrait sheet and the landscape panel:
/// live chat (polling while shown) or the chat replay following playback.
struct PlayerChatContent: View {
    let liveLoader: LiveChatLoader?
    let replayLoader: LiveChatReplayLoader?
    let playbackTime: PlayerPlaybackTime?

    var body: some View {
        Group {
            if let liveLoader {
                live(liveLoader)
            } else if let replayLoader {
                replay(replayLoader)
            } else {
                notice("No chat for this video.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func live(_ loader: LiveChatLoader) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            switch loader.availability {
            case .unknown:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading live chat…").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .active, .ended:
                if loader.messages.isEmpty {
                    notice("No chat messages yet.")
                } else {
                    LiveChatTranscriptPane(
                        messages: loader.messages,
                        accessibilityLabel: "Live chat messages",
                        fillsContainer: true)
                }
                if loader.availability == .ended {
                    Text("Live chat ended.").font(.footnote).foregroundStyle(.secondary)
                }
            case .unavailable:
                notice("This instance doesn't provide live chat.")
            }
        }
        .task {
            AppDiagnostics.reportLiveChat(active: true)
            defer { AppDiagnostics.reportLiveChat(active: false) }
            await loader.run()
        }
    }

    @ViewBuilder
    private func replay(_ loader: LiveChatReplayLoader) -> some View {
        let visible = loader.visibleMessages(at: playbackTime?.seconds)
        Group {
            if visible.isEmpty {
                notice("Chat will appear as the stream plays.")
            } else {
                LiveChatTranscriptPane(
                    messages: visible,
                    accessibilityLabel: "Chat replay messages",
                    fillsContainer: true)
            }
        }
        .task(id: loader.videoID) {
            await loader.run { playbackTime?.seconds }
        }
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Portrait: the same chrome as the Info sheet (inline title, Done). The
/// transcript's scroll view spans the full sheet width — like Info's — so the
/// navigation bar's scroll-edge glass matches the sheet instead of drawing an
/// inset box; the horizontal inset lives inside the scroll content.
struct PlayerChatSheet: View {
    let content: PlayerChatContent
    var onDisappear: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    private var title: String { content.liveLoader != nil ? "Live Chat" : "Chat Replay" }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .containerBackground(.clear, for: .navigation)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .onDisappear(perform: onDisappear)
    }
}

/// Landscape: a Liquid Glass panel docked to the trailing edge over the
/// still-playing video. Tapping the video area dismisses it.
struct PlayerChatSidePanel: View {
    let content: PlayerChatContent
    var onDisappear: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    private static let panelWidth: CGFloat = 360

    var body: some View {
        HStack(spacing: 0) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }
                .accessibilityLabel("Close chat")
            VStack(spacing: 8) {
                HStack {
                    Text(content.liveLoader != nil ? "Live Chat" : "Chat Replay")
                        .font(.headline)
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close chat")
                }
                .padding(.horizontal, 4)
                content
            }
            .padding(12)
            .frame(width: Self.panelWidth)
            .frame(maxHeight: .infinity)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(.vertical, 12)
            .padding(.trailing, 12)
        }
        .onDisappear(perform: onDisappear)
    }
}
