import SwiftUI

/// Consent lives here rather than in an appearance task: opening Settings never
/// enrolls the device or starts an account lookup.
struct ICloudSyncSettingsView: View {
    @Environment(CloudSyncCoordinator.self) private var sync
    @State private var presentedSheet: SyncSheet?
    @State private var confirmation: SyncConfirmation?

    var body: some View {
        Form {
            Section {
                SyncStatusHeader(sync: sync)
                if let detail = sync.detailText {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if sync.quarantinedCount > 0 {
                    LabeledContent("Items Not Applied", value: sync.quarantinedCount.formatted())
                        .accessibilityIdentifier("icloud.sync.quarantined")
                }
                if sync.isEnabled {
                    if let lastSync = sync.lastSync {
                        LabeledContent("Last Synced") {
                            Text(lastSync, format: .relative(presentation: .named))
                        }
                    }
                    LabeledContent("Pending Changes", value: sync.pendingCount.formatted())
                    Button("Sync Now", systemImage: "arrow.trianglehead.2.clockwise") {
                        Task { await sync.syncNow() }
                    }
                    .disabled(sync.isWorking || !sync.isAvailable)
                } else {
                    Button {
                        presentedSheet = .enable
                    } label: {
                        Label("Enable iCloud Sync…", systemImage: "icloud.and.arrow.up")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .disabled(sync.isWorking || !sync.isAvailable)
                }
            } footer: {
                Text(
                    sync.isEnabled
                        ? "Your library stays available offline. iOS decides when background sync runs."
                        : "Sync is off. Nothing leaves this device until you enable it.")
            }

            Section("What Syncs") {
                SyncCategoryGrid()
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            }

            Section {
                SyncDeviceOnlyRow()
            } footer: {
                Text("Recommendations are still generated on this device.")
            }

            Section {
                SyncEncryptionCard()
            } header: {
                Text("Encryption")
            } footer: {
                Text(
                    "Check Advanced Data Protection in Settings → your name → iCloud. Atlas does not verify whether it is enabled; availability depends on your account and region."
                )
            }

            Section {
                if sync.isEnabled {
                    Button("Turn Off Sync on This Device…") { confirmation = .disable }
                }
                Button("Reset For You Personalization…", role: .destructive) {
                    confirmation = .resetPersonalization
                }
                .disabled(sync.isWorking || !sync.isAvailable)
                Button("Delete Synced Content from iCloud…", role: .destructive) {
                    confirmation = .deleteCloudContent
                }
                .disabled(sync.isWorking || !sync.isAvailable || !sync.hasLinkedLibrary)
            } footer: {
                Text(
                    "Turning off sync keeps both your local and iCloud copies. It does not change your device’s iCloud Backup setting."
                )
            }
        }
        .navigationTitle("iCloud Sync")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $presentedSheet) { _ in
            ICloudSyncConsentView()
        }
        .confirmationDialog(
            confirmation?.title ?? "iCloud Sync",
            isPresented: Binding(
                get: { confirmation != nil },
                set: { if !$0 { confirmation = nil } }),
            titleVisibility: .visible,
            presenting: confirmation
        ) { action in
            Button(action.buttonTitle, role: action.isDestructive ? .destructive : nil) {
                confirmation = nil
                Task {
                    switch action {
                    case .disable: await sync.disable()
                    case .deleteCloudContent: await sync.deleteCloudContent()
                    case .resetPersonalization: await sync.resetPersonalization()
                    }
                }
            }
            Button("Cancel", role: .cancel) { confirmation = nil }
        } message: { action in
            Text(action.message)
        }
    }
}

// MARK: - Header

/// Icon, name, and the live status line. The status is one accessibility element
/// whose value is the plain status text.
private struct SyncStatusHeader: View {
    let sync: CloudSyncCoordinator

