import AppIntents
import CoreSpotlight
import Foundation

/// Handoff / continuity activities. Types are registered under
/// `NSUserActivityTypes` in project.yml. `webpageURL` is set so a Mac without
/// Atlas continues in Safari on youtube.com.
enum AtlasActivity {
    static let watch = "sh.cmf.atlas.watch"
    static let channel = "sh.cmf.atlas.channel"

    static let videoIDKey = "videoID"
    static let titleKey = "title"
    static let uploaderKey = "uploader"
    static let thumbnailKey = "thumbnail"
    static let channelIDKey = "channelID"

    static func configureWatch(_ activity: NSUserActivity, request: PlayRequest) {
        activity.title = request.title
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false  // videos are indexed as entities already
        activity.isEligibleForPrediction = true
        activity.webpageURL = URL(string: "https://www.youtube.com/watch?v=\(request.videoID)")
        var info: [String: Any] = [videoIDKey: request.videoID, titleKey: request.title]
        if let uploader = request.uploader { info[uploaderKey] = uploader }
        if let thumbnail = request.thumbnail, !thumbnail.hasPrefix("file:") {
            info[thumbnailKey] = thumbnail
        }
        activity.addUserInfoEntries(from: info)
        activity.requiredUserInfoKeys = [videoIDKey]
        // Onscreen awareness (iOS 26+): lets Siri resolve "this video" / "download
        // this" against what's playing without our on-screen registry.
        activity.appEntityIdentifier = EntityIdentifier(for: VideoEntity.self, identifier: request.videoID)
    }

    static func configureChannel(_ activity: NSUserActivity, channelID: String, name: String) {
        activity.title = name
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        activity.isEligibleForPrediction = true
        activity.webpageURL = URL(string: "https://www.youtube.com/channel/\(channelID)")
        activity.addUserInfoEntries(from: [channelIDKey: channelID])
        activity.requiredUserInfoKeys = [channelIDKey]
        activity.appEntityIdentifier = EntityIdentifier(for: ChannelEntity.self, identifier: channelID)
    }
}

/// `atlas://` deep links, for Shortcuts automations and external launchers.
///
///     atlas://resume            resume the last watch
///     atlas://search?q=term     open search (empty q focuses the field)
///     atlas://downloads         Library → Downloads
///     atlas://feed              Home
///     atlas://channel/<id>      a channel page
enum AtlasURL {
    static let scheme = "atlas"

    static func action(for url: URL) -> AtlasIntentAction? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let host = url.host()?.lowercased() ?? ""
        let path = url.pathComponents.filter { $0 != "/" }
        switch host {
        case "resume": return .resumeWatching
        case "downloads": return .openDownloads
        case "feed": return .forYou
        case "playlists": return .openPlaylists
        case "search":
            let q =
                URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "q" }?.value ?? ""
            return .search(q)
        case "channel":
            guard let id = path.first, !id.isEmpty else { return nil }
            return .openChannel(id)
        default: return nil
        }
    }
}
