import SwiftUI

/// Reusable error view with a retry button.
struct ErrorState: View {
    let message: String
    var retry: (() async -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label("Something went wrong", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            if let retry {
                Button("Try Again") { Task { await retry() } }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
