import SwiftUI

/// Reusable error view with a retry button. When the failure is the
/// "no Piped instance configured" case, shows `MissingInstanceView` instead
/// so the fix (pick an instance) is one tap away rather than a dead retry.
struct ErrorState: View {
    let message: String
    var retry: (() async -> Void)?

    var body: some View {
        if message == AppModel.missingInstanceMessage {
            MissingInstanceView()
        } else {
            ContentUnavailableView {
                Label("Something went wrong", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                if let retry {
                    Button("Try again") { Task { await retry() } }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                }
            }
        }
    }
}

/// Empty state shown anywhere online features are requested before a Piped
/// instance has been chosen. Atlas deliberately ships no default instance:
/// the view opens Instance settings and links to self-hosting and instance
/// resources instead of quietly pointing the user at a third-party server.
struct MissingInstanceView: View {
    @Environment(AppModel.self) private var app

    static let pipedForAtlasURL = URL(string: "https://github.com/heysonder/piped")!
    static let pipedDocsURL = URL(string: "https://docs.piped.video/docs/self-hosting/")!
    static let privacyGuidesURL = URL(string: "https://www.privacyguides.org/en/frontends/")!

    var body: some View {
        ContentUnavailableView {
            Label("Choose a Piped instance", systemImage: "server.rack")
        } description: {
            Text(
                "Video, search, and subscriptions load through the instance you pick. "
                    + "Atlas does not ship with a default. Self-hosting keeps your traffic on a server you control."
            )
        } actions: {
            VStack(spacing: 12) {
                Button("Open settings") {
                    app.libraryTarget = .instanceSettings
                    app.selectedTab = .profile
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)

                VStack(spacing: 6) {
                    Link("Self-host Piped for Atlas", destination: Self.pipedForAtlasURL)
                    Link("Piped self-hosting docs", destination: Self.pipedDocsURL)
                    Link("Privacy Guides: choosing a frontend", destination: Self.privacyGuidesURL)
                }
                .font(.footnote)
            }
        }
    }
}
