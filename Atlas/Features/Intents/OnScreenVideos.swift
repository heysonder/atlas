import SwiftUI
import AppIntents
import PipedKit

extension View {
    /// Records recently visible videos so App Intents can resolve their ids from
    /// the in-memory registry without another network lookup.
    func onScreenVideos(_ videos: [StreamItem]) -> some View {
        modifier(OnScreenVideos(videos: videos))
    }
}

private struct OnScreenVideos: ViewModifier {
    let videos: [StreamItem]

    func body(content: Content) -> some View {
        content
            .onAppear { VisibleVideoRegistry.shared.record(videos) }
            .onChange(of: videos.map(\.id)) { _, _ in
                VisibleVideoRegistry.shared.record(videos)
            }
    }
}
