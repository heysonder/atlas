import AppIntents

/// The phrases that expose Atlas's intents to Siri, Spotlight, and the Shortcuts
/// app. `\(.applicationName)` lets users say "Atlas" (or whatever they've renamed
/// the app to) without us hardcoding it.
struct AtlasShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // A ShowInAppSearchResultsIntent: Siri recognizes "search for … in Atlas"
        // natively and fills the term, so these phrases are just for discovery in
        // Spotlight / the Shortcuts app.
        AppShortcut(
            intent: ShowSearchResultsIntent(),
            phrases: [
                "Search \(.applicationName)",
                "Search in \(.applicationName)",
            ],
            shortTitle: "Search",
            systemImageName: "magnifyingglass")

        AppShortcut(
            intent: ResumeWatchingIntent(),
            phrases: [
                "Resume watching in \(.applicationName)",
                "Continue watching in \(.applicationName)",
            ],
            shortTitle: "Resume Watching",
            systemImageName: "play.fill")

        AppShortcut(
            intent: OpenForYouIntent(),
            phrases: [
                "Show my \(.applicationName) feed",
                "Open For You in \(.applicationName)",
            ],
            shortTitle: "For You",
            systemImageName: "sparkles")

        AppShortcut(
            intent: OpenDownloadsIntent(),
            phrases: [
                "Open \(.applicationName) downloads",
                "Show my downloads in \(.applicationName)",
            ],
            shortTitle: "Downloads",
            systemImageName: "arrow.down.circle")

        AppShortcut(
            intent: PlayVideoIntent(),
            phrases: ["Play this in \(.applicationName)"],
            shortTitle: "Play",
            systemImageName: "play.fill")

        AppShortcut(
            intent: DownloadVideoIntent(),
            phrases: ["Download this in \(.applicationName)"],
            shortTitle: "Download",
            systemImageName: "arrow.down.circle")

        // The playlist is an AppEntity, so — unlike the search String — it CAN be
        // spoken inside the phrase, and the query matches it by name.
        AppShortcut(
            intent: AddToPlaylistIntent(),
            phrases: [
                "Add this to \(\.$playlist) in \(.applicationName)",
                "Save this to \(\.$playlist) in \(.applicationName)",
            ],
            shortTitle: "Add to Playlist",
            systemImageName: "text.badge.plus")

        // Returns videos for chaining in the Shortcuts app (Find Videos → Add to
        // Playlist). Mainly used as a building block rather than a spoken command.
        AppShortcut(
            intent: FindVideosIntent(),
            phrases: [
                "Find videos in \(.applicationName)",
                "Find \(.applicationName) videos",
            ],
            shortTitle: "Find Videos",
            systemImageName: "sparkle.magnifyingglass")
    }
}
