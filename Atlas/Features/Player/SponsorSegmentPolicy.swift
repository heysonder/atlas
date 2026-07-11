import PipedKit

enum SponsorSegmentPolicy {
    /// Keeps only bounded, skippable segments with a positive duration,
    /// ordered by their start time.
    nonisolated static func usableSegments(_ segments: [SponsorSegment]) -> [SponsorSegment] {
        segments.lazy
            .prefix(1_000)
            .filter {
                $0.segment.count == 2
                    && $0.start.isFinite && $0.end.isFinite
                    && $0.start >= 0 && $0.end > $0.start
                    && $0.end <= 7 * 24 * 60 * 60
                    && ($0.actionType ?? "skip") == "skip"
                    && $0.category.utf8.count <= 64
                    && ($0.uuid?.utf8.count ?? 0) <= 128
            }
            .prefix(200)
            .sorted { $0.start < $1.start }
    }
}
