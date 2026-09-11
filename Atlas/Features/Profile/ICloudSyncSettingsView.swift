import SwiftUI

/// Consent lives here rather than in an appearance task: opening Settings never
/// enrolls the device or starts an account lookup.
///
/// Two layouts share this screen. With sync off it reads like onboarding:
/// coverage grid, what stays local, and the encryption notice sit above the
/// enable button. Once sync is on, the page collapses to a status card and the
/// actions; coverage moves behind a "What Syncs" row.
struct ICloudSyncSettingsView: View {
    @Environment(CloudSyncCoordinator.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @State private var presentedSheet: SyncSheet?
    @State private var confirmation: SyncConfirmation?

    var body: some View {
        Form {
            Section {
                SyncStatusHeader(sync: sync)
                if let detail = sync.detailText, sync.showsDetail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if sync.quarantinedCount > 0 {
                    LabeledContent("Items Not Applied", value: sync.quarantinedCount.formatted())
                        .accessibilityIdentifier("icloud.sync.quarantined")
                }
            } footer: {
                if let footerText {
                    Text(footerText)
                }
            }

            if !sync.isEnabled, sync.isAvailable {
                Section {
                    Button("Enable iCloud Sync", systemImage: "icloud.and.arrow.up") {
                        presentedSheet = .enable
                    }
                    .disabled(sync.isWorking)
                }
            }

            if sync.isEnabled {
                Section {
                    NavigationLink {
                        SyncCoverageView()
                    } label: {
                        SyncCoverageRow()
                    }
                    SyncEncryptionRow()
                }
            } else {
                Section("What Syncs") {
                    SyncCategoryGrid()
                        .listRowInsets(SyncCategoryGrid.rowInsets)
                    SyncDeviceOnlyRow()
                }

                Section("Encryption") {
                    SyncEncryptionNotice()
                }
            }

            Section {
                if sync.isEnabled {
                    Button("Turn Off Sync on This Device…") { confirmation = .disable }
                        .syncConfirmation(.disable, current: $confirmation) { await sync.disable() }
                }
                Button("Reset For You Personalization…", role: .destructive) {
                    confirmation = .resetPersonalization
                }
                .disabled(sync.isWorking || !sync.isAvailable)
                .syncConfirmation(.resetPersonalization, current: $confirmation) {
                    await sync.resetPersonalization()
                }
                Button("Delete Synced Content from iCloud…", role: .destructive) {
                    confirmation = .deleteCloudContent
                }
                .disabled(sync.isWorking || !sync.isAvailable || !sync.hasLinkedLibrary)
                .syncConfirmation(.deleteCloudContent, current: $confirmation) {
                    // Deleting drops the device back to the off state, so leave the
                    // page; the Settings row reports progress and the result.
                    dismiss()
                    await sync.deleteCloudContent()
                }
            } footer: {
                if sync.isEnabled {
                    Text("Turning off sync keeps your local and iCloud copies.")
                }
            }
        }
        .navigationTitle("iCloud Sync")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $presentedSheet) { _ in
            ICloudSyncConsentView()
        }
    }

    private var footerText: String? {
        if !sync.isAvailable {
            return
                "Sync cannot be enabled while Atlas is running on temporary storage. Your saved library is still on this device, so do not delete or reinstall the app. Relaunch Atlas, and update to the latest version if this keeps happening."
        }
        if sync.isEnabled { return nil }
        return "Nothing leaves this device until you enable it."
    }
}

// MARK: - Status

/// How the status line should read at a glance. Routine states hide the
/// coordinator's detail sentence; attention states show it.
enum SyncStatusTone {
    case off, working, healthy, attention
}

extension CloudSyncCoordinator {
    var tone: SyncStatusTone {
        switch statusText {
        case "Off", "Unavailable": .off
        case "Up to Date", "Changes Pending", "iCloud Content Deleted": .healthy
        case "Needs Attention", "Account Changed", "Account Unavailable", "iCloud Storage Full",
            "Deletion Not Finished":
            .attention
        default: .working
        }
    }

    /// Routine states repeat the status line; problems and the post-deletion
    /// note about the reset marker are worth the extra sentence.
    var showsDetail: Bool {
        tone == .attention || statusText == "iCloud Content Deleted" || !isAvailable
    }
}

// MARK: - Header

/// Icon, name, and the live status line. Last-sync time and pending count fold
/// into one caption so the card never repeats itself. The status is one
/// accessibility element whose value is the plain status text. When sync is on,
/// the trailing control is Sync Now (or a spinner while a round runs).
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
                if let caption {
                    caption
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            if sync.isWorking {
                ProgressView()
            } else if sync.isEnabled {
                Button {
                    Task { await sync.syncNow() }
                } label: {
                    Image(systemName: "arrow.trianglehead.2.clockwise")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .disabled(!sync.isAvailable)
                .accessibilityLabel("Sync Now")
            }
        }
        .padding(.vertical, 4)
    }

    private var caption: Text? {
        guard sync.isEnabled, !sync.isWorking else { return nil }
        let pending = sync.pendingCount
        switch (pending > 0, sync.lastSync) {
        case (false, nil):
            return nil
        case (true, nil):
            return Text("^[\(pending) change](inflect: true) waiting")
        case (false, let last?):
            return Text("Synced \(last, format: .relative(presentation: .named))")
        case (true, let last?):
            return Text(
                "^[\(pending) change](inflect: true) waiting · Synced \(last, format: .relative(presentation: .named))"
            )
        }
    }

    private var statusColor: Color {
        switch sync.tone {
        case .healthy: .green
        case .off: .secondary
        case .attention: .orange
        case .working: .accentColor
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

/// Grid of what leaves the device, one chip per category. Columns adapt to the
/// available width: two on a phone, more in a wide iPad form.
private struct SyncCategoryGrid: View {
    /// Extra top inset keeps the first row's icons clear of the card's corners.
    static let rowInsets = EdgeInsets(top: 20, leading: 18, bottom: 16, trailing: 18)
    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 260), spacing: 10)]

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

