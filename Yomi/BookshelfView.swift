//
//  BookshelfView.swift
//  Yomi
//

import SwiftUI
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
private typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
private typealias PlatformImage = NSImage
#endif

struct BookshelfView: View {
    private struct ReaderSelection: Identifiable {
        let id: UUID
    }

    @EnvironmentObject private var store: LibraryStore

    @State private var importingFile = false
    @State private var selectedBook: ReaderSelection?
    @State private var pendingRemoval: BookRecord?
    @State private var showingSettings = false

#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
#endif

    private let columns = [
        GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 28)
    ]

    var body: some View {
        NavigationStack {
            libraryContent
            .navigationTitle("Novels")
            .navigationBarBackButtonHidden()
            .toolbar {
#if os(macOS)
                ToolbarItem {
                    importButton
                }
#else
                ToolbarItem(placement: .topBarLeading) {
                    if horizontalSizeClass == .compact {
                        settingsButton
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    importButton
                }
#endif
            }
            .overlay {
                if store.books.isEmpty {
                    ContentUnavailableView(
                        "No books yet",
                        systemImage: "books.vertical",
                        description: Text("Import an EPUB with the + button.")
                    )
                }
            }
            .overlay(alignment: .center) {
                if store.isImporting {
                    ProgressView("Importing EPUB…")
                        .padding(20)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
            .fileImporter(
                isPresented: $importingFile,
                allowedContentTypes: [UTType(filenameExtension: "epub") ?? .data],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    Task {
                        await store.importBook(from: url)
                    }
                case .failure(let error):
                    store.importError = error.localizedDescription
                }
            }
#if os(iOS)
            .fullScreenCover(item: $selectedBook) { selection in
                ReaderView(bookID: selection.id)
            }
            .sheet(isPresented: $showingSettings) {
                ReaderPreferencesView()
            }
#else
            .sheet(item: $selectedBook) { selection in
                ReaderView(bookID: selection.id)
            }
#endif
            .alert("Import Failed", isPresented: Binding(
                get: { store.importError != nil },
                set: { isPresented in
                    if !isPresented {
                        store.importError = nil
                    }
                }
            ), actions: {
                Button("OK") {
                    store.importError = nil
                }
            }, message: {
                Text(store.importError ?? "")
            })
            .confirmationDialog(
                "Remove Book",
                isPresented: Binding(
                    get: { pendingRemoval != nil },
                    set: { isPresented in
                        if !isPresented {
                            pendingRemoval = nil
                        }
                    }
                ),
                titleVisibility: .visible
            ) {
                if let book = pendingRemoval {
                    Button("Remove", role: .destructive) {
                        if selectedBook?.id == book.id {
                            selectedBook = nil
                        }
                        store.removeBook(id: book.id)
                        pendingRemoval = nil
                    }
                }

                Button("Cancel", role: .cancel) {
                    pendingRemoval = nil
                }
            } message: {
                Text(
                    pendingRemoval.map {
                        "Delete “\($0.title)” from the library and remove its stored EPUB files."
                    } ?? ""
                )
            }
        }
    }

    private var libraryContent: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
                ForEach(store.books) { book in
                    bookCard(for: book)
                }
            }
            .padding(28)
        }
    }

    private func bookCard(for book: BookRecord) -> some View {
        BookCardView(
            book: book,
            onOpen: { selectedBook = ReaderSelection(id: book.id) },
            onRemove: { pendingRemoval = book }
        )
    }

    private var importButton: some View {
        Button {
            importingFile = true
        } label: {
            Image(systemName: "plus")
        }
        .accessibilityLabel("Import EPUB")
    }

    private var settingsButton: some View {
        Button {
            showingSettings = true
        } label: {
            Image(systemName: "gearshape")
        }
        .accessibilityLabel("Settings")
    }
}

private struct BookCardView: View {
    let book: BookRecord
    let onOpen: () -> Void
    let onRemove: () -> Void

    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 10) {
                Group {
                    if let coverURL = store.coverURL(for: book), let image = PlatformImage(contentsOfFile: coverURL.path) {
                        Image(platformImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color(red: 0.96, green: 0.90, blue: 0.78), Color(red: 0.83, green: 0.89, blue: 0.96)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .overlay(alignment: .bottomLeading) {
                                Text(book.title)
                                    .font(.headline)
                                    .lineLimit(4)
                                    .padding(16)
                                    .foregroundStyle(.black.opacity(0.8))
                            }
                    }
                }
                .frame(height: 280)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.08), radius: 12, y: 6)
                .overlay(alignment: .topTrailing) {
                    Menu {
                        Button(role: .destructive, action: onRemove) {
                            Label("Remove", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.headline.weight(.bold))
                            .padding(10)
                            .background(.thinMaterial, in: Circle())
                    }
                    .padding(12)
                }

                Text(book.title)
                    .font(.headline)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)

                Text(book.author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack {
                    Label("EPUB", systemImage: "doc.richtext")
                    Spacer()
                    Text(book.progressSummary)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary.opacity(0.72))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

private extension Image {
    init(platformImage: PlatformImage) {
#if canImport(UIKit)
        self.init(uiImage: platformImage)
#elseif canImport(AppKit)
        self.init(nsImage: platformImage)
#endif
    }
}
