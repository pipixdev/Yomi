import SwiftUI

struct ContentView: View {
    enum SidebarSection: Hashable {
        case bookshelf
        case settings
    }

    @State private var selectedSection: SidebarSection? = .bookshelf

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedSection) {
                Label("Bookshelf", systemImage: "books.vertical")
                    .tag(SidebarSection.bookshelf)

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
