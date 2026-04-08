//
//  LibraryStore.swift
//  Yomi
//

import Combine
import CryptoKit
import Foundation

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var books: [BookRecord] = []
    @Published var isImporting = false
    @Published var importError: String?

    private let importer = EPUBImporter()
    private let manifestURL: URL
    private let fileManager: FileManager
    private var progressPersistTask: Task<Void, Never>?

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        var resolvedManifestURL: URL
        do {
            let root = try EPUBImporter.rootURL(using: fileManager)
            resolvedManifestURL = root.deletingLastPathComponent().appendingPathComponent("library.json")
            books = try Self.loadBooks(from: resolvedManifestURL)
        } catch {
            resolvedManifestURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("library.json")
            books = []
            importError = error.localizedDescription
        }

        manifestURL = resolvedManifestURL
        migrateImportedBooksIfNeeded()
        importAutomationFixtureIfNeeded()
    }

    func book(id: UUID) -> BookRecord? {
        books.first { $0.id == id }
    }

    func importBook(from url: URL) async {
        isImporting = true
        importError = nil

        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScoped {
                url.stopAccessingSecurityScopedResource()
            }
            isImporting = false
        }

        do {
            let fingerprint = try fileFingerprint(for: url)
            let existingBook = books.first { $0.sourceFingerprint == fingerprint }
            let importedBook = try importer.import(bookID: existingBook?.id ?? UUID(), from: url, using: fileManager)

            if let existingBook, let existingIndex = books.firstIndex(where: { $0.id == existingBook.id }) {
                books[existingIndex] = importedBook
            } else {
                books.insert(importedBook, at: 0)
            }

            books.sort { $0.importedAt > $1.importedAt }
            try persist()
        } catch {
            importError = error.localizedDescription
        }
    }

    func removeBook(id: UUID) {
        guard let index = books.firstIndex(where: { $0.id == id }) else { return }
        let book = books.remove(at: index)

        do {
            try deleteFiles(for: book)
            try persist()
        } catch {
            importError = error.localizedDescription
        }
    }

    func updateProgress(for bookID: UUID, location: ReaderLocation) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        guard books[index].contains(location: location) else { return }
        if let current = books[index].readingProgress,
           current.chapterID == location.chapterID,
           current.paragraphID == location.paragraphID {
            return
        }

        books[index].readingProgress = location
        scheduleProgressPersist()
    }

    func toggleBookmark(for bookID: UUID, location: ReaderLocation, title: String) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }

        if let bookmarkIndex = books[index].bookmarks.firstIndex(where: {
            $0.chapterID == location.chapterID && $0.paragraphID == location.paragraphID
        }) {
            books[index].bookmarks.remove(at: bookmarkIndex)
        } else {
            books[index].bookmarks.insert(
                BookBookmark(
                    id: UUID(),
                    title: title,
                    chapterID: location.chapterID,
                    paragraphID: location.paragraphID,
                    createdAt: .now
                ),
                at: 0
            )
        }

        progressPersistTask?.cancel()
        try? persist()
    }

    func coverURL(for book: BookRecord) -> URL? {
        guard let relativePath = book.coverRelativePath else { return nil }
        return applicationSupportBaseURL()?.appendingPathComponent(relativePath)
    }

    func epubURL(for book: BookRecord) -> URL? {
        applicationSupportBaseURL()?.appendingPathComponent(book.epubRelativePath)
    }

    private func deleteFiles(for book: BookRecord) throws {
        let folderURL = try EPUBImporter.bookFolderURL(for: book.id, using: fileManager)
        if fileManager.fileExists(atPath: folderURL.path) {
            try fileManager.removeItem(at: folderURL)
        }
    }

    private func fileFingerprint(for url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(books)
        try data.write(to: manifestURL, options: [.atomic])
    }

    private func scheduleProgressPersist() {
        progressPersistTask?.cancel()
        progressPersistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard let self, !Task.isCancelled else { return }
            try? self.persist()
        }
    }

    private static func loadBooks(from url: URL) throws -> [BookRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([BookRecord].self, from: data)
    }

    private func migrateImportedBooksIfNeeded() {
        let staleBooks = books.filter { $0.importVersion < BookRecord.currentImportVersion }
        guard !staleBooks.isEmpty else { return }

        var migratedBooks = books
        var migrationFailures: [String] = []
        var didMigrateAtLeastOneBook = false

        for staleBook in staleBooks {
            guard let index = migratedBooks.firstIndex(where: { $0.id == staleBook.id }) else { continue }

            do {
                migratedBooks[index] = try migratedCopy(of: staleBook)
                didMigrateAtLeastOneBook = true
            } catch {
                migrationFailures.append(staleBook.title)
            }
        }

        if didMigrateAtLeastOneBook {
            books = migratedBooks
            do {
                try persist()
            } catch {
                importError = error.localizedDescription
            }
        }

        if !migrationFailures.isEmpty {
            importError = String(
                localized: "Some books could not be refreshed automatically. Re-import them to rebuild text without embedded ruby."
            )
        }
    }

    private func migratedCopy(of book: BookRecord) throws -> BookRecord {
        guard let storedEPUBURL = epubURL(for: book), fileManager.fileExists(atPath: storedEPUBURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let temporaryEPUBURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(book.id.uuidString)-migration.epub")

        if fileManager.fileExists(atPath: temporaryEPUBURL.path) {
            try fileManager.removeItem(at: temporaryEPUBURL)
        }

        try fileManager.copyItem(at: storedEPUBURL, to: temporaryEPUBURL)
        defer {
            try? fileManager.removeItem(at: temporaryEPUBURL)
        }

        var migratedBook = try importer.import(bookID: book.id, from: temporaryEPUBURL, using: fileManager)
        migratedBook.importedAt = book.importedAt

        if let progress = book.readingProgress, migratedBook.contains(location: progress) {
            migratedBook.readingProgress = progress
        }

        migratedBook.bookmarks = book.bookmarks.compactMap { bookmark in
            let location = ReaderLocation(
                chapterID: bookmark.chapterID,
                paragraphID: bookmark.paragraphID,
                updatedAt: bookmark.createdAt
            )
            guard migratedBook.contains(location: location) else { return nil }

            return BookBookmark(
                id: bookmark.id,
                title: bookmarkTitle(in: migratedBook, fallback: bookmark.title, for: location),
                chapterID: bookmark.chapterID,
                paragraphID: bookmark.paragraphID,
                createdAt: bookmark.createdAt
            )
        }

        return migratedBook
    }

    private func applicationSupportBaseURL() -> URL? {
        try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    }

    private func documentsBaseURL() -> URL? {
        try? fileManager.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    }

    private func importAutomationFixtureIfNeeded() {
        let candidates = [
            applicationSupportBaseURL()?.deletingLastPathComponent().appendingPathComponent("AutomationImport.epub"),
            applicationSupportBaseURL()?.appendingPathComponent("AutomationImport.epub"),
            documentsBaseURL()?.appendingPathComponent("AutomationImport.epub")
        ].compactMap { $0 }

        for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
            do {
                let fingerprint = try fileFingerprint(for: candidate)
                let existingBook = books.first { $0.sourceFingerprint == fingerprint }
                let importedBook = try importer.import(bookID: existingBook?.id ?? UUID(), from: candidate, using: fileManager)

                if let existingBook, let existingIndex = books.firstIndex(where: { $0.id == existingBook.id }) {
                    books[existingIndex] = importedBook
                } else {
                    books.insert(importedBook, at: 0)
                }

                books.sort { $0.importedAt > $1.importedAt }
                try persist()
            } catch {
                importError = error.localizedDescription
            }

            try? fileManager.removeItem(at: candidate)
        }
    }

    private func bookmarkTitle(in book: BookRecord, fallback: String, for location: ReaderLocation) -> String {
        let chapterTitle = book.chapter(for: location)?.title ?? book.title
        let paragraphText = book.chapter(for: location)?
            .paragraphs
            .first(where: { $0.id == location.paragraphID })?
            .text ?? fallback
        let trimmedParagraph = String(paragraphText.prefix(24))
        return "\(chapterTitle) · \(trimmedParagraph)"
    }
}
