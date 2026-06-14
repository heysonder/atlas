import SwiftUI

/// The small Liquid Glass "Info" button layered over the video.
struct InfoOverlayButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label("Info", systemImage: "info.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
    }
}

/// The contents of the player's "Info" sheet: title, uploader + subscribe
/// toggle, and the full (HTML-stripped) description. Presented over the
/// still-playing video, so it never interrupts playback.
struct PlayerInfoSheet: View {
    let title: String
    let uploader: String?
    let description: String
    let canSubscribe: Bool
    @State var isSubscribed: Bool
    let onToggleSubscribe: (Bool) -> Void
    /// Only shown when the personalized For You feed is on.
    let showFeedback: Bool
    @State var feedback: Int
    let onFeedback: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)

                    if let uploader, !uploader.isEmpty {
                        HStack(spacing: 12) {
                            Text(uploader)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            if canSubscribe { subscribeButton }
                        }
                    }

                    if showFeedback {
                        HStack(spacing: 12) {
                            suggestButton(more: true)
                            suggestButton(more: false)
                            Spacer(minLength: 0)
                        }
                    }

                    Divider()

                    if description.isEmpty {
                        Text("No description.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(description)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// "Suggest More / Less"; tapping the active one again clears it.
    private func suggestButton(more: Bool) -> some View {
        let active = more ? feedback > 0 : feedback < 0
        return Button {
            let target = more ? 1 : -1
            feedback = (feedback == target) ? 0 : target
            onFeedback(feedback)
        } label: {
            Label(more ? "Suggest More" : "Suggest Less",
                  systemImage: more ? (active ? "hand.thumbsup.fill" : "hand.thumbsup")
                                    : (active ? "hand.thumbsdown.fill" : "hand.thumbsdown"))
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .tint(active ? .accentColor : .secondary)
    }

    private var subscribeButton: some View {
        Button {
            isSubscribed.toggle()
            onToggleSubscribe(isSubscribed)
        } label: {
            Label(isSubscribed ? "Subscribed" : "Subscribe",
                  systemImage: isSubscribed ? "checkmark" : "plus")
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.borderedProminent)
        .tint(isSubscribed ? .gray : .accentColor)
    }
}
