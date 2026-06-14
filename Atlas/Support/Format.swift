import Foundation

enum Format {
    /// 1695 -> "28:15", 65 -> "1:05".
    static func duration(_ seconds: Int?) -> String {
        guard let seconds, seconds > 0 else { return "" }
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// Scrubber clock that always renders, including zero: 0 -> "0:00", 65 -> "1:05".
    static func clock(_ seconds: Int) -> String {
        let s = max(seconds, 0)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", m, sec)
    }

    /// 8807 -> "8.8K views", 1200000 -> "1.2M views".
    static func views(_ count: Int?) -> String? {
        guard let count, count >= 0 else { return nil }
        let n = Double(count)
        let label: String
        switch n {
        case 1_000_000_000...: label = String(format: "%.1fB", n / 1_000_000_000)
        case 1_000_000...:     label = String(format: "%.1fM", n / 1_000_000)
        case 1_000...:         label = String(format: "%.1fK", n / 1_000)
        default:               label = "\(count)"
        }
        return "\(label) views"
    }

    /// Joins non-empty parts with " · ".
    static func metaLine(_ parts: String?...) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// YouTube-style relative upload time from a millisecond epoch timestamp:
    /// "just now", "2 hours ago", "3 days ago", "5 years ago". Returns nil when
    /// the timestamp is missing or in the future.
    static func relativeTime(_ uploadedMillis: Int64?) -> String? {
        guard let uploadedMillis, uploadedMillis > 0 else { return nil }
        let seconds = Date().timeIntervalSince1970 - Double(uploadedMillis) / 1000
        guard seconds >= 0 else { return nil }
        let minute = 60.0, hour = 3600.0, day = 86_400.0
        let week = day * 7, month = day * 30, year = day * 365
        func ago(_ value: Double, _ unit: String) -> String {
            let n = max(Int(value), 1)
            return "\(n) \(unit)\(n == 1 ? "" : "s") ago"
        }
        switch seconds {
        case ..<minute: return "just now"
        case ..<hour:   return ago(seconds / minute, "minute")
        case ..<day:    return ago(seconds / hour, "hour")
        case ..<week:   return ago(seconds / day, "day")
        case ..<month:  return ago(seconds / week, "week")
        case ..<year:   return ago(seconds / month, "month")
        default:        return ago(seconds / year, "year")
        }
    }
}
