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
    @State private var showingTextImport = false
    @State private var interaction = BookshelfInteraction()
    @State private var pendingRemoval: BookRecord?
    @State private var showingSettings = false
    @State private var showingBookmarks = false

#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
#endif

    private let gridSpacing: CGFloat = 18
    private let gridHorizontalPadding: CGFloat = 20

    private var columns: [GridItem] {
        [
            GridItem(
                .adaptive(minimum: 150, maximum: 210),
                spacing: gridSpacing,
                alignment: .top
            )
        ]
    }

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
                ToolbarItem(placement: .navigationBarLeading) {
                    if horizontalSizeClass == .compact {
                        settingsButton
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showingBookmarks = true } label: {
                        Label("Bookmarks", systemImage: "bookmark")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    importButton
                }
#endif
            }
            .overlay {
                if store.books.isEmpty {
                    CompatibilityUnavailableView(
                        "No books yet",
                        systemImage: "books.vertical",
                        description: "Add a book to get started."
                    )
                }
            }
            .overlay(alignment: .center) {
                if store.isImporting {
                    VStack(alignment: .leading, spacing: 12) {
                        if let fraction = store.importProgressFraction {
                            ProgressView(value: fraction, total: 1) {
                                Text(store.importProgressLabel)
                            } currentValueLabel: {
                                Text("\(Int((fraction * 100).rounded()))%")
                                    .monospacedDigit()
                            }
                        } else {
                            ProgressView(store.importProgressLabel)
                        }
                    }
                    .frame(maxWidth: 280, alignment: .leading)
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
            .fileImporter(
                isPresented: $importingFile,
                allowedContentTypes: [
                    UTType(filenameExtension: "epub") ?? .data,
                    .plainText,
                ],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    Task {
                        let contentType = UTType(filenameExtension: url.pathExtension)
                        if contentType?.conforms(to: .plainText) == true {
                            await store.importPlainText(from: url)
                        } else {
                            await store.importBook(from: url)
                        }
                    }
                case .failure(let error):
                    store.importError = error.localizedDescription
                }
            }
            .sheet(isPresented: $showingBookmarks) {
                BookmarksView()
            }
            .sheet(isPresented: $showingTextImport) {
                PlainTextImportView()
                    .environmentObject(store)
            }
#if os(iOS)
            .sheet(isPresented: $showingSettings) {
                ReaderPreferencesView()
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
                        "“\($0.title)” will be removed from this device."
                    } ?? ""
                )
            }
        }
#if os(iOS)
        .fullScreenCover(item: readerSelection) { selection in
            ReaderView(bookID: selection.id) {
                closeReader(selection)
            }
        }
#else
        .sheet(item: readerSelection) { selection in
            ReaderView(bookID: selection.id) {
                closeReader(selection)
            }
        }
