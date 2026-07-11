import SwiftUI

struct CreatorChannelControl<Content: View>: View {
    let summary: CreatorSummary
    private let label: () -> Content
    @State private var showingCollaborators = false

    init(summary: CreatorSummary, @ViewBuilder label: @escaping () -> Content) {
        self.summary = summary
        self.label = label
    }

    var body: some View {
        if summary.hasMultipleCreators {
            Button {
                showingCollaborators = true
            } label: {
                interactiveLabel
            }
            .buttonStyle(.plain)
            .accessibilityLabel(collaboratorAccessibilityLabel)
            .sheet(isPresented: $showingCollaborators) {
                CollaboratorPickerSheet(summary: summary)
            }
        } else if let channelID = summary.channelID {
            NavigationLink(value: channelID) {
                interactiveLabel
            }
            .buttonStyle(.plain)
            .accessibilityLabel(channelAccessibilityLabel)
        } else {
            label()
        }
    }

    private var interactiveLabel: some View {
        label()
            .frame(minWidth: 44, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
    }

    private var collaboratorAccessibilityLabel: String {
        guard let name = summary.visibleName, !name.isEmpty else { return "Choose collaborator" }
        return "Choose collaborator for \(name)"
    }

    private var channelAccessibilityLabel: String {
        guard let name = summary.visibleName, !name.isEmpty else { return "Open channel" }
        return "Open \(name) channel"
    }
}

private struct CollaboratorPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let summary: CreatorSummary

    var body: some View {
        NavigationStack {
            List(summary.visibleCollaborators) { channel in
                if let channelID = channel.channelID {
                    NavigationLink(value: channelID) {
                        row(channel)
                    }
                } else {
                    row(channel)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Collaborators")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { id in
                ChannelDetailView(channelID: id)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func row(_ channel: CreatorChannel) -> some View {
        HStack(spacing: 12) {
            Avatar(url: channel.avatarURL, size: 44, networkScope: .selectedInstance)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(channel.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if channel.isVerified {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if let subtitle = channel.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 6)
    }
}
