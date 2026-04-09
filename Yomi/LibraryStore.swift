//
//  LibraryStore.swift
//  Yomi
//

import CryptoKit
import Foundation
import Combine

#if canImport(UIKit)
import UIKit
#endif

#if canImport(ReadiumShared) && canImport(ReadiumStreamer) && canImport(UIKit)
import ReadiumShared
import ReadiumStreamer
#endif

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var books: [BookRecord] = []
    @Published var isImporting = false
    @Published var importProgressFraction: Double?
    @Published var importProgressLabel = String(localized: "Importing EPUB…")
    @Published var importError: String?

    private let manifestURL: URL
    private let fileManager: FileManager

#if canImport(ReadiumShared) && canImport(ReadiumStreamer) && canImport(UIKit)
    private var importer = ReadiumLibraryImporter()
#endif

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        var resolvedManifestURL: URL
        do {
            let root = try Self.booksRootURL(using: fileManager)
            resolvedManifestURL = root.deletingLastPathComponent().appendingPathComponent("library.json")
            books = try Self.loadBooks(from: resolvedManifestURL)
        } catch {
            resolvedManifestURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("library.json")
            books = []
            importError = error.localizedDescription
        }

        manifestURL = resolvedManifestURL
    }

    func book(id: UUID) -> BookRecord? {
        books.first { $0.id == id }
    }

    func importBook(from url: URL) async {
        isImporting = true
        importProgressFraction = 0
        importProgressLabel = String(localized: "Preparing import…")
        importError = nil

        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScoped {
                url.stopAccessingSecurityScopedResource()
            }
            importProgressFraction = nil
            isImporting = false
        }

#if canImport(ReadiumShared) && canImport(ReadiumStreamer) && canImport(UIKit)
        do {
            let fingerprint = try fileFingerprint(for: url)
            let existingBook = books.first { $0.sourceFingerprint == fingerprint }
            let importedBook = try await importer.importBook(
                bookID: existingBook?.id ?? UUID(),
                from: url,
                sourceFingerprint: fingerprint,
                using: fileManager,
                progress: { [weak self] fraction, label in
                    Task { @MainActor [weak self] in
                        self?.importProgressFraction = fraction
                        self?.importProgressLabel = label
                    }
                }
            )

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
#else
        importError = String(localized: "Readium reader is available on iOS only in this build.")
#endif
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

#if canImport(ReadiumShared) && canImport(ReadiumStreamer) && canImport(UIKit)
    func updateReadingProgress(for bookID: UUID, locator: Locator) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }

        books[index].lastReadLocatorJSON = try? locator.jsonString()
        books[index].readingProgression = locator.locations.totalProgression ?? locator.locations.progression
        try? persist()
    }
#endif

    func coverURL(for book: BookRecord) -> URL? {
        guard let relativePath = book.coverRelativePath else { return nil }
        return applicationSupportBaseURL()?.appendingPathComponent(relativePath)
    }

    func epubURL(for book: BookRecord) -> URL? {
        applicationSupportBaseURL()?.appendingPathComponent(book.epubRelativePath)
    }

    func normalizedURL(for book: BookRecord) -> URL? {
        guard let relativePath = book.normalizedRelativePath else { return nil }
        return applicationSupportBaseURL()?.appendingPathComponent(relativePath)
    }

    private func deleteFiles(for book: BookRecord) throws {
        let folderURL = try Self.bookFolderURL(for: book.id, using: fileManager)
        if fileManager.fileExists(atPath: folderURL.path) {
            try fileManager.removeItem(at: folderURL)
        }
    }

    private func fileFingerprint(for url: URL) throws -> String {
        guard let stream = InputStream(url: url) else {
            throw CocoaError(.fileReadUnknown)
        }

        stream.open()
        defer {
            stream.close()
        }

        var hasher = SHA256()
        let bufferSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer {
            buffer.deallocate()
        }

        while stream.hasBytesAvailable {
            let readCount = stream.read(buffer, maxLength: bufferSize)
            if readCount < 0 {
                throw stream.streamError ?? CocoaError(.fileReadUnknown)
            }
            if readCount == 0 {
                break
            }

            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: readCount))
        }

        let digest = hasher.finalize()
        return digest.compactMap { String(format: "%02x", $0) }.joined()
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

    static func bookFolderURL(for bookID: UUID, using fileManager: FileManager = .default) throws -> URL {
        let root = try booksRootURL(using: fileManager)
        return root.appendingPathComponent(bookID.uuidString, isDirectory: true)
    }

    static func booksRootURL(using fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = base.appendingPathComponent("Books", isDirectory: true)
        if !fileManager.fileExists(atPath: root.path) {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return root
    }

    private func applicationSupportBaseURL() -> URL? {
        try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    }
}

