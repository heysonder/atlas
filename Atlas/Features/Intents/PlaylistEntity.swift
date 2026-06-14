import AppIntents
import Foundation

/// A playlist exposed to Siri / App Intents. Because it's an `AppEntity`, it can
/// be spoken inside a shortcut phrase ("Add this to <playlist>") — unlike a plain
/// `String` — and Siri matches the spoken name via the query below.
struct PlaylistEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Playlist")
    static let defaultQuery = PlaylistEntityQuery()

    /// The playlist's UUID, as a string (App Intents ids must be Codable & Sendable).
    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    init(_ playlist: Playlist) {
        self.init(id: playlist.id.uuidString, name: playlist.name)
    }
}

/// Resolves playlists by id and by spoken name (`EntityStringQuery`), so a user
/// can say the playlist out loud and Siri matches it.
struct PlaylistEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [PlaylistEntity.ID]) async throws -> [PlaylistEntity] {
        let wanted = Set(identifiers)
        return IntentDataStore.playlists()
            .filter { wanted.contains($0.id.uuidString) }
            .map(PlaylistEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [PlaylistEntity] {
        IntentDataStore.playlists()
            .filter { $0.name.localizedCaseInsensitiveContains(string) }
            .map(PlaylistEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [PlaylistEntity] {
        IntentDataStore.playlists().map(PlaylistEntity.init)
    }
}
