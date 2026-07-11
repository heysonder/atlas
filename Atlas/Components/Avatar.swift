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
        let loaded = await ThumbnailImagePipeline.shared.image(
            original: url,
            upgraded: nil,
            displaySize: CGSize(width: size, height: size),
            scale: displayScale,
            client: client,
            namespace: namespace)
        guard !Task.isCancelled else { return }
        image = loaded
    }
}
