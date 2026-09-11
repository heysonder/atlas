import SwiftUI

struct SearchHistoryContent: View {
    let entries: [SearchEntry]
    let onSelect: (SearchEntry) -> Void
    let onDeleteOffsets: (IndexSet) -> Void
    let onDeleteEntry: (SearchEntry) -> Void
    let onClear: () -> Void

    var body: some View {
        LibraryLayout(minCardWidth: 280) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    LazyVGrid(
                        columns: LibraryGrid.columns(minCardWidth: 280),
                        spacing: LibraryGrid.spacing
                    ) {
                        ForEach(entries) { entry in
                            Button {
                                onSelect(entry)
                            } label: {
                                SearchHistoryRow(entry: entry).libraryCard()
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    onDeleteEntry(entry)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .padding()
            }
        } list: {
            // Plain rows like the App Store's "Recent": no card, one line per
            // query, separators aligned to the text.
            List {
                Section {
                    ForEach(entries) { entry in
                        Button {
                            onSelect(entry)
                        } label: {
                            SearchHistoryRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete(perform: onDeleteOffsets)
                } header: {
                    header.textCase(nil)
                }
            }
            .listStyle(.plain)
        }
    }

    private var header: some View {
        HStack {
            Text("Recent")
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button("Clear", action: onClear)
                .font(.body)
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .inlineTapTarget()
        }
    }
}

private struct SearchHistoryRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let entry: SearchEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            Text(entry.displayTitle)
                .font(.body)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityLabel("Search \(entry.displayTitle)")
    }
}
