import SwiftUI

struct ContentView: View {
    enum SidebarSection: Hashable {
        case bookshelf
        case bookmarks
        case settings
    }

    @State private var selectedSection: SidebarSection? = .bookshelf

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedSection) {
                Label("Bookshelf", systemImage: "books.vertical")
                    .tag(SidebarSection.bookshelf)

                Label("Bookmarks", systemImage: "bookmark")
                    .tag(SidebarSection.bookmarks)

                Label("Settings", systemImage: "gearshape")
                    .tag(SidebarSection.settings)
            }
            .listStyle(.sidebar)
#if os(macOS)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
#endif
        } detail: {
            switch selectedSection ?? .bookshelf {
            case .bookshelf:
                BookshelfView()
            case .bookmarks:
                BookmarksView()
            case .settings:
                ReaderPreferencesView()
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(LibraryStore())
}
