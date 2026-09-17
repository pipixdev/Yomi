import SwiftUI

struct BookmarksView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var selectedBookmark: ParagraphBookmark?

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.bookmarks) { bookmark in
                    Button {
                        selectedBookmark = bookmark
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(store.book(id: bookmark.bookID)?.title ?? String(localized: "Book unavailable"))
                                .font(.headline)
                            Text(bookmark.text)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                        }
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(store.book(id: bookmark.bookID) == nil)
                    .swipeActions {
                        Button(role: .destructive) {
                            store.removeBookmark(id: bookmark.id)
                        } label: {
                            Label("Remove bookmark", systemImage: "bookmark.slash")
                        }
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            store.removeBookmark(id: bookmark.id)
                        } label: {
                            Label("Remove bookmark", systemImage: "bookmark.slash")
                        }
                    }
                }
            }
            .overlay {
                if store.bookmarks.isEmpty {
                    CompatibilityUnavailableView(
                        "No bookmarks yet",
                        systemImage: "bookmark",
                        description: "Save paragraphs from their detail page to find them here."
                    )
                }
            }
            .navigationTitle("Bookmarks")
#if os(iOS)
            .fullScreenCover(item: $selectedBookmark) { bookmark in
                ReaderView(bookID: bookmark.bookID, bookmarkLocatorJSON: bookmark.locatorJSON)
            }
#else
            .sheet(item: $selectedBookmark) { bookmark in
                ReaderView(bookID: bookmark.bookID, bookmarkLocatorJSON: bookmark.locatorJSON)
            }
#endif
            .alert("Bookmark error", isPresented: Binding(
                get: { store.bookmarkError != nil },
                set: { if !$0 { store.bookmarkError = nil } }
            )) {
                Button("OK") { store.bookmarkError = nil }
            } message: {
                Text(store.bookmarkError ?? "")
            }
        }
    }
}
