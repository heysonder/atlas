import SwiftData
import SwiftUI

struct TopicCloudView: View {
    @Query(sort: \HistoryEntry.watchedAt, order: .reverse) private var history: [HistoryEntry]
    @Query(sort: \Feedback.createdAt, order: .reverse) private var feedback: [Feedback]
    @Query(sort: \PlaylistVideo.addedAt, order: .reverse) private var savedVideos: [PlaylistVideo]
    @Query(sort: \SearchEntry.lastSearchedAt, order: .reverse) private var searches: [SearchEntry]
    @Query(sort: \VideoSignalCacheEntry.updatedAt, order: .reverse) private var cachedSignals: [VideoSignalCacheEntry]

    private var cloud: TopicCloudSummary {
        TopicCloudBuilder.make(history: history, feedback: feedback, saved: savedVideos,
                               searches: searches, cachedSignals: cachedSignals)
    }

    var body: some View {
        List {
            if cloud.positive.isEmpty && cloud.negative.isEmpty {
                ContentUnavailableView("No topics yet", systemImage: "textformat.size",
                                       description: Text("Watch, search, save, or rate videos to build your cloud."))
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    TopicCloudWords(entries: cloud.positive, tint: .accentColor)
                        .padding(.vertical, 8)
                } header: {
                    Text("More of this")
                }

                if !cloud.negative.isEmpty {
                    Section {
                        TopicCloudWords(entries: cloud.negative, tint: .red)
                            .padding(.vertical, 8)
                    } header: {
                        Text("Less of this")
                    }
                }
            }

            Section {
                LabeledContent("History", value: "\(history.count)")
                LabeledContent("Searches", value: "\(searches.count)")
                LabeledContent("Saved", value: "\(savedVideos.count)")
                LabeledContent("Ratings", value: "\(feedback.count)")
            } header: {
                Text("Signals")
            } footer: {
                Text("Built on this device from local activity. Nothing is uploaded.")
            }
        }
        .navigationTitle("Topic Cloud")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TopicCloudWords: View {
    let entries: [TopicCloudEntry]
    let tint: Color

    private var weightRange: ClosedRange<Double> {
        let weights = entries.map(\.weight)
        let minWeight = weights.min() ?? 1
        let maxWeight = weights.max() ?? 1
        return minWeight...max(maxWeight, minWeight)
    }

    var body: some View {
        FlowLayout(spacing: 10, lineSpacing: 8) {
            ForEach(entries) { entry in
                Text(entry.term)
                    .font(.system(size: fontSize(for: entry), weight: fontWeight(for: entry),
                                  design: .rounded))
                    .foregroundStyle(tint.opacity(opacity(for: entry)))
                    .accessibilityLabel("\(entry.term), strength \(Int(entry.weight.rounded()))")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func scale(for entry: TopicCloudEntry) -> Double {
        let lower = weightRange.lowerBound
        let spread = max(0.1, weightRange.upperBound - lower)
        return min(1, max(0, (entry.weight - lower) / spread))
    }

    private func fontSize(for entry: TopicCloudEntry) -> CGFloat {
        14 + CGFloat(scale(for: entry)) * 14
    }

    private func fontWeight(for entry: TopicCloudEntry) -> Font.Weight {
        scale(for: entry) > 0.65 ? .bold : .semibold
    }

    private func opacity(for entry: TopicCloudEntry) -> Double {
        0.58 + scale(for: entry) * 0.42
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    nonisolated func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                                  cache: inout ()) -> CGSize {
        let maxWidth = max(1, proposal.width ?? 320)
        let rows = rows(in: maxWidth, subviews: subviews)
        let height = rows.reduce(0) { total, row in
            total + row.height + (total == 0 ? 0 : lineSpacing)
        }
        return CGSize(width: maxWidth, height: height)
    }

    nonisolated func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                                   cache: inout ()) {
        let rows = rows(in: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(at: CGPoint(x: x, y: y),
                                           proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    nonisolated private func rows(in maxWidth: CGFloat, subviews: Subviews) -> [FlowRow] {
        var rows: [FlowRow] = []
        var currentItems: [FlowItem] = []
        var currentWidth: CGFloat = 0
        var currentHeight: CGFloat = 0

        for index in subviews.indices {
            let subview = subviews[index]
            let size = subview.sizeThatFits(.unspecified)
            let wouldWrap = !currentItems.isEmpty
                && currentWidth + spacing + size.width > maxWidth
            if wouldWrap {
                rows.append(FlowRow(items: currentItems, height: currentHeight))
                currentItems = []
                currentWidth = 0
                currentHeight = 0
            }

            if !currentItems.isEmpty { currentWidth += spacing }
            currentItems.append(FlowItem(index: index, size: size))
            currentWidth += size.width
            currentHeight = max(currentHeight, size.height)
        }
        if !currentItems.isEmpty {
            rows.append(FlowRow(items: currentItems, height: currentHeight))
        }
        return rows
    }
}

private struct FlowRow {
    let items: [FlowItem]
    let height: CGFloat
}

private struct FlowItem {
    let index: LayoutSubviews.Index
    let size: CGSize
}
