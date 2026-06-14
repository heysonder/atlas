import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        @Bindable var app = app
        TabView(selection: searchAwareSelection) {
            Tab("Home", systemImage: "house.fill", value: AppModel.TabSelection.feed) {
                FeedView()
            }
            Tab("Library", systemImage: "square.stack.fill", value: AppModel.TabSelection.profile) {
                ProfileView()
            }
            Tab(value: AppModel.TabSelection.search, role: .search) {
                SearchView()
            }
        }
        .background {
            VideoPlayerPresenter(request: $app.nowPlaying, app: app, modelContext: modelContext)
                .frame(width: 0, height: 0)
        }
    }

    /// Wraps the tab selection so re-tapping the search tab while already on the
    /// search page bumps a token SearchView listens to (clear field + refocus).
    private var searchAwareSelection: Binding<AppModel.TabSelection> {
        Binding {
            app.selectedTab
        } set: { newValue in
            if newValue == .search && app.selectedTab == .search {
                app.searchRetapToken += 1
            }
            app.selectedTab = newValue
        }
    }
}
