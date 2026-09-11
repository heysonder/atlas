import Foundation
import PipedKit
import SwiftData

/// The complete portable preference allowlist. Device consent, instances,
/// diagnostics, account enrollment and playback state cannot enter this store.
@MainActor
enum SyncPreferences {
    static let sponsorCategoryPrefix = "atlas.sponsorBlock.category."
    private static weak var attachedApp: AppModel?
    private static var attachedContext: ModelContext?
    private static var defaults: UserDefaults = .standard
    private static var isProjecting = false

    static var allowedKeys: Set<String> {
        Set([
            FeedMode.storageKey, AppModel.hideShortsKey, AppModel.shortsLayoutKey,
            AppModel.playerStyleKey, AppModel.sponsorBlockKey,
        ])
        .union(SponsorCategory.allCases.map { sponsorCategoryPrefix + $0.rawValue })
    }

    static func validate(key: String, value: String) -> Bool {
        switch key {
        case FeedMode.storageKey: return FeedMode(rawValue: value) != nil
        case AppModel.playerStyleKey: return PlayerStyle(rawValue: value) != nil
        case AppModel.shortsLayoutKey: return ShortsLayout(rawValue: value) != nil
        case AppModel.hideShortsKey, AppModel.sponsorBlockKey: return value == "true" || value == "false"
        default:
            guard key.hasPrefix(sponsorCategoryPrefix),
                SponsorCategory(rawValue: String(key.dropFirst(sponsorCategoryPrefix.count))) != nil
            else { return false }
            return value == "true" || value == "false"
        }
    }

    /// Called only for the durable container. Existing defaults are an
    /// unversioned migration baseline; absent defaults never create sync edits.
    static func attach(app: AppModel, in context: ModelContext, defaults source: UserDefaults = .standard) {
        attachedApp = app
        attachedContext = context
        defaults = source
        do {
            try LibrarySyncJournal.transaction(in: context, captureChanges: false) {
                let rows = try context.fetch(FetchDescriptor<SyncPreference>())
                let existingKeys = Set(rows.map(\.key))
                for key in allowedKeys where !existingKeys.contains(key) {
                    guard let value = legacyValue(key: key, defaults: source) else { continue }
                    context.insert(SyncPreference(key: key, value: value, isExplicit: false))
                    try LibrarySyncJournal.capture(kind: .preference, entityID: key, in: context)
                }
            }
            project(in: context, app: app)
        } catch {
            // Existing defaults remain usable if the disk transaction fails.
        }
    }

    /// Explicit control actions write the preference and outbox in one save.
    @discardableResult
    static func set(
        key: String, value: String, in context: ModelContext, projectValue: Bool = true
    ) -> Bool {
        guard validate(key: key, value: value) else { return false }
        do {
            try LibrarySyncJournal.transaction(in: context, captureChanges: false) {
                let descriptor = FetchDescriptor<SyncPreference>(predicate: #Predicate { $0.key == key })
                if let row = try context.fetch(descriptor).first {
                    guard row.value != value || !row.isExplicit else { return }
                    row.value = value
                    row.isExplicit = true
                    row.modifiedAt = .now
                } else {
                    context.insert(SyncPreference(key: key, value: value, isExplicit: true))
                }
                try LibrarySyncJournal.capture(kind: .preference, entityID: key, in: context)
            }
            if projectValue { applySyncedValue(key: key, value: value) }
            return true
        } catch {
            return false
        }
    }

    /// AppModel's existing property setters remain the UI's single entry point.
    /// Projection after a remote save is fenced so it cannot echo a new edit.
    static func recordAppEdit(app: AppModel, key: String, value: String, previousValue: String) {
        guard !isProjecting, app === attachedApp, let context = attachedContext else { return }
        if !set(key: key, value: value, in: context) {
            applySyncedValue(key: key, value: previousValue)
        }
    }

    static func project(in context: ModelContext, app: AppModel? = nil) {
        guard let rows = try? context.fetch(FetchDescriptor<SyncPreference>()) else { return }
        if let app { attachedApp = app }
        for row in rows { applySyncedValue(key: row.key, value: row.value) }
    }

    static func applySyncedValue(key: String, value: String) {
        guard validate(key: key, value: value) else { return }
        let wasProjecting = isProjecting
        isProjecting = true
        defer { isProjecting = wasProjecting }
        let app = attachedApp
        switch key {
        case FeedMode.storageKey:
            defaults.set(value, forKey: key)
        case AppModel.playerStyleKey:
            defaults.set(value, forKey: key)
            if let style = PlayerStyle(rawValue: value), app?.playerStyle != style { app?.playerStyle = style }
        case AppModel.shortsLayoutKey:
            defaults.set(value, forKey: key)
            if let layout = ShortsLayout(rawValue: value), app?.shortsLayout != layout { app?.shortsLayout = layout }
        case AppModel.hideShortsKey:
            let enabled = value == "true"
            defaults.set(enabled, forKey: key)
            if app?.hideShorts != enabled { app?.hideShorts = enabled }
        case AppModel.sponsorBlockKey:
            let enabled = value == "true"
            defaults.set(enabled, forKey: key)
            if app?.sponsorBlockEnabled != enabled { app?.sponsorBlockEnabled = enabled }
        default:
            guard let category = SponsorCategory(rawValue: String(key.dropFirst(sponsorCategoryPrefix.count))) else {
                return
            }
            let enabled = value == "true"
            var categories =
                (defaults.array(forKey: AppModel.sponsorCategoriesKey) as? [String])
                .map { Set($0) } ?? Set(AppModel.defaultSponsorCategories.map(\.rawValue))
            if enabled { categories.insert(category.rawValue) } else { categories.remove(category.rawValue) }
            defaults.set(categories.sorted(), forKey: AppModel.sponsorCategoriesKey)
            if app?.isSponsorCategoryEnabled(category) != enabled {
                app?.setSponsorCategory(category, enabled: enabled)
            }
        }
    }

    private static func legacyValue(key: String, defaults: UserDefaults) -> String? {
        if key.hasPrefix(sponsorCategoryPrefix) {
            guard let values = defaults.array(forKey: AppModel.sponsorCategoriesKey) as? [String] else { return nil }
            return values.contains(String(key.dropFirst(sponsorCategoryPrefix.count))) ? "true" : "false"
        }
        guard defaults.object(forKey: key) != nil else { return nil }
        let value: String?
        if key == AppModel.hideShortsKey || key == AppModel.sponsorBlockKey {
            value = defaults.bool(forKey: key) ? "true" : "false"
        } else {
            value = defaults.string(forKey: key)
        }
        guard let value, validate(key: key, value: value) else { return nil }
        return value
    }
}

/// Adapter boundary: projection happens only after incoming SwiftData saves.
@MainActor
enum PortablePreferenceStore {
    static func applySyncedValue(key: String, value: String) {
        SyncPreferences.applySyncedValue(key: key, value: value)
    }

    static func validate(key: String, value: String) -> Bool {
        SyncPreferences.validate(key: key, value: value)
    }
}
