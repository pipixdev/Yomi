import SwiftUI

struct BookmarksView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var selectedBookmark: ParagraphBookmark?

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.bookmarks) { bookmark in
                    Button {
                        guard selectedBookmark == nil else { return }
                        var transaction = Transaction(animation: nil)
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            selectedBookmark = bookmark
                        }
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
            .alert("Bookmark error", isPresented: Binding(
                get: { store.bookmarkError != nil },
                set: { if !$0 { store.bookmarkError = nil } }
            )) {
                Button("OK") { store.bookmarkError = nil }
            } message: {
                Text(store.bookmarkError ?? "")
            }
        }
        // Presentation stays outside this modifier so the reader's back button works.
        .disabled(selectedBookmark != nil)
        .accessibilityHidden(selectedBookmark != nil)
#if os(iOS)
        .fullScreenCover(item: $selectedBookmark) { bookmark in
            ReaderView(bookID: bookmark.bookID, bookmarkLocatorJSON: bookmark.locatorJSON) {
                closeReader(bookmark)
            }
        }
#else
        .sheet(item: $selectedBookmark) { bookmark in
            ReaderView(bookID: bookmark.bookID, bookmarkLocatorJSON: bookmark.locatorJSON) {
                closeReader(bookmark)
            }
        }
#endif
    }

    private func closeReader(_ bookmark: ParagraphBookmark) {
        // Match bookshelf dismissal: selection and interaction recover together.
        guard selectedBookmark?.id == bookmark.id else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            selectedBookmark = nil
        }
    }
}
