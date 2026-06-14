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

    // MARK: Create-on-demand

    /// Ids for playlists that don't exist yet carry this prefix; the add intent
    /// creates the playlist when it sees one. Lets "add this to Watch Later" work
    /// even before you've made a Watch Later playlist.
    static let createPrefix = "create:"

    static func toCreate(named name: String) -> PlaylistEntity {
        PlaylistEntity(id: createPrefix + name, name: name)
    }

    /// True when this entity stands for a playlist that should be created.
    var isNew: Bool { id.hasPrefix(Self.createPrefix) }
}

/// Resolves playlists by id and by spoken name (`EntityStringQuery`), so a user
/// can say the playlist out loud and Siri matches it.
struct PlaylistEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [PlaylistEntity.ID]) async throws -> [PlaylistEntity] {
        let playlists = IntentDataStore.playlists()
        return identifiers.compactMap { id in
            // A "create:" id round-trips as a to-be-created playlist.
            if id.hasPrefix(PlaylistEntity.createPrefix) {
                return PlaylistEntity(id: id, name: String(id.dropFirst(PlaylistEntity.createPrefix.count)))
            }
            return playlists.first { $0.id.uuidString == id }.map(PlaylistEntity.init)
        }
    }

    @MainActor
    func entities(matching string: String) async throws -> [PlaylistEntity] {
        let matches = IntentDataStore.playlists()
            .filter { $0.name.localizedCaseInsensitiveContains(string) }
            .map(PlaylistEntity.init)
        guard matches.isEmpty else { return matches }
        // No playlist by that name yet — offer to create it instead of failing.
        let name = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? [] : [PlaylistEntity.toCreate(named: name)]
    }

    @MainActor
    func suggestedEntities() async throws -> [PlaylistEntity] {
        IntentDataStore.playlists().map(PlaylistEntity.init)
    }
}
