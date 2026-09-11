import Foundation
import PipedKit
import SwiftData
import Testing

@testable import Atlas

@MainActor
@Suite("Cloud sync recommendation activity", .serialized)
struct CloudSyncActivityTests {
    @Test func oneEventDrivesTrainingAndImpressionCount() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let recorded = RecommendationOutcomeStore.record(
            [
                .init(videoID: "a", position: 0, features: RecommendationSyncFeatures.empty.features),
                .init(videoID: "a", position: 1, features: RecommendationSyncFeatures.empty.features),
            ], in: context)
        let rows = try context.fetch(FetchDescriptor<RecommendationOutcomeEntry>())
        #expect(rows.count == 1)
        #expect(rows.first?.eventID == recorded["a"])
        #expect(rows.first?.contributesToImpressions == true)
        #expect(FeedImpressionStore.counts(in: context)["a"] == 1)
        let state = try SyncStoreAdapter(context: context).state(
            kind: .activity, entityID: #require(recorded["a"]).uuidString.lowercased())
        #expect(state?.localRevision ?? 0 > 0)
        #expect(state?.materializedPayload != nil)
    }

    @Test func aRemoteNewerImpressionDoesNotStealTheDisplayedTap() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let now = Date()
        let ids = RecommendationOutcomeStore.record(
            [
                .init(videoID: "a", position: 0, features: RecommendationSyncFeatures.empty.features)
            ], in: context, now: now.addingTimeInterval(-20))
        let remote = RecommendationOutcomeEntry(
            videoID: "a", shownAt: now.addingTimeInterval(-10), position: 3,
            features: RecommendationSyncFeatures.empty.features, originID: "other-device")
        let remoteID = try #require(remote.eventID)
        let payload = try RecommendationActivityPayload(remote)
        try RecommendationSyncBridge.apply(
            kind: .activity,
            entityID: remoteID.uuidString.lowercased(), payload: SyncPayload.encode(payload), in: context)
        try context.save()

