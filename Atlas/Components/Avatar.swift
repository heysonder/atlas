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
    /// See `Thumbnail.revealed`: only avatars that landed on a blank circle
    /// animate in.
    @State private var revealed = true
    /// See `Thumbnail.loadsInFlight`.
    @State private var loadsInFlight = 0

    var body: some View {
        let shown = image ?? (loadsInFlight > 0 ? nil : cachedImage?.image)
        let rememberedColor = ImageToneStore.shared.tone(for: url)?.averageColor
        ZStack {
            Circle().fill(rememberedColor.map { AnyShapeStyle(Color(uiColor: $0)) } ?? AnyShapeStyle(.quaternary))
            if let image = shown {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .imageReveal(revealed)
                    .onAppear {
                        guard !revealed else { return }
                        withAnimation(.imageReveal) { revealed = true }
                    }
            } else if rememberedColor == nil {
                Image(systemName: "person.fill").foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .imageEdge(Circle(), url: url)
        .accessibilityHidden(true)
        .task(id: loadKey) { await load() }
    }

    private var namespace: String {
        switch networkScope {
        case .selectedInstance: "instance:\(app.instanceGeneration)"
        case .publicInternet: "public"
        }
    }

    private var upgradedURL: String? {
        ThumbnailURL.upgraded(url, pixelWidth: Int((size * displayScale).rounded(.up)))
    }

    /// Synchronous memory-cache hit, so a returning row never shows the glyph.
    private var cachedImage: ThumbnailImagePipeline.LoadedImage? {
        ThumbnailImagePipeline.shared.cachedImage(
            original: url, upgraded: upgradedURL,
            displaySize: CGSize(width: size, height: size),
            scale: displayScale, namespace: namespace)
    }

    private var loadKey: String {
        let generation = networkScope == .selectedInstance ? app.instanceGeneration : 0
        return "\(generation)|\(url ?? "")|\(size)|\(displayScale)"
    }

    private func load() async {
        image = nil
        guard let url, !url.isEmpty else { return }
        let wasBlank = cachedImage == nil
        loadsInFlight += 1
        defer { loadsInFlight -= 1 }
        let client: PolicyHTTPClient? =
            switch networkScope {
            case .selectedInstance: try? app.httpClient
            case .publicInternet: AppModel.publicHTTPClient
            }
        let policy = AvatarRetryPolicy.shared
        var retry = 0
        while !Task.isCancelled {
            guard await policy.shouldAttempt(url) else { return }
            let loaded = await ThumbnailImagePipeline.shared.load(
                original: url,
                upgraded: upgradedURL,
                displaySize: CGSize(width: size, height: size),
                scale: displayScale,
                client: client,
                namespace: namespace)
            guard !Task.isCancelled else { return }
            if let loaded {
                await policy.recordSuccess(url)
                if wasBlank { revealed = false }
                image = loaded.image
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
