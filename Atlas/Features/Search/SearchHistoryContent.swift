import SwiftUI

struct SearchHistoryContent: View {
    let entries: [SearchEntry]
    let horizontalSizeClass: UserInterfaceSizeClass?
    let onSelect: (SearchEntry) -> Void
    let onDeleteOffsets: (IndexSet) -> Void
    let onDeleteEntry: (SearchEntry) -> Void
    let onClear: () -> Void

    var body: some View {
        if horizontalSizeClass == .regular {
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
        } else {
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
                    header
                        .textCase(nil)
                        .padding(.horizontal, -14)
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private var header: some View {
        HStack {
            Text("Recent Searches")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button("Clear", action: onClear)
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .foregroundStyle(.secondary)
    }
}

private struct SearchHistoryRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let entry: SearchEntry

    private var subtitle: String {
        entry.count == 1 ? "Searched once" : "\(entry.count) searches"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.displayTitle)
                    .font(.body.weight(.medium))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.left")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityLabel("Search \(entry.displayTitle)")
        .accessibilityValue(subtitle)
    }
}
