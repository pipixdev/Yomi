//
//  EPUBImporter.swift
//  Yomi
//

import Foundation
import SwiftSoup
import ZIPFoundation

enum EPUBImportError: LocalizedError {
    case invalidContainer
    case invalidPackage
    case unsupportedBook

    var errorDescription: String? {
        switch self {
        case .invalidContainer:
            return String(localized: "Unable to read EPUB container.")
        case .invalidPackage:
            return String(localized: "Unable to parse EPUB package.")
        case .unsupportedBook:
            return String(localized: "This EPUB does not contain readable body content.")
        }
    }
}

struct EPUBImporter {
    func `import`(bookID: UUID, from sourceURL: URL, using fileManager: FileManager = .default) throws -> BookRecord {
        let folderURL = try Self.bookFolderURL(for: bookID, using: fileManager)
        let epubURL = folderURL.appendingPathComponent("book.epub")
        let extractionURL = folderURL.appendingPathComponent("extracted", isDirectory: true)

        if fileManager.fileExists(atPath: folderURL.path) {
            try fileManager.removeItem(at: folderURL)
        }

        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try fileManager.copyItem(at: sourceURL, to: epubURL)
        try fileManager.createDirectory(at: extractionURL, withIntermediateDirectories: true)

        try unzip(epubURL: epubURL, to: extractionURL)

        let containerURL = extractionURL.appendingPathComponent("META-INF/container.xml")
        let containerXML = try String(contentsOf: containerURL, encoding: .utf8)
        guard let packageRelativePath = firstMatch(in: containerXML, pattern: #"full-path="([^"]+)""#, group: 1) else {
            throw EPUBImportError.invalidContainer
        }

        let packageURL = extractionURL.appendingPathComponent(packageRelativePath)
        let packageDirectory = packageURL.deletingLastPathComponent()
        let packageXML = try String(contentsOf: packageURL, encoding: .utf8)
        let packageDocument = try OPFDocument(xml: packageXML)

        var chapters: [BookChapter] = []
        for item in packageDocument.spineItems {
            guard let href = packageDocument.manifest[item] else { continue }
            let chapterURL = packageDirectory.appendingPathComponent(href)
            let html = try String(contentsOf: chapterURL, encoding: .utf8)
            let paragraphs = try extractParagraphs(fromHTML: html)
            guard !paragraphs.isEmpty else { continue }

            chapters.append(
                BookChapter(
                    id: href,
                    title: prettifiedTitle(from: href, fallback: packageDocument.title),
                    paragraphs: paragraphs
                )
            )
        }

        guard !chapters.isEmpty else {
            throw EPUBImportError.unsupportedBook
        }

        let coverPath = try extractCover(from: packageDocument, extractionRoot: extractionURL, packageDirectory: packageDirectory)

        return BookRecord(
            id: bookID,
            title: packageDocument.title,
            author: packageDocument.author,
            importedAt: Date(),
            chapters: chapters,
            epubRelativePath: "Books/\(bookID.uuidString)/book.epub",
            coverRelativePath: coverPath
        )
    }

    static func bookFolderURL(for bookID: UUID, using fileManager: FileManager = .default) throws -> URL {
        let root = try rootURL(using: fileManager)
        return root.appendingPathComponent(bookID.uuidString, isDirectory: true)
    }

    static func rootURL(using fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = base.appendingPathComponent("Books", isDirectory: true)
        if !fileManager.fileExists(atPath: root.path) {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return root
    }

    private func unzip(epubURL: URL, to destinationURL: URL) throws {
        let archive = try Archive(url: epubURL, accessMode: .read)

        for entry in archive {
            let entryURL = destinationURL.appendingPathComponent(entry.path)
            let parentURL = entryURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)

            if entry.path.hasSuffix("/") {
                try FileManager.default.createDirectory(at: entryURL, withIntermediateDirectories: true)
            } else {
                _ = try archive.extract(entry, to: entryURL)
            }
        }
    }

