import AppIntents
import PipedKit
import SwiftUI

extension View {
    /// Records the videos currently on screen so Siri / App Intents can resolve
    /// nearby video actions from the visible registry.
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
