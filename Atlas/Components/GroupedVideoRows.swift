import PipedKit

/// One display row: a full-width video, a run of Shorts, or a horizontal shelf.
enum GroupedVideoRow: Identifiable {
    case video(StreamItem)
    case shorts([StreamItem])
    case shelf([StreamItem])

    var id: String {
        switch self {
        case .video(let video):
            "v:" + video.id
        case .shorts(let shorts):
            "s:" + shorts.map(\.id).joined(separator: "+")
        case .shelf(let shorts):
            "shelf:" + shorts.map(\.id).joined(separator: "+")
        }
    }
}

/// Groups Shorts in pairs while preserving regular-video order.
func inlineVideoRows(_ items: [StreamItem]) -> [GroupedVideoRow] {
    var rows: [GroupedVideoRow] = []
    var pendingShort: StreamItem?
    for item in items {
        if item.isShort == true {
            if let firstShort = pendingShort {
                rows.append(.shorts([firstShort, item]))
                pendingShort = nil
            } else {
                pendingShort = item
            }
        } else {
            rows.append(.video(item))
        }
    }
    if let pendingShort {
        rows.append(.shorts([pendingShort]))
    }
    return rows
}

/// Places all Shorts in one shelf after up to three regular videos.
func carouselVideoRows(_ items: [StreamItem]) -> [GroupedVideoRow] {
    let shorts = items.filter { $0.isShort == true }
    let videos = items.filter { $0.isShort != true }
    guard !shorts.isEmpty else { return videos.map(GroupedVideoRow.video) }

    var rows: [GroupedVideoRow] = []
    let shelfInsertionIndex = min(3, videos.count)
    for (index, video) in videos.enumerated() {
        rows.append(.video(video))
        if index + 1 == shelfInsertionIndex {
            rows.append(.shelf(shorts))
        }
    }
    if videos.isEmpty {
        rows.append(.shelf(shorts))
    }
    return rows
}

func groupedVideoRows(
    _ items: [StreamItem],
    layout: ShortsLayout
) -> [GroupedVideoRow] {
    switch layout {
    case .inline:
        inlineVideoRows(items)
    case .carousel:
        carouselVideoRows(items)
    }
}
