//
//  LibraryStore.swift
//  Yomi
//

import Foundation
import Combine

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var books: [BookRecord] = []
    @Published var isImporting = false
    @Published var importError: String?

    private let importer = EPUBImporter()
    private let manifestURL: URL

    init(fileManager: FileManager = .default) {
        var resolvedManifestURL: URL

        do {
            let root = try EPUBImporter.rootURL(using: fileManager)
            resolvedManifestURL = root.appendingPathComponent("library.json")
            books = try Self.loadBooks(from: resolvedManifestURL)
        } catch {
            resolvedManifestURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("library.json")
            books = []
            importError = error.localizedDescription
        }

        manifestURL = resolvedManifestURL

#if DEBUG
        if books.isEmpty {
            books = [SampleLibrary.previewBook]
            try? persist()
        }
#endif
    }

    func importBook(from url: URL) async {
        isImporting = true
        importError = nil

        do {
            let book = try importer.import(bookID: UUID(), from: url)
            books.insert(book, at: 0)
            try persist()
        } catch {
            importError = error.localizedDescription
        }

        isImporting = false
    }

    func coverURL(for book: BookRecord) -> URL? {
        guard let relativePath = book.coverRelativePath else { return nil }
        return applicationSupportBaseURL()?.appendingPathComponent(relativePath)
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(books)
        try data.write(to: manifestURL, options: [.atomic])
    }

    private static func loadBooks(from url: URL) throws -> [BookRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([BookRecord].self, from: data)
    }

    private func applicationSupportBaseURL() -> URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    }
}