    var body: some View {
        HStack(spacing: 14) {
            SyncHeroIcon(size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text("iCloud Sync")
                    .font(.headline)
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(sync.statusText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Sync Status")
                .accessibilityValue(sync.statusText)
                .accessibilityIdentifier("icloud.sync.status")
            }
            Spacer(minLength: 0)
            if sync.isWorking {
                ProgressView()
            }
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch sync.statusText {
        case "Up to Date", "iCloud Content Deleted": .green
        case "Off", "Unavailable": .secondary
        case "Needs Attention", "Account Changed", "Account Unavailable", "iCloud Storage Full",
            "Deletion Not Finished":
            .orange
        default: .accentColor
        }
    }
}

private struct SyncHeroIcon: View {
    var size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.accentColor, Color.accentColor.opacity(0.65)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "icloud.fill")
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Coverage

private struct SyncCategory: Identifiable {
    let title: String
    let symbol: String
    let tint: Color
    var id: String { title }

    static let synced: [SyncCategory] = [
        .init(title: "Subscriptions", symbol: "person.2.fill", tint: .blue),
        .init(title: "Watch history", symbol: "clock.fill", tint: .indigo),
        .init(title: "Playback progress", symbol: "play.circle.fill", tint: .purple),
        .init(title: "Playlists & Favorites", symbol: "heart.text.square.fill", tint: .pink),
        .init(title: "Search history", symbol: "magnifyingglass", tint: .teal),
        .init(title: "More / Less feedback", symbol: "hand.thumbsup.fill", tint: .green),
        .init(title: "For You activity", symbol: "sparkles", tint: .orange),
        .init(title: "Display & playback settings", symbol: "slider.horizontal.3", tint: .gray),
    ]

    static let deviceOnly: [String] = [
        "Downloads", "Piped instance", "Privacy permissions", "Diagnostics", "Player queue",
    ]
}

/// Two-column grid of what leaves the device, one chip per category.
private struct SyncCategoryGrid: View {
    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(SyncCategory.synced) { category in
                HStack(spacing: 10) {
                    Image(systemName: category.symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(category.tint.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text(category.title)
                        .font(.subheadline)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private struct SyncDeviceOnlyRow: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "iphone")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Stays on this device")
                    .font(.subheadline.weight(.semibold))
                Text(SyncCategory.deviceOnly.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Encryption

/// The full notice is required copy before any upload and stays on the settings
/// page; the lead line keeps the takeaway readable at a glance.
private struct SyncEncryptionCard: View {
    private let instructionsURL = URL(string: "https://support.apple.com/en-us/108756")!

    static let notice =
        "Atlas stores your synced library and activity in encrypted iCloud fields. End-to-end encryption requires Advanced Data Protection for your Apple Account. Without it, Apple holds the keys needed to decrypt this data. Some iCloud service metadata is not end-to-end encrypted, even with Advanced Data Protection."

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.green.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text("Encrypted in iCloud")
                    .font(.subheadline.weight(.semibold))
                Text(Self.notice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        Link(destination: instructionsURL) {
            Label("About Advanced Data Protection", systemImage: "arrow.up.right.square")
        }
    }
}

// MARK: - Consent

private struct ICloudSyncConsentView: View {
    @Environment(CloudSyncCoordinator.self) private var sync
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(spacing: 12) {
                        SyncHeroIcon(size: 72)
                        Text("Sync Your Library")
                            .font(.title2.weight(.bold))
                        Text(
                            "Merge this device’s library with the Atlas library in your Apple Account’s private iCloud database. Items from both are kept, minus anything you have already deleted or reset."
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)

                    ConsentCard(title: "What’s included") {
                        SyncCategoryGrid()
                    }

                    ConsentCard(title: "Stays on this device") {
                        Text(SyncCategory.deviceOnly.joined(separator: " · "))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    ConsentCard(title: "Encryption") {
                        SyncEncryptionCard()
                        Text(
                            "Check Advanced Data Protection in Settings → your name → iCloud. Atlas does not verify whether it is enabled."
                        )
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Button {
                        dismiss()
                        Task { await sync.enable() }
                    } label: {
                        Label("Enable & Merge", systemImage: "icloud.and.arrow.up")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(sync.isWorking || !sync.isAvailable)
                    Text("You can turn sync off at any time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 6)
                .background(.bar)
            }
            .navigationTitle("Enable iCloud Sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

/// Grouped-style card for the consent sheet, matching the Form sections elsewhere.
private struct ConsentCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

// MARK: - Dialogs

private enum SyncSheet: String, Identifiable {
    case enable
    var id: String { rawValue }
}

private enum SyncConfirmation {
    case disable
    case deleteCloudContent
    case resetPersonalization

    var title: String {
        switch self {
        case .disable: "Turn Off Sync on This Device?"
        case .deleteCloudContent: "Delete Synced Content from iCloud?"
        case .resetPersonalization: "Reset For You Personalization?"
        }
    }

    var buttonTitle: String {
        switch self {
        case .disable: "Turn Off Sync"
        case .deleteCloudContent: "Delete Synced Content"
        case .resetPersonalization: "Reset Personalization"
        }
    }

    var isDestructive: Bool {
        switch self {
        case .disable: false
        case .deleteCloudContent, .resetPersonalization: true
        }
    }

    var message: String {
        switch self {
        case .disable:
            "Stops new sync requests on this device and keeps your local library and existing iCloud content. Changes already sent may still finish. You can merge again when you re-enable sync."
        case .deleteCloudContent:
            "Removes Atlas’s synced library and activity from iCloud while keeping local copies. Other enrolled devices pause when they receive the reset. A minimal encrypted reset marker remains in iCloud to prevent offline devices from uploading the deleted library again."
        case .resetPersonalization:
            "Clears watch and search history, playback progress, Suggest More/Less feedback, and recommendation activity. When sync is enabled, the reset also applies to your synced library. Subscriptions and playlist saves remain and continue to inform recommendations."
        }
    }
}
