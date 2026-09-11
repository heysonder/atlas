import Foundation
import Observation
import os

#if canImport(DeclaredAgeRange)
    import DeclaredAgeRange
#endif

/// App Store age assurance: social features (comments, live chat, chat replay
/// — all user-generated content) stay off until the Declared Age Range API
/// confirms the user is 13 or older. The verdict is cached and re-checked
/// every 30 days, or whenever the user asks from Settings.
///
/// Requires the `com.apple.developer.declared-age-range` entitlement.
@MainActor
@Observable
final class SocialFeaturesGate {
    static let shared = SocialFeaturesGate()
    private static let log = Logger(subsystem: "sh.cmf.atlas", category: "agegate")

    /// Youngest age allowed to see social features.
    static let minimumAge = 13
    /// Master switch. Requires the `com.apple.developer.declared-age-range`
    /// entitlement in the provisioning profile — without it the API throws
    /// and everyone reads as "declined" (that's what happened 2026-08-27).
    static let isEnforced = false
    static let recheckInterval: TimeInterval = 30 * 24 * 60 * 60

    enum Status: String, Codable, Sendable {
        /// Not asked yet this install, or the cached answer expired.
        case unknown
        case allowed
        /// Under 13 (or declared range overlaps under-13).
        case underage
        /// The user declined to share, so we can't confirm — treated as off,
        /// with a way to try again.
        case declined
    }

    private(set) var status: Status
    private(set) var checkedAt: Date?
    /// True while a request is in flight, so the UI shows a spinner rather than
    /// the "off" notice flashing before the sheet answers.
    private(set) var isChecking = false

    var allowsSocialFeatures: Bool { !Self.isEnforced || status == .allowed }
    var needsCheck: Bool {
        guard status != .unknown, let checkedAt else { return true }
        return Date().timeIntervalSince(checkedAt) > Self.recheckInterval
    }

    private static let statusKey = "social.ageGate.status"
    private static let checkedAtKey = "social.ageGate.checkedAt"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        status = defaults.string(forKey: Self.statusKey).flatMap(Status.init) ?? .unknown
        checkedAt = defaults.object(forKey: Self.checkedAtKey) as? Date
    }

    /// Pure mapping from a declared range to a verdict. Apple returns the
    /// bounds relative to the gates we asked for, so with a single 13 gate:
    /// `upperBound == 12` means under 13, `lowerBound == 13` means 13+.
    static func verdict(lowerBound: Int?, upperBound: Int?) -> Status {
        if let upperBound, upperBound < minimumAge { return .underage }
        if let lowerBound, lowerBound >= minimumAge { return .allowed }
        // Ambiguous (no bounds at all): don't unlock UGC on a guess.
        return .underage
    }

    func apply(_ status: Status, at date: Date = Date()) {
        self.status = status
        checkedAt = date
        defaults.set(status.rawValue, forKey: Self.statusKey)
        defaults.set(date, forKey: Self.checkedAtKey)
    }

    #if canImport(DeclaredAgeRange)
        /// Asks the system for the user's age range (shows Apple's sheet the
        /// first time) and caches the verdict. `force` re-asks even when a
        /// fresh answer is cached (Settings → Check Again).
        func resolve(using request: sending DeclaredAgeRangeAction, force: Bool = false) async {
            guard Self.isEnforced || force, force || needsCheck, !isChecking else { return }
            isChecking = true
            defer { isChecking = false }
            do {
                switch try await request(ageGates: Self.minimumAge) {
                case .sharing(let range):
                    Self.log.info(
                        "age range lower=\(range.lowerBound.map(String.init) ?? "nil", privacy: .public) upper=\(range.upperBound.map(String.init) ?? "nil", privacy: .public)"
                    )
                    apply(Self.verdict(lowerBound: range.lowerBound, upperBound: range.upperBound))
                case .declinedSharing:
                    Self.log.info("age range declined sharing")
                    apply(.declined)
                @unknown default:
                    apply(.declined)
                }
            } catch let error as AgeRangeService.Error {
                Self.log.error("age range error \(String(describing: error), privacy: .public)")
                switch error {
                case .notAvailable, .invalidAccount:
                    // No age-range system on this device/account (e.g. no Apple
                    // Account signed in). The API can't be consulted, so treat
                    // it as declined rather than silently unlocking UGC.
                    apply(.declined)
                case .declinedOnboarding, .invalidRequest:
                    apply(.declined)
                case .network:
                    // Transient: keep the cached verdict (or `.unknown`, which
                    // re-asks next time) rather than caching "declined" for 30 days.
                    break
                @unknown default:
                    apply(.declined)
                }
            } catch {
                apply(.declined)
            }
        }
    #endif
}
