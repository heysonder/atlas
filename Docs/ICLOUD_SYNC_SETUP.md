# iCloud sync setup and verification

Atlas keeps SwiftData local and synchronizes an encrypted record protocol through the user's private CloudKit database. Sync is off until the user enables it in Library → Settings → iCloud Sync. The app does not check or claim to detect Advanced Data Protection.

## Developer configuration

1. In the Apple Developer account for team `R8VQT6V47K`, enable iCloud/CloudKit and Push Notifications for App ID `sh.cmf.atlas`.
2. Register the container `iCloud.sh.cmf.atlas` and associate it with that App ID. Refresh development and distribution provisioning profiles.
3. Run `xcodegen generate`. `project.yml` owns the CloudKit and push entitlements and preserves background audio alongside remote notifications. Do not edit generated Xcode project settings.
4. Build a signed development app. Inspect its entitlements to confirm the container and correct APNs environment. Keep unit tests and test accounts separate from the production library.
5. On two test devices signed into the same test Apple Account, explicitly enable sync. Development CloudKit schemas are created by encrypted record writes. Inspect `SyncRootV1` and `AtlasItemV1` in CloudKit Console: every custom field must be the encrypted `payload` bytes field. Never create a plain `payload` field first; an existing plain field cannot be converted in place.
6. Promote the verified schema to production before TestFlight/App Store use. TestFlight uses production CloudKit. Test again with a dedicated account and signed distribution build.

There is no backend API key or management token in the app. A CloudKit management token, when needed for CLI operations, belongs in the developer's credential storage, never the repository, app configuration, logs or exported backups.

See [Apple's encryptedValues reference](https://developer.apple.com/documentation/cloudkit/ckrecord/encryptedvalues) and [CKSyncEngine sample](https://github.com/apple/sample-cloudkit-sync-engine) for schema restrictions, capabilities and device testing.

## Device acceptance

Use a dedicated account/library for these destructive checks:

- Leave sync off, edit the local library and run App Intents. No CloudKit library requests should occur.
- Enable on two devices with overlapping subscriptions, history and playlists. Verify the merged result after each device reconnects.
- Concurrently add different playlist videos, remove an entry, delete/recreate Favorites, and seek backwards during a later playback session. Repeat with reversed reconnect order.
- Clear history while the second device is offline. Old history and progress callbacks must not restore cleared entries. New-generation records received before their clear policy must eventually appear.
- Search for the same new term once on each device: the merged repeat count is two; replaying the same cloud change does not increase it.
- Turn sync off, keep editing locally, then re-enable. Current cloud state must be read before pending local edits are sent.
- Switch Apple Accounts or restore a device backup. Sync must pause or stay off until the new installation/account receives explicit consent. Retained data must not upload to another account automatically.
- Delete the cloud copy using Atlas. The library zone is removed, local copies remain, and the minimal encrypted disabled marker prevents stale clients from repopulating the old zone.
- Test quota errors, network interruptions, process termination mid-bootstrap, missing zones and encrypted-data reset. The local library and durable edits must survive.
- Test standard iCloud protection and an ADP-enabled test account. Verify the notice on both; a successful sync does not prove ADP is on. End-to-end protection of encrypted CloudKit fields depends on ADP. [Apple's data security overview](https://support.apple.com/en-us/102651).

Unit tests use in-memory or temporary disk stores and injected CloudKit transports. Passing them does not establish that container registration, distribution signing, push delivery, live quota handling, or ADP account behavior has been verified. Do not run destructive tests on a personal production library.

## Local verification

Verified on September 10, 2026 with Xcode 27 and a dedicated iPhone 17 simulator:

- 313 app unit tests passed, including the original unversioned SwiftData migration, encrypted record encoding, merge convergence, account isolation, restored-installation consent, deletion barriers, interrupted bootstrap, and the engine-delegate suite (quarantined pages, server-record conflicts, stale change tags, per-record rejection isolation, account-change verification, batched progress uploads, unfinished cloud deletion, tombstone compaction, a rejected barrier, and progress ticks during a round), plus writer-identity resets, rollback isolation, journal compaction, preference explicitness, taps below the impression window, and the Favorites read path.
- The UI consent test passed: sync starts off, the Advanced Data Protection notice appears before consent, and canceling leaves sync off. Its captured screenshot was visually checked.
- The app builds for the simulator and as an unsigned Release build for iPhone hardware. The source entitlements keep `aps-environment` at `development`; Xcode rewrites it at archive export.
- A 1,000-item bootstrap was exercised. Production enrollment commits at most 100 journal entries per batch and yields between batches, and runs only until the first successful round for a given account/library binding. Maximum-size libraries still need profiling on devices.

Runtime behavior worth knowing when testing on devices:

- Playback progress is written locally every few seconds, journaled once per 30 seconds per playback session, and uploaded in one batch per 30 seconds, plus immediately on pause, stop, end of playback, and when the app leaves the foreground. A tick that lands while a round is in flight waits for the next batching interval instead of chaining another round.
- A fetched item this version cannot apply is quarantined (shown as "Items Not Applied") and retried at the next session start; a newer version of the same record that applies releases the quarantine. Only an unsupported protocol version pauses sync. A single record CloudKit rejects is skipped for the session while the rest of the queue continues, even when the rejected record is a clear or retention barrier.
- A CloudKit sign-out event is verified against the container before consent is discarded: an unavailable account pauses sync; only a different account un-enrolls the device.
- Preferences carry whether they were an explicit choice. An explicit choice on one device beats another device's unedited migration default regardless of which device enrolled first; an unedited default always yields to the cloud value.
- The sync journal is capped at 250,000 rows. A library that has never been bound to an account drops retired rows immediately (there is nothing in iCloud to delete), and a full journal compacts rows CloudKit never saw before refusing a write.
- Incoming records do not reload the Home or For You feed by themselves; the feed reloads on subscription changes and mode changes as before.
- Expired For You activity retires its cloud record (physical deletion) rather than writing a causal tombstone; the shared retention barrier is what removes an event from other devices, and receivers reject barriers beyond their own clocks.

These checks used local stores and injected transports. Container provisioning, signed development/distribution entitlements, production schema deployment, two-device convergence, and standard-protection/ADP account testing remain unverified. No live CloudKit library was created or changed during these checks.

```sh
xcodegen generate
xcodebuild -project Atlas.xcodeproj -scheme Atlas \
  -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
xcodebuild test -project Atlas.xcodeproj -scheme Atlas \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:AtlasTests -only-testing:AtlasUITests/ICloudSyncFlowTests
```

Adjust the simulator name to an installed device. The design and release criteria are in [ICLOUD_SYNC_PLAN.md](ICLOUD_SYNC_PLAN.md).
