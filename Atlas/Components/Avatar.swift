import PipedKit
import SwiftUI
import UIKit

/// Circular channel avatar.
struct Avatar: View {
    @Environment(AppModel.self) private var app
    @Environment(\.displayScale) private var displayScale

    let url: String?
    var size: CGFloat = 40
    var networkScope: RemoteResourceScope = .publicInternet

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Circle().fill(.quaternary).overlay(
                    Image(systemName: "person.fill").foregroundStyle(.secondary)
                )
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
        .task(id: loadKey) { await load() }
    }

    private var loadKey: String {
        let generation = networkScope == .selectedInstance ? app.instanceGeneration : 0
        return "\(generation)|\(url ?? "")|\(size)|\(displayScale)"
    }

    private func load() async {
        image = nil
        guard let url, !url.isEmpty else { return }
        let client: PolicyHTTPClient?
        let namespace: String
        switch networkScope {
        case .selectedInstance:
            client = try? app.httpClient
            namespace = "instance:\(app.instanceGeneration)"
        case .publicInternet:
            client = AppModel.publicHTTPClient
            namespace = "public"
        }
        let policy = AvatarRetryPolicy.shared
        var retry = 0
        while !Task.isCancelled {
            guard await policy.shouldAttempt(url) else { return }
            let loaded = await ThumbnailImagePipeline.shared.image(
                original: url,
                upgraded: nil,
                displaySize: CGSize(width: size, height: size),
                scale: displayScale,
                client: client,
                namespace: namespace)
            guard !Task.isCancelled else { return }
            if let loaded {
                await policy.recordSuccess(url)
                image = loaded
                return
            }
            await policy.recordFailure(url)
            // Retry a couple of times while still on screen; the task is
            // cancelled (and the loop ends) as soon as the row scrolls away.
            guard let delay = policy.inViewDelay(forRetry: retry) else { return }
            retry += 1
            guard (try? await Task.sleep(for: delay)) != nil else { return }
        }
    }
}