/// One-line summary for the enabled state: the category icons stand in for the
/// full grid, which lives one push away.
private struct SyncCoverageRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What Syncs")
            HStack(spacing: 6) {
                ForEach(SyncCategory.synced) { category in
                    Image(systemName: category.symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(category.tint.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
            .accessibilityHidden(true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityValue(SyncCategory.synced.map(\.title).joined(separator: ", "))
    }
}

/// Full coverage list, reachable from the enabled state.
private struct SyncCoverageView: View {
    var body: some View {
        Form {
            Section {
                SyncCategoryGrid()
                    .listRowInsets(SyncCategoryGrid.rowInsets)
            }
            Section {
                SyncDeviceOnlyRow()
            } footer: {
                Text("Recommendations are still generated on this device.")
            }
        }
        .navigationTitle("What Syncs")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Encryption

enum SyncEncryptionCopy {
    /// "iCloud data security overview".
    static let overviewURL = URL(string: "https://support.apple.com/en-us/102651")!
    /// "How to turn on Advanced Data Protection for iCloud". iOS has no public
    /// way to open the Apple Account → iCloud page, so the guide is the path.
    static let howToURL = URL(string: "https://support.apple.com/en-us/108756")!

    /// Lead line, required before any upload. Keep the phrase
    /// "End-to-end encryption requires Advanced Data Protection" intact; the UI
    /// test looks for it on the consent sheet.
    static let lead =
        "Atlas stores your synced library in encrypted iCloud fields. End-to-end encryption requires Advanced Data Protection on your Apple Account."

    static let withADP = "Only your devices can read your synced library."
    static let withoutADP = "Apple holds the keys and could read it."

    /// One-line takeaway for the enabled state.
    static let summary = "End-to-end only with Advanced Data Protection."
}

/// Compact encryption status plus the Apple support link, for the enabled
/// state. The full notice stays on the off state and the consent sheet, where
/// it gates the first upload.
private struct SyncEncryptionRow: View {
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            SyncEncryptionIcon()
            VStack(alignment: .leading, spacing: 2) {
                Text("Encrypted in iCloud")
                Text(SyncEncryptionCopy.summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        SyncEncryptionLink()
    }
}

private struct SyncEncryptionIcon: View {
    var body: some View {
        Image(systemName: "lock.shield.fill")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(Color.green.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct SyncEncryptionLink: View {
    var body: some View {
        Link(destination: SyncEncryptionCopy.overviewURL) {
            Label("About Advanced Data Protection", systemImage: "arrow.up.right.square")
        }
    }
}

private struct SyncEncryptionHowToLink: View {
    var body: some View {
        Link(destination: SyncEncryptionCopy.howToURL) {
            Label("Turn On Advanced Data Protection", systemImage: "lock.icloud")
        }
    }
}

/// Full notice for onboarding: the lead line, then the two account states so
/// the privacy trade-off is legible without reading a paragraph.
private struct SyncEncryptionNotice: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                SyncEncryptionIcon()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Encrypted in iCloud")
                        .font(.subheadline.weight(.semibold))
                    Text(SyncEncryptionCopy.lead)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                ADPStateRow(
                    on: true, title: "Advanced Data Protection on",
                    detail: SyncEncryptionCopy.withADP)
                ADPStateRow(
                    on: false, title: "Advanced Data Protection off",
                    detail: SyncEncryptionCopy.withoutADP)
            }
            .padding(.leading, 42)
        }
        .padding(.vertical, 2)
        SyncEncryptionLink()
        SyncEncryptionHowToLink()
    }
}

private struct ADPStateRow: View {
    let on: Bool
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: on ? "lock.fill" : "lock.open.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? Color.green : Color.orange)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.footnote.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
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
                        SyncEncryptionNotice()
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
            .padding(EdgeInsets(top: 20, leading: 18, bottom: 16, trailing: 18))
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

/// Each action row owns its dialog so the popover anchors to the tapped row.
/// Attached to the Form instead, iOS 27 anchors it to the form's center.
private struct SyncConfirmationModifier: ViewModifier {
    let action: SyncConfirmation
    @Binding var current: SyncConfirmation?
    let perform: @MainActor () async -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            action.title,
            isPresented: Binding(
                get: { current == action },
                set: { if !$0 { current = nil } }),
            titleVisibility: .visible
        ) {
            Button(action.buttonTitle, role: action.isDestructive ? .destructive : nil) {
                current = nil
                Task { await perform() }
            }
            Button("Cancel", role: .cancel) { current = nil }
        } message: {
            Text(action.message)
        }
    }
}

extension View {
    fileprivate func syncConfirmation(
        _ action: SyncConfirmation, current: Binding<SyncConfirmation?>,
        perform: @escaping @MainActor () async -> Void
    ) -> some View {
        modifier(SyncConfirmationModifier(action: action, current: current, perform: perform))
    }
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