    private func extractParagraphs(fromHTML html: String) throws -> [String] {
        let doc = try SwiftSoup.parse(html)
        try doc.select("script, style, nav").remove()

        let blocks = try doc.select("body h1, body h2, body h3, body p, body li, body blockquote, body div")
        var paragraphs = blocks.compactMap { element -> String? in
            let text = try? element.text(trimAndNormaliseWhitespace: true)
            guard let text else { return nil }
            let normalized = text.replacingOccurrences(of: "\u{00A0}", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized.count > 1 else { return nil }
            return normalized
        }

        if paragraphs.isEmpty {
            let bodyText = try doc.body()?.text(trimAndNormaliseWhitespace: true) ?? ""
            paragraphs = bodyText
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        return paragraphs.removingNearDuplicates()
    }

    private func extractCover(from package: OPFDocument, extractionRoot: URL, packageDirectory: URL) throws -> String? {
        guard let coverHref = package.coverHref else { return nil }
        let sourceURL = packageDirectory.appendingPathComponent(coverHref)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return nil }

        let coverDirectory = extractionRoot.deletingLastPathComponent()
        let destinationURL = coverDirectory.appendingPathComponent("cover.\(sourceURL.pathExtension)")

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return "Books/\(coverDirectory.lastPathComponent)/\(destinationURL.lastPathComponent)"
    }

    private func firstMatch(in text: String, pattern: String, group: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard
            let match = regex.firstMatch(in: text, options: [], range: range),
            let captureRange = Range(match.range(at: group), in: text)
        else {
            return nil
        }

        return String(text[captureRange])
    }

    private func prettifiedTitle(from href: String, fallback: String) -> String {
        let filename = URL(fileURLWithPath: href).deletingPathExtension().lastPathComponent
        let cleaned = filename.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return cleaned.isEmpty ? fallback : cleaned
    }
}

private struct OPFDocument {
    let title: String
    let author: String
    let manifest: [String: String]
    let spineItems: [String]
    let coverHref: String?

    init(xml: String) throws {
        let parser = OPFParser()
        guard parser.parse(xml: xml) else {
            throw EPUBImportError.invalidPackage
        }

        title = parser.title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? String(localized: "Untitled Novel")
        author = parser.author?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? String(localized: "Unknown Author")
        manifest = parser.manifest
        spineItems = parser.spine

        if let coverID = parser.coverID, let href = parser.manifest[coverID] {
            coverHref = href
        } else if let id = parser.coverPropertyID, let href = parser.manifest[id] {
            coverHref = href
        } else {
            coverHref = nil
        }
    }
}

private final class OPFParser: NSObject, XMLParserDelegate {
    private var currentCharacters = ""

    var title: String?
    var author: String?
    var coverID: String?
    var coverPropertyID: String?
    var manifest: [String: String] = [:]
    var spine: [String] = []

    func parse(xml: String) -> Bool {
        guard let data = xml.data(using: .utf8) else { return false }
        let parser = XMLParser(data: data)
        parser.delegate = self
        return parser.parse()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentCharacters = ""

        if elementName == "meta", attributeDict["name"] == "cover" {
            coverID = attributeDict["content"]
        }

        if elementName == "item" {
            if let id = attributeDict["id"], let href = attributeDict["href"] {
                manifest[id] = href
            }

            if let properties = attributeDict["properties"], properties.contains("cover-image") {
                coverPropertyID = attributeDict["id"]
            }
        }

        if elementName == "itemref", let idref = attributeDict["idref"] {
            spine.append(idref)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentCharacters += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let value = currentCharacters.trimmingCharacters(in: .whitespacesAndNewlines)
        if elementName.hasSuffix("title"), title == nil, !value.isEmpty {
            title = value
        }

        if elementName.hasSuffix("creator"), author == nil, !value.isEmpty {
            author = value
        }
    }
}

private extension Array where Element == String {
    func removingNearDuplicates() -> [String] {
        var result: [String] = []
        var seen = Set<String>()

        for text in self {
            let key = text.replacingOccurrences(of: " ", with: "")
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(text)
        }

        return result
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