#if canImport(ReadiumShared) && canImport(ReadiumStreamer) && canImport(UIKit)
private final class ReadiumLibraryImporter {
    private let normalizer = EPUBImportNormalizer()
    private let httpClient = DefaultHTTPClient()
    private lazy var assetRetriever = AssetRetriever(httpClient: httpClient)
    private lazy var publicationOpener = PublicationOpener(
        parser: DefaultPublicationParser(
            httpClient: httpClient,
            assetRetriever: assetRetriever,
            pdfFactory: DefaultPDFDocumentFactory()
        )
    )

    func importBook(
        bookID: UUID,
        from sourceURL: URL,
        sourceFingerprint: String,
        using fileManager: FileManager = .default,
        progress: @escaping (_ fraction: Double, _ label: String) -> Void
    ) async throws -> BookRecord {
        let folderURL = try LibraryStore.bookFolderURL(for: bookID, using: fileManager)
        let epubURL = folderURL.appendingPathComponent("book.epub")
        let normalizedFolderURL = folderURL.appendingPathComponent("normalized", isDirectory: true)

        progress(0.05, String(localized: "Copying EPUB…"))

        if fileManager.fileExists(atPath: folderURL.path) {
            try fileManager.removeItem(at: folderURL)
        }

        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try fileManager.copyItem(at: sourceURL, to: epubURL)
        try fileManager.createDirectory(at: normalizedFolderURL, withIntermediateDirectories: true)

        guard let absoluteURL = epubURL.anyURL.absoluteURL else {
            throw CocoaError(.fileReadUnknown)
        }

        progress(0.15, String(localized: "Parsing publication…"))
        let asset = try await assetRetriever.retrieve(url: absoluteURL).get()
        let publication = try await publicationOpener.open(
            asset: asset,
            allowUserInteraction: false,
            sender: nil
        ).get()
        defer {
            publication.close()
        }

        guard publication.conforms(to: .epub) else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }

        progress(0.25, String(localized: "Extracting cover…"))
        let coverRelativePath = try await saveCoverIfAvailable(
            publication: publication,
            folderURL: folderURL,
            bookID: bookID,
            using: fileManager
        )

        guard case let .container(containerAsset) = asset else {
            throw CocoaError(.fileReadUnknown)
        }

        try await normalizer.normalize(
            container: containerAsset.container,
            bookID: bookID,
            outputDirectory: normalizedFolderURL,
            progress: progress
        )

        let title = publication.metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = sourceURL.deletingPathExtension().lastPathComponent
        let author = publication.metadata.authors.map(\.name).joined(separator: ", ")

        return BookRecord(
            id: bookID,
            title: (title?.isEmpty == false ? title! : fallbackTitle),
            author: author.isEmpty ? String(localized: "Unknown Author") : author,
            importedAt: .now,
            epubRelativePath: "Books/\(bookID.uuidString)/book.epub",
            normalizedRelativePath: "Books/\(bookID.uuidString)/normalized",
            normalizedVersion: EPUBImportNormalizer.version,
            coverRelativePath: coverRelativePath,
            sourceFingerprint: sourceFingerprint
        )
    }

    private func saveCoverIfAvailable(
        publication: Publication,
        folderURL: URL,
        bookID: UUID,
        using fileManager: FileManager
    ) async throws -> String? {
        guard let image = try await publication.cover().get(),
              let data = image.pngData() else {
            return nil
        }

        let coverURL = folderURL.appendingPathComponent("cover.png")
        if fileManager.fileExists(atPath: coverURL.path) {
            try fileManager.removeItem(at: coverURL)
        }

        try data.write(to: coverURL, options: [.atomic])
        return "Books/\(bookID.uuidString)/cover.png"
    }
}
#endif
