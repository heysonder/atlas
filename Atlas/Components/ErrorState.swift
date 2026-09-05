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
/// instance has been chosen. Offers the Instance settings screen and a one-tap
/// default so the user is never stuck.
struct MissingInstanceView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ContentUnavailableView {
            Label("Choose a Piped instance", systemImage: "server.rack")
        } description: {
            Text("Video, search, and subscriptions load through the instance you pick.")
        } actions: {
            VStack(spacing: 12) {
                Button("Open settings") {
                    app.libraryTarget = .instanceSettings
                    app.selectedTab = .profile
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)

                Button("Use the default") {
                    app.instanceURLString = AppModel.defaultInstanceURL
                }
            }
        }
    }
}