        // Compatibility callers also retain the exact context-local render ID.
        RecommendationOutcomeStore.recordTap("a", in: context, now: now)
        let rows = try context.fetch(FetchDescriptor<RecommendationOutcomeEntry>())
        #expect(rows.first { $0.eventID == ids["a"] }?.tapped == true)
        #expect(rows.first { $0.eventID == remoteID }?.tapped == false)
        #expect(FeedImpressionStore.counts(in: context)["a"] == nil)
    }

    @Test func replayingAnEventDoesNotDoubleCount() throws {
        let sourceContainer = try makeTestContainer()
        let targetContainer = try makeTestContainer()
        let source = sourceContainer.mainContext
        let target = targetContainer.mainContext
        RecommendationOutcomeStore.record(
            [
                .init(videoID: "a", position: 0, features: RecommendationSyncFeatures.empty.features)
            ], in: source)
        let events = try RecommendationSyncBridge.snapshots(in: source)
            .filter { $0.kind == .activity && $0.entityID != RecommendationSyncBridge.retentionEntityID }
        let event = try #require(events.first)
        for _ in 0..<3 {
            try RecommendationSyncBridge.apply(
                kind: event.kind, entityID: event.entityID, payload: event.payload, in: target)
        }
        #expect(try target.fetchCount(FetchDescriptor<RecommendationOutcomeEntry>()) == 1)
        #expect(FeedImpressionStore.counts(in: target)["a"] == 1)
    }

    @Test func legacyAggregateDoesNotCountHistoricalOutcomesTwice() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        context.insert(FeedImpressionEntry(videoID: "a", count: 4))
        let old = RecommendationOutcomeEntry(
            videoID: "a", shownAt: .now, position: 0,
            features: RecommendationSyncFeatures.empty.features, contributesToImpressions: false)
        old.eventID = nil
        old.originID = "legacy"
        context.insert(old)
        try RecommendationSyncBridge.prepare(in: context)
        let firstID = try #require(old.eventID)
        try RecommendationSyncBridge.prepare(in: context)
        try FeedImpressionStore.rebuild(in: context)
        #expect(old.eventID == firstID)
        #expect(try context.fetchCount(FetchDescriptor<FeedImpressionBaseline>()) == 1)
        #expect(FeedImpressionStore.counts(in: context)["a"] == 4)
        RecommendationOutcomeStore.record(
            [
                .init(videoID: "a", position: 0, features: RecommendationSyncFeatures.empty.features)
            ], in: context)
        #expect(FeedImpressionStore.counts(in: context)["a"] == 5)
    }

    @Test func concurrentTapProjectionIsCommutativeAndCannotBeLost() throws {
        let row = RecommendationOutcomeEntry(
            videoID: "a", shownAt: Date().addingTimeInterval(-30),
            position: 0, features: RecommendationSyncFeatures.empty.features)
        let untouched = try RecommendationActivityPayload(row)
        var tapped = untouched
        tapped.tappedAt = Date().addingTimeInterval(-10)
        let first = try SyncPayload.encode(untouched)
        let second = try SyncPayload.encode(tapped)
        let id = untouched.eventID.uuidString.lowercased()
        let forward = try RecommendationSyncBridge.mergedPayloads(
            kind: .activity, entityID: id, payloads: [first, second])
        let reversed = try RecommendationSyncBridge.mergedPayloads(
            kind: .activity, entityID: id, payloads: [second, first])
        #expect(forward == reversed)
        let decoded = try SyncPayload.decode(RecommendationActivityPayload.self, from: #require(forward))
        #expect(decoded.tappedAt == tapped.tappedAt)
    }

    @Test func conflictingCreationContentAndUnboundedFeaturesAreRejected() throws {
        let row = RecommendationOutcomeEntry(
            videoID: "a", shownAt: .now, position: 0,
            features: RecommendationSyncFeatures.empty.features)
        let payload = try RecommendationActivityPayload(row)
        let id = payload.eventID.uuidString.lowercased()
        var conflict = payload
        conflict.videoID = "b"
        let originals = try [SyncPayload.encode(payload), SyncPayload.encode(conflict)]
        #expect(throws: SyncProtocolError.invalidPayload) {
            try RecommendationSyncBridge.mergedPayloads(kind: .activity, entityID: id, payloads: originals)
        }
        var invalid = payload
        invalid.features.topicSimilarity = .infinity
        #expect(throws: SyncProtocolError.invalidPayload) { try invalid.validate(entityID: id) }
        invalid = payload
        invalid.shownAt = Date().addingTimeInterval(3 * 86_400)
        #expect(throws: SyncProtocolError.invalidPayload) { try invalid.validate(entityID: id) }
    }

    @Test func unknownFeatureVersionsRemainStoredButCannotTrain() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let row = RecommendationOutcomeEntry(
            videoID: "future", shownAt: .now, position: 0,
            features: RecommendationSyncFeatures.empty.features, featureSchemaVersion: 42)
        let payload = try RecommendationActivityPayload(row)
        try RecommendationSyncBridge.apply(
            kind: .activity,
            entityID: payload.eventID.uuidString.lowercased(), payload: SyncPayload.encode(payload), in: context)
        let restored = try #require(try context.fetch(FetchDescriptor<RecommendationOutcomeEntry>()).first)
        #expect(restored.featureSchemaVersion == 42)
        #expect(!restored.isEligibleForTraining)
    }

    @Test func unknownFeatureLayoutSurvivesProjectionAndTapUpdates() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let now = Date()
        let row = RecommendationOutcomeEntry(
            videoID: "future-layout", shownAt: now.addingTimeInterval(-5),
            position: 0, features: RecommendationSyncFeatures.empty.features, featureSchemaVersion: 77)
        let value = try RecommendationActivityPayload(row)
        var object = try #require(try JSONSerialization.jsonObject(with: SyncPayload.encode(value)) as? [String: Any])
        object["features"] = ["futureVector": [0.125, 0.25, 0.5], "layout": "v77"]
        let original = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let id = value.eventID.uuidString.lowercased()
        try RecommendationSyncBridge.apply(kind: .activity, entityID: id, payload: original, in: context)
        try context.save()
        RecommendationOutcomeStore.recordTap(eventID: value.eventID, in: context, now: now)
        let snapshot = try #require(
            try RecommendationSyncBridge.snapshots(in: context, kind: .activity, entityID: id).first)
        let restored = try #require(try JSONSerialization.jsonObject(with: snapshot.payload) as? [String: Any])
        let features = try #require(restored["features"] as? [String: Any])
        #expect(features["futureVector"] as? [Double] == [0.125, 0.25, 0.5])
        #expect(features["layout"] as? String == "v77")
        #expect(restored["tappedAt"] != nil)
    }

    @Test func retentionCutoffOrdersEqualTimeEventsAndRejectsReplays() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let now = Date()
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let cutoff = RecommendationRetentionPayload(cutoff: now, eventID: firstID.uuidString.lowercased())
        #expect(cutoff.contains(date: now, id: firstID))
        #expect(!cutoff.contains(date: now, id: secondID))
        try RecommendationSyncBridge.apply(
            kind: .activity, entityID: RecommendationSyncBridge.retentionEntityID,
            payload: SyncPayload.encode(cutoff), in: context)
        for id in [firstID, secondID] {
            let row = RecommendationOutcomeEntry(
                videoID: id.uuidString, shownAt: now, position: 0,
                features: RecommendationSyncFeatures.empty.features, eventID: id)
            try RecommendationSyncBridge.apply(
                kind: .activity, entityID: id.uuidString.lowercased(),
                payload: SyncPayload.encode(RecommendationActivityPayload(row)), in: context)
        }
        let rows = try context.fetch(FetchDescriptor<RecommendationOutcomeEntry>())
        #expect(rows.map(\.eventID) == [secondID])
    }

    @Test func pruningRetiresExpiredEventsAndBaselines() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        try SyncStoreAdapter(context: context).bind(accountID: "account", libraryGeneration: "library")
        try RecommendationSyncBridge.prepare(in: context)
        let event = RecommendationOutcomeEntry(
            videoID: "old", shownAt: Date().addingTimeInterval(-181 * 86_400),
            position: 0, features: RecommendationSyncFeatures.empty.features)
        let id = try #require(event.eventID).uuidString.lowercased()
        context.insert(event)
        let baseline = FeedImpressionBaseline(
            videoID: "older", count: 3,
            lastShownAt: Date().addingTimeInterval(-46 * 86_400))
        context.insert(baseline)
        // Journal both rows first, as if they had been captured for upload.
        try LibrarySyncJournal.transaction(in: context, captureChanges: false, notifySync: false) {
            try LibrarySyncJournal.capture(kind: .activity, entityID: id, in: context)
            try LibrarySyncJournal.capture(
                kind: .impressionBaseline, entityID: baseline.id.uuidString.lowercased(), in: context)
        }
        try LibrarySyncJournal.transaction(in: context, captureChanges: false, notifySync: false) {
            try RecommendationSyncBridge.prune(in: context)
        }
        #expect(try context.fetchCount(FetchDescriptor<RecommendationOutcomeEntry>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<FeedImpressionBaseline>()) == 0)
        // Expiry retires the journal row into a pending physical cloud deletion. It
        // does not write a causal tombstone: only the shared retention barrier may
        // remove an event from other devices, so a wrong local clock cannot.
        let adapter = SyncStoreAdapter(context: context)
        let state = try #require(try adapter.state(kind: .activity, entityID: id))
        #expect(state.isObsolete)
        #expect(state.materializedPayload == nil)
        #expect(try adapter.pendingDeletions().contains { $0.envelope.entityID == id })
        #expect(try adapter.pendingRecords().allSatisfy { $0.envelope.entityID != id })
        // A never-journaled row simply disappears; there is nothing to retire.
        let orphan = RecommendationOutcomeEntry(
            videoID: "orphan", shownAt: Date().addingTimeInterval(-200 * 86_400),
            position: 0, features: RecommendationSyncFeatures.empty.features)
        let orphanID = try #require(orphan.eventID).uuidString.lowercased()
        context.insert(orphan)
        try RecommendationSyncBridge.prune(in: context)
        #expect(try adapter.state(kind: .activity, entityID: orphanID) == nil)
    }

    @Test func aFutureLocalClockCannotDeleteOtherDevicesEvents() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        try SyncStoreAdapter(context: context).bind(accountID: "account", libraryGeneration: "library")
        let state = try RecommendationSyncBridge.prepare(in: context)
        let now = Date()
        let remoteID = UUID()
        let remote = RecommendationOutcomeEntry(
            videoID: "remote", shownAt: now.addingTimeInterval(-10 * 86_400),
            position: 0, features: RecommendationSyncFeatures.empty.features, eventID: remoteID,
            originID: "other-device")
        // Received through the sync adapter, so a journal row exists as it would after a fetch.
        let incoming = try SyncEnvelope.mutation(
            kind: .activity, entityID: remoteID.uuidString.lowercased(),
            payload: SyncPayload.encode(RecommendationActivityPayload(remote)), writerID: "other-device:1", counter: 1)
        try SyncStoreAdapter(context: context).apply(incoming)
        // This device's clock jumps 200 days ahead and it prunes.
        try LibrarySyncJournal.transaction(in: context, captureChanges: false, notifySync: false) {
            try RecommendationSyncBridge.prune(in: context, now: now.addingTimeInterval(200 * 86_400))
        }
        let adapter = SyncStoreAdapter(context: context)
        // The local copy is gone and the cloud copy is queued for collection, but no
        // causal removal exists that another device would have to honor.
        let row = try #require(try adapter.state(kind: .activity, entityID: remoteID.uuidString.lowercased()))
        #expect(row.isObsolete)
        #expect(try adapter.pendingRecords().allSatisfy { $0.envelope.entityID != remoteID.uuidString.lowercased() })
        // The bad barrier is uploaded but rejected by every sane receiver, and a
        // later prune on this device with a corrected clock discards it locally.
        let retention = RecommendationRetentionPayload(cutoff: state.retentionCutoff, eventID: state.retentionEventID)
        #expect(retention.cutoff > now)
        #expect(throws: SyncProtocolError.self) { try retention.validate(now: now) }
        try RecommendationSyncBridge.prune(in: context, now: now)
        #expect(state.retentionCutoff <= now)
        // Fresh events record normally again after the correction.
        let fresh = UUID()
        let freshRow = RecommendationOutcomeEntry(
            videoID: "fresh", shownAt: now, position: 0,
            features: RecommendationSyncFeatures.empty.features, eventID: fresh, originID: "other-device")
        try RecommendationSyncBridge.apply(
            kind: .activity, entityID: fresh.uuidString.lowercased(),
            payload: SyncPayload.encode(RecommendationActivityPayload(freshRow)), in: context)
        #expect(try context.fetch(FetchDescriptor<RecommendationOutcomeEntry>()).contains { $0.eventID == fresh })
    }

    @Test func expiringAnOldTappedOutcomeDoesNotResurrectRecentPenalties() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let now = Date()
        try RecommendationSyncBridge.prepare(in: context)
        let old = RecommendationOutcomeEntry(
            videoID: "a", shownAt: now.addingTimeInterval(-179 * 86_400),
            position: 0, features: RecommendationSyncFeatures.empty.features)
        context.insert(old)
        context.insert(
            RecommendationOutcomeEntry(
                videoID: "a", shownAt: now.addingTimeInterval(-10 * 86_400),
                position: 0, features: RecommendationSyncFeatures.empty.features))
        context.insert(FeedImpressionBaseline(videoID: "a", count: 4, lastShownAt: now.addingTimeInterval(-9 * 86_400)))
        RecommendationOutcomeStore.recordTap(eventID: try #require(old.eventID), in: context, now: now)
        try RecommendationSyncBridge.prune(in: context, now: now.addingTimeInterval(2 * 86_400))
        try FeedImpressionStore.rebuild(in: context, now: now.addingTimeInterval(2 * 86_400))
        #expect(try context.fetchCount(FetchDescriptor<RecommendationOutcomeEntry>()) == 1)
        #expect(FeedImpressionStore.counts(in: context)["a"] == nil)
        let resetCount = try context.fetch(FetchDescriptor<FeedImpressionBaseline>()).filter { $0.count == 0 }.count
        #expect(resetCount == 1)
    }

    @Test func delayedBaselineClearPreservesNewActivityAfterActivityClear() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        try RecommendationSyncBridge.prepare(in: context)
        context.insert(FeedImpressionBaseline(videoID: "legacy", count: 4, lastShownAt: .now))
        try RecommendationSyncBridge.reset(kind: .activity, in: context)
        let current = RecommendationOutcomeEntry(
            videoID: "new", shownAt: .now, position: 0,
            features: RecommendationSyncFeatures.empty.features)
        context.insert(current)
        // Another page brings only the baseline clear; the new-generation event survives.
        try RecommendationSyncBridge.reset(kind: .impressionBaseline, in: context)
        #expect(try context.fetchCount(FetchDescriptor<RecommendationOutcomeEntry>()) == 1)
        #expect(FeedImpressionStore.counts(in: context)["new"] == 1)
        #expect(FeedImpressionStore.counts(in: context)["legacy"] == nil)
    }

    @Test func portablePreferencesExcludeDeviceConsentAndValidateValues() {
        #expect(SyncPreferences.allowedKeys.count == 5 + SponsorCategory.allCases.count)
        for key in [
            AppModel.instanceKey, AppModel.statsForNerdsKey,
            "atlas.sync.enabled", "atlas.collaboratorLookupConsent", "atlas.ageRange",
        ] {
            #expect(!SyncPreferences.validate(key: key, value: "true"))
        }
        #expect(!SyncPreferences.validate(key: FeedMode.storageKey, value: "unknown-mode"))
        #expect(!SyncPreferences.validate(key: AppModel.hideShortsKey, value: "1"))
        for category in SponsorCategory.allCases {
            #expect(
                SyncPreferences.validate(
                    key: SyncPreferences.sponsorCategoryPrefix + category.rawValue, value: "false"))
        }
    }

    @Test func preferenceEditDoesNotCaptureOrMigrateTheWholeLibrary() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        context.insert(FeedImpressionEntry(videoID: "legacy", count: 5))
        let old = RecommendationOutcomeEntry(
            videoID: "legacy", shownAt: .now, position: 0,
            features: RecommendationSyncFeatures.empty.features, contributesToImpressions: false)
        old.eventID = nil
        context.insert(old)
        #expect(SyncPreferences.set(key: AppModel.hideShortsKey, value: "true", in: context, projectValue: false))
        #expect(try context.fetchCount(FetchDescriptor<RecommendationActivityState>()) == 0)
        #expect(old.eventID == nil)
        let records = try context.fetch(FetchDescriptor<SyncRecordState>())
        #expect(records.count == 1)
        #expect(records.first?.kindRawValue == SyncKind.preference.rawValue)
    }

    @Test func independentPreferenceEditsHaveIndependentJournalRecords() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let sponsor = SyncPreferences.sponsorCategoryPrefix + SponsorCategory.sponsor.rawValue
        let intro = SyncPreferences.sponsorCategoryPrefix + SponsorCategory.intro.rawValue
        #expect(SyncPreferences.set(key: sponsor, value: "true", in: context, projectValue: false))
        #expect(SyncPreferences.set(key: intro, value: "false", in: context, projectValue: false))
        let rows = try context.fetch(FetchDescriptor<SyncPreference>())
        #expect(rows.count == 2)
        let allExplicit = rows.allSatisfy { $0.isExplicit }
        #expect(allExplicit)
        let adapter = SyncStoreAdapter(context: context)
        let sponsorRevision = try #require(try adapter.state(kind: .preference, entityID: sponsor)).localRevision
        let introRevision = try #require(try adapter.state(kind: .preference, entityID: intro)).localRevision
        #expect(SyncPreferences.set(key: sponsor, value: "false", in: context, projectValue: false))
        #expect(try adapter.state(kind: .preference, entityID: sponsor)?.localRevision ?? 0 > sponsorRevision)
        #expect(try adapter.state(kind: .preference, entityID: intro)?.localRevision == introRevision)
    }
}

