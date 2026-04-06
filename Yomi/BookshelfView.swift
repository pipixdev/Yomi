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
    @EnvironmentObject private var store: LibraryStore

    @State private var importingFile = false
    @State private var selectedBook: BookRecord?

    private let columns = [
        GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 28)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
                    ForEach(store.books) { book in
                        Button {
                            selectedBook = book
                        } label: {
                            BookCardView(book: book)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(28)
            }
            .navigationTitle("Novels")
            .navigationBarBackButtonHidden()
            .toolbar {
#if os(macOS)
                ToolbarItem {
                    importButton
                }
#else
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
            .fullScreenCover(item: $selectedBook) { book in
                ReaderView(book: book)
            }
#else
            .sheet(item: $selectedBook) { book in
                ReaderView(book: book)
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
        }
    }

    private var importButton: some View {
        Button {
            importingFile = true
        } label: {
            Image(systemName: "plus")
        }
        .accessibilityLabel("Import EPUB")
    }
}

private struct BookCardView: View {
    let book: BookRecord

    @EnvironmentObject private var store: LibraryStore

    var body: some View {
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
                        }
                }
            }
            .frame(height: 280)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 12, y: 6)

            Text(book.title)
                .font(.headline)
                .multilineTextAlignment(.leading)
                .lineLimit(2)

            Text(book.author)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