#endif
    }

    private var readerSelection: Binding<ReaderSelection?> {
        let presentedID = interaction.readerID
        return Binding(
            get: { interaction.readerID.map { ReaderSelection(id: $0) } },
            set: { selection in
                if selection == nil, let id = presentedID {
                    closeReader(ReaderSelection(id: id))
                }
            }
        )
    }

    private func closeReader(_ selection: ReaderSelection) {
        withoutReaderAnimation { interaction.closeReader(selection.id) }
    }

    private func withoutReaderAnimation(_ action: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, action)
    }

    private var libraryContent: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
                ForEach(store.books) { book in
                    bookCard(for: book)
                }
            }
            .padding(.horizontal, gridHorizontalPadding)
            .padding(.vertical, 24)
        }
    }

    private func bookCard(for book: BookRecord) -> some View {
        BookCardView(
            book: book,
            canPresentMenu: interaction.phase == .browsing,
            onOpen: { withoutReaderAnimation { interaction.openBook(book.id) } },
            onMenuBegin: { interaction.showActions(for: book.id) },
            onMenuSelect: { interaction.selectAction($0, for: book.id) },
            onMenuEnd: { finishMenu(for: book.id) }
        )
    }

    private func finishMenu(for id: UUID) {
        guard let action = interaction.finishActions(for: id), store.book(id: id) != nil else { return }
        switch action {
        case .translate: store.translateBook(id: id)
        case .cancelTranslation: store.cancelBookTranslation(id: id)
        case .rebuild: Task { await store.rebuildBook(id: id) }
        case .remove: pendingRemoval = store.book(id: id)
        }
    }

    private var importButton: some View {
        Menu {
            Button {
                importingFile = true
            } label: {
                Label("Import", systemImage: "doc.badge.plus")
            }

            Button {
                showingTextImport = true
            } label: {
                Label("Paste Text", systemImage: "doc.on.clipboard")
            }
        } label: {
            Image(systemName: "plus")
        }
        .accessibilityLabel("Add Book")
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

private struct PlainTextImportView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: LibraryStore

    @State private var title = ""
    @State private var author = ""
    @State private var text = ""

    private var canCreate: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && text.contains { !$0.isWhitespace }
            && !store.isImporting
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Title", text: $title)
                    TextField("Author (Optional)", text: $author)
                }

                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 280)
                } header: {
                    Text("Text")
                } footer: {
                    Text("One line per paragraph.")
                }
            }
            .navigationTitle("New Book")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let bookTitle = title
                        let bookAuthor = author
                        let bookText = text
                        dismiss()
                        Task {
                            await store.importPlainText(
                                title: bookTitle,
                                author: bookAuthor,
                                text: bookText
                            )
                        }
                    }
                    .disabled(!canCreate)
                }
            }
            .onAppear {
                guard text.isEmpty else { return }
                text = Self.clipboardText
            }
        }
    }

    private static var clipboardText: String {
#if canImport(UIKit)
        UIPasteboard.general.string ?? ""
#elseif canImport(AppKit)
        NSPasteboard.general.string(forType: .string) ?? ""
#else
        ""
#endif
    }
}

/// Library progress notifications must not reload every visible cover from disk.
private struct BookCoverArtwork: View, Equatable {
    let url: URL?
    let title: String
    let importedAt: Date

    var body: some View {
        Group {
            if let url, let image = PlatformImage(contentsOfFile: url.path) {
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
                        Text(title)
                            .font(.headline)
                            .lineLimit(4)
                            .padding(16)
                            .foregroundStyle(.black.opacity(0.8))
                    }
            }
        }
    }
}

private struct BookCardView: View {
    let book: BookRecord
    let canPresentMenu: Bool
    let onOpen: () -> Void
    let onMenuBegin: () -> Void
    let onMenuSelect: (BookAction) -> Void
    let onMenuEnd: () -> Void

    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 10) {
                BookCoverArtwork(url: store.coverURL(for: book), title: book.title, importedAt: book.importedAt)
                .equatable()
                .aspectRatio(2 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.08), radius: 12, y: 6)

                Text(book.title)
                    .font(.headline)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)

                if let translation = store.bookTranslations[book.id] {
                    VStack(alignment: .leading, spacing: 4) {
                        switch translation.phase {
                        case .running:
                            Text("Translating: \(translation.completed) / \(translation.total)")
                            if translation.total > 0 {
                                ProgressView(value: Double(translation.completed), total: Double(translation.total))
                            } else {
                                ProgressView()
                            }
                        case .finished:
                            Label("Translation cached", systemImage: "checkmark.circle")
                        case .failed:
                            Text("Translation paused. Try again to resume.")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Text(book.author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack {
                    Label("Book", systemImage: "book.closed")
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
        .overlay(alignment: .topTrailing) {
            BookActionsMenu(
                isTranslating: store.bookTranslations[book.id]?.phase == .running,
                canTranslate: !store.isImporting,
                canPresent: canPresentMenu,
                onBegin: onMenuBegin,
                onSelect: onMenuSelect,
                onEnd: onMenuEnd
            )
            .frame(width: 44, height: 44)
            .padding(12)
        }
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
