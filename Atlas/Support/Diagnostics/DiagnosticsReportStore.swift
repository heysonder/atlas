import Foundation

/// On-disk archive of MetricKit reports, kept under Application Support. Each
/// report is one JSON file named by kind + arrival time; nothing leaves the
/// device unless the user shares the archive from Settings → Diagnostics.
actor DiagnosticsReportStore {
    static let shared = DiagnosticsReportStore()

    enum Kind: String, CaseIterable, Sendable {
        case metric
        case diagnostic
    }

    struct Entry: Identifiable, Sendable, Equatable {
        let url: URL
        let kind: Kind
        let date: Date
        let size: Int
        var id: URL { url }
    }

    /// Reports older than this are pruned on every write.
    let retention: TimeInterval
    /// Hard cap on files, oldest first, so a chatty week can't grow unbounded.
    let maximumCount: Int
    private let directory: URL
    private let fileManager = FileManager.default

    init(
        directory: URL? = nil,
        retention: TimeInterval = 30 * 24 * 60 * 60,
        maximumCount: Int = 120
    ) {
        self.directory = directory ?? Self.defaultDirectory()
        self.retention = retention
        self.maximumCount = maximumCount
    }

    private static func defaultDirectory() -> URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Diagnostics", isDirectory: true)
    }

    static func fileName(kind: Kind, date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate]
        formatter.timeZone = TimeZone(identifier: "UTC")
        let stamp = formatter.string(from: date).replacingOccurrences(of: ":", with: "")
        return "\(kind.rawValue)-\(stamp).json"
    }

    @discardableResult
    func save(_ data: Data, kind: Kind, date: Date = Date()) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory.appendingPathComponent(Self.fileName(kind: kind, date: date))
        var suffix = 1
        while fileManager.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent(
                Self.fileName(kind: kind, date: date).replacingOccurrences(of: ".json", with: "-\(suffix).json"))
            suffix += 1
        }
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        prune(now: date)
        return url
    }

    func entries() -> [Entry] {
        guard
            let urls = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
        else { return [] }
        return urls.compactMap { url -> Entry? in
            guard url.pathExtension == "json",
                let kind = Kind.allCases.first(where: { url.lastPathComponent.hasPrefix($0.rawValue + "-") }),
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            else { return nil }
            return Entry(
                url: url, kind: kind,
                date: values.contentModificationDate ?? .distantPast,
                size: values.fileSize ?? 0)
        }
        .sorted { $0.date > $1.date }
    }

    /// Bundles every report into one JSON array file for sharing.
    func exportArchive() throws -> URL {
        let entries = entries()
        var parts: [String] = []
        for entry in entries {
            if let data = try? Data(contentsOf: entry.url), let text = String(data: data, encoding: .utf8) {
                parts.append("{\"kind\":\"\(entry.kind.rawValue)\",\"file\":\"\(entry.url.lastPathComponent)\",\"report\":\(text)}")
            }
        }
        let body = "[\n" + parts.joined(separator: ",\n") + "\n]\n"
        let exportURL = fileManager.temporaryDirectory.appendingPathComponent("atlas-diagnostics.json")
        try body.data(using: .utf8)?.write(to: exportURL, options: .atomic)
        return exportURL
    }

    func deleteAll() {
        try? fileManager.removeItem(at: directory)
    }

    private func prune(now: Date) {
        let all = entries()
        let cutoff = now.addingTimeInterval(-retention)
        for (index, entry) in all.enumerated() where entry.date < cutoff || index >= maximumCount {
            try? fileManager.removeItem(at: entry.url)
        }
    }
}