@Suite(.serialized)
struct CloudSyncPreferenceAndTapTests {
    @MainActor
    @Test func anExplicitPreferenceSurvivesAnotherDevicesMigrationDefault() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let adapter = SyncStoreAdapter(context: context)
        try adapter.bind(accountID: "account", libraryGeneration: "library")
        let key = AppModel.hideShortsKey
        #expect(SyncPreferences.set(key: key, value: "true", in: context, projectValue: false))
        // A writer name and counter chosen to win any causal tie-break.
        let remoteDefault = try SyncEnvelope.mutation(
            kind: .preference, entityID: key,
            payload: SyncPayload.encode(
                SyncPreferencePayload(key: key, value: "false", modifiedAt: .now, isExplicit: false)),
            writerID: "zzzz-remote:1", counter: 1_000)
        try adapter.apply(remoteDefault)
        let row = try #require(
            context.fetch(FetchDescriptor<SyncPreference>(predicate: #Predicate { $0.key == key })).first)
        #expect(row.value == "true")
        #expect(row.isExplicit)
        let pending = try #require(adapter.pendingRecords().first { $0.envelope.entityID == key })
        let reasserted = try SyncPayload.decode(
            SyncPreferencePayload.self, from: #require(pending.envelope.effectivePayload))
        #expect(reasserted.value == "true")
        #expect(reasserted.isExplicit == true)

        // The other direction: an unedited local default yields to the cloud value.
        let other = AppModel.sponsorBlockKey
        try LibrarySyncJournal.transaction(in: context, captureChanges: false) {
            context.insert(SyncPreference(key: other, value: "true", isExplicit: false))
            try LibrarySyncJournal.capture(kind: .preference, entityID: other, in: context)
        }
        let remoteChoice = try SyncEnvelope.mutation(
            kind: .preference, entityID: other,
            payload: SyncPayload.encode(
                SyncPreferencePayload(key: other, value: "false", modifiedAt: .now, isExplicit: true)),
            writerID: "remote:1", counter: 1)
        try adapter.apply(remoteChoice)
        let adopted = try #require(
            context.fetch(FetchDescriptor<SyncPreference>(predicate: #Predicate { $0.key == other })).first)
        #expect(adopted.value == "false")
        #expect(adopted.isExplicit)
        #expect(try adapter.pendingRecords().allSatisfy { $0.envelope.entityID != other })
    }

    @MainActor
    @Test func aTapBelowTheImpressionWindowStillClearsThePenalty() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let now = Date()
        try RecommendationSyncBridge.prepare(in: context)
        // A penalty carried over from earlier sessions, with no event from this render.
        context.insert(FeedImpressionBaseline(videoID: "deep", count: 4, lastShownAt: now.addingTimeInterval(-3_600)))
        try FeedImpressionStore.rebuild(in: context, now: now)
        #expect(FeedImpressionStore.counts(in: context)["deep"] == 4)
        RecommendationOutcomeStore.recordTap(videoID: "deep", eventID: nil, in: context, now: now)
        #expect(FeedImpressionStore.counts(in: context)["deep"] == nil)

        // Another device's event is never claimed; the reset is written on its own.
        let remote = RecommendationOutcomeEntry(
            videoID: "remote", shownAt: now.addingTimeInterval(-60), position: 0,
            features: RecommendationSyncFeatures.empty.features, originID: "other-device")
        context.insert(remote)
        try FeedImpressionStore.rebuild(in: context, now: now)
        #expect(FeedImpressionStore.counts(in: context)["remote"] == 1)
        RecommendationOutcomeStore.recordTap(videoID: "remote", eventID: nil, in: context, now: now)
        #expect(!remote.tapped)
        #expect(FeedImpressionStore.counts(in: context)["remote"] == nil)

        // This device's newest event for the video takes the tap.
        let recorded = RecommendationOutcomeStore.record(
            [.init(videoID: "shown", position: 12, features: RecommendationSyncFeatures.empty.features)],
            in: context, now: now)
        let eventID = try #require(recorded["shown"])
        #expect(FeedImpressionStore.counts(in: context)["shown"] == 1)
        RecommendationOutcomeStore.recordTap(
            videoID: "shown", eventID: nil, in: context, now: now.addingTimeInterval(1))
        let optionalID: UUID? = eventID
        let event = try #require(
            context.fetch(
                FetchDescriptor<RecommendationOutcomeEntry>(predicate: #Predicate { $0.eventID == optionalID })
            )
            .first)
        #expect(event.tapped)
        #expect(FeedImpressionStore.counts(in: context)["shown"] == nil)
    }
}
