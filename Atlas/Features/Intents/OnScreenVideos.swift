import SwiftUI
import AppIntents
import PipedKit

extension View {
    /// Records the videos currently on screen so Siri / App Intents can resolve
    /// them, and — on iOS 27 — annotates the collection so Siri can act on "this
    /// video" (the one the user is looking at) without an explicit target.
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
            .modifier(SiriOnScreenAnnotation())
    }
}

/// The on-screen entity annotation, gated to iOS 27 where the API lands. The
/// selection id is `StreamItem.ID` (the video id), which we map to a `VideoEntity`.
private struct SiriOnScreenAnnotation: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 27.0, *) {
            content.appEntityIdentifier(forSelectionType: StreamItem.ID.self) { id in
                EntityIdentifier(for: VideoEntity.self, identifier: id)
            }
        } else {
            content
        }
    }
}
