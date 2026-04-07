//
//  EPUBImporter.swift
//  Yomi
//

import CryptoKit
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
        let sourceFingerprint = try fingerprint(for: sourceURL)
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

        let packageRelativePath = try packagePath(in: extractionURL)
        let packageURL = extractionURL.appendingPathComponent(packageRelativePath)
        let packageDirectory = packageURL.deletingLastPathComponent()
        let packageXML = try loadText(from: packageURL)
        let packageDocument = try OPFDocument(packageRelativePath: packageRelativePath, xml: packageXML)
        let navigation = try loadNavigation(for: packageDocument, packageDirectory: packageDirectory)
        let fallbackTitles = firstNavigationTitles(from: navigation)
        let extractedChapters = try extractChapters(
            from: packageDocument,
            packageDirectory: packageDirectory,
            fallbackTitles: fallbackTitles
        )

        let chapters = extractedChapters.map(\.chapter)
        guard !chapters.isEmpty else {
            throw EPUBImportError.unsupportedBook
        }

        let tableOfContents = resolveTableOfContents(
            navigation,
            with: extractedChapters,
            fallbackTitle: packageDocument.title
        )

        let coverPath = try extractCover(
            from: packageDocument,
            extractionRoot: extractionURL,
            packageDirectory: packageDirectory
        )

        return BookRecord(
            id: bookID,
            title: packageDocument.title,
            author: packageDocument.author,
            importedAt: Date(),
            chapters: chapters,
            tableOfContents: tableOfContents.isEmpty ? derivedNavigation(from: chapters) : tableOfContents,
            epubRelativePath: "Books/\(bookID.uuidString)/book.epub",
            coverRelativePath: coverPath,
            sourceFingerprint: sourceFingerprint,
            pageProgression: packageDocument.pageProgression,
            readingProgress: chapters.first.flatMap { chapter in
                chapter.paragraphs.first.map {
                    ReaderLocation(chapterID: chapter.id, paragraphID: $0.id, updatedAt: .now)
                }
            }
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

    private func packagePath(in extractionURL: URL) throws -> String {
        let containerURL = extractionURL.appendingPathComponent("META-INF/container.xml")
        let containerXML = try loadText(from: containerURL)
        guard let packageRelativePath = firstMatch(in: containerXML, pattern: #"full-path="([^"]+)""#, group: 1) else {
            throw EPUBImportError.invalidContainer
        }
        return normalizedRelativePath(packageRelativePath)
    }

    private func loadNavigation(for package: OPFDocument, packageDirectory: URL) throws -> [NavigationReference] {
        if let navigationItem = package.navigationItem {
            let navigationURL = packageDirectory.appendingPathComponent(navigationItem.href)
            let navigationHTML = try loadText(from: navigationURL)
            let document = try SwiftSoup.parse(navigationHTML)
            return try parseNavigationDocument(document, baseHref: navigationItem.href)
        }

        guard let ncxItem = package.ncxItem else { return [] }
        let ncxURL = packageDirectory.appendingPathComponent(ncxItem.href)
        let ncxXML = try loadText(from: ncxURL)
        let parser = NCXParser(baseHref: ncxItem.href)
        return parser.parse(xml: ncxXML)
    }

    private func extractChapters(
        from package: OPFDocument,
        packageDirectory: URL,
        fallbackTitles: [String: String]
    ) throws -> [ExtractedChapter] {
        var chapters: [ExtractedChapter] = []

        for spineItem in package.spineItems where spineItem.linear {
            guard let manifestItem = package.manifest[spineItem.idref] else { continue }
            guard manifestItem.mediaType.contains("html") else { continue }

            let chapterURL = packageDirectory.appendingPathComponent(manifestItem.href)
            let html = try loadText(from: chapterURL)
            let chapter = try extractChapter(
                fromHTML: html,
                href: manifestItem.href,
                fallbackTitle: fallbackTitles[normalizedRelativePath(manifestItem.href)] ?? package.title
            )

            guard !chapter.chapter.paragraphs.isEmpty else { continue }
            chapters.append(chapter)
        }

        return chapters
    }

    private func extractChapter(fromHTML html: String, href: String, fallbackTitle: String) throws -> ExtractedChapter {
        let doc = try SwiftSoup.parse(html)
        try doc.select("script, style, nav, noscript").remove()

        guard let body = doc.body() else {
            return ExtractedChapter(
                chapter: BookChapter(id: chapterID(for: href), title: fallbackTitle, sourceHref: href, paragraphs: []),
                anchorToParagraph: [:]
            )
        }

        let blockTags: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6", "p", "li", "blockquote", "div"]
        var paragraphs: [BookParagraph] = []
        var anchorToParagraph: [String: String] = [:]
        var detectedTitle: String?

        for element in try body.getAllElements().array() {
            let tagName = element.tagNameNormalised()
            guard blockTags.contains(tagName) else { continue }
            guard shouldExtract(element: element, within: blockTags) else { continue }

            let text = normalizedText(try element.text(trimAndNormaliseWhitespace: true))
            let role = paragraphRole(for: tagName, text: text)
            guard !text.isEmpty || role == .separator else { continue }
            guard role == .separator || text.count > 1 else { continue }

            let paragraphID = "\(chapterID(for: href))-p\(paragraphs.count)"
            let anchors = try anchors(for: element)
            let paragraph = BookParagraph(
                id: paragraphID,
                text: text,
                role: role,
                anchor: anchors.first
            )

            if detectedTitle == nil, role == .heading {
                detectedTitle = text
            }

            paragraphs.append(paragraph)
            for anchor in anchors {
                anchorToParagraph[anchor] = paragraphID
            }
        }

        if paragraphs.isEmpty {
            let fallbackParagraphs = normalizedText(try body.text(trimAndNormaliseWhitespace: true))
                .components(separatedBy: .newlines)
                .map(normalizedText)
                .filter { !$0.isEmpty }

            paragraphs = fallbackParagraphs.enumerated().map { index, text in
                BookParagraph(
                    id: "\(chapterID(for: href))-p\(index)",
                    text: text,
                    role: .body
                )
            }
        }

        let chapterTitle = detectedTitle?.nonEmpty ?? fallbackTitle
        let chapter = BookChapter(
            id: chapterID(for: href),
            title: chapterTitle,
            sourceHref: href,
            anchor: paragraphs.first?.anchor,
            paragraphs: paragraphs
        )

        return ExtractedChapter(chapter: chapter, anchorToParagraph: anchorToParagraph)
    }

    private func resolveTableOfContents(
        _ references: [NavigationReference],
        with chapters: [ExtractedChapter],
        fallbackTitle: String
    ) -> [BookNavigationPoint] {
        let normalizedPathToChapter = Dictionary(uniqueKeysWithValues: chapters.map {
            (normalizedRelativePath($0.chapter.sourceHref), $0.chapter)
        })

        let anchors = chapters.reduce(into: [String: (chapterID: String, paragraphID: String?)]()) { result, chapter in
            for (anchor, paragraphID) in chapter.anchorToParagraph {
                result[anchor] = (chapter.chapter.id, paragraphID)
            }
        }

        let resolved = references.compactMap { reference in
            resolve(reference: reference, chapters: normalizedPathToChapter, anchors: anchors)
        }

        guard !resolved.isEmpty else {
            return derivedNavigation(from: chapters.map(\.chapter), fallbackTitle: fallbackTitle)
        }

        return resolved
    }

    private func resolve(
        reference: NavigationReference,
        chapters: [String: BookChapter],
        anchors: [String: (chapterID: String, paragraphID: String?)]
    ) -> BookNavigationPoint? {
        let components = reference.src.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let relativeHref = normalizedRelativePath(components.first ?? "")
        let anchor = components.count > 1 ? components[1] : nil

        let matchedChapter: BookChapter?
        if !relativeHref.isEmpty {
            matchedChapter = chapters[relativeHref]
        } else if let anchor, let anchorMatch = anchors[anchor] {
            matchedChapter = chapters.values.first { $0.id == anchorMatch.chapterID }
        } else {
            matchedChapter = nil
        }

        guard let chapter = matchedChapter else { return nil }
        let paragraphID = anchor.flatMap { anchors[$0]?.paragraphID } ?? chapter.paragraphs.first?.id
        let children = reference.children.compactMap { child in
            resolve(reference: child, chapters: chapters, anchors: anchors)
        }

        return BookNavigationPoint(
            id: reference.id,
            title: reference.title.nonEmpty ?? chapter.title,
            chapterID: chapter.id,
            paragraphID: paragraphID,
            anchor: anchor,
            children: children
        )
    }

    private func derivedNavigation(from chapters: [BookChapter], fallbackTitle: String? = nil) -> [BookNavigationPoint] {
        let title = fallbackTitle?.nonEmpty
        return chapters.enumerated().map { index, chapter in
            BookNavigationPoint(
                id: "derived-\(chapter.id)",
                title: chapter.title.nonEmpty ?? title ?? "Chapter \(index + 1)",
                chapterID: chapter.id,
                paragraphID: chapter.paragraphs.first?.id,
                anchor: chapter.anchor,
                children: []
            )
        }
    }

    private func firstNavigationTitles(from references: [NavigationReference]) -> [String: String] {
        var titles: [String: String] = [:]

        func walk(_ items: [NavigationReference]) {
            for item in items {
                let href = normalizedRelativePath(item.src.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "")
                if !href.isEmpty, titles[href] == nil {
                    titles[href] = item.title
                }
                walk(item.children)
            }
        }

        walk(references)
        return titles
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

    private func parseNavigationDocument(_ document: Document, baseHref: String) throws -> [NavigationReference] {
        let tocLinks = try document.select("nav a[href], body a[href]").array()
        var references: [NavigationReference] = []

        for (index, element) in tocLinks.enumerated() {
            let title = normalizedText(try element.text(trimAndNormaliseWhitespace: true))
            let href = try element.attr("href")
            guard !href.isEmpty, !title.isEmpty else { continue }

            references.append(
                NavigationReference(
                    id: "nav-\(index)",
                    title: title,
                    src: resolveHref(href, relativeTo: baseHref),
                    children: []
                )
            )
        }

        return references
    }

    private func shouldExtract(element: Element, within blockTags: Set<String>) -> Bool {
        if element.tagNameNormalised() == "div" {
            return element.children().array().allSatisfy { child in
                !blockTags.contains(child.tagNameNormalised())
            }
        }

        return true
    }

    private func anchors(for element: Element) throws -> [String] {
        var anchors: [String] = []

        if let identifier = element.id().nonEmpty {
            anchors.append(identifier)
        }

        for descendant in try element.select("[id], a[name]").array() {
            let identifier = try descendant.id().nonEmpty ?? descendant.attr("name").nonEmpty
            if let identifier, !anchors.contains(identifier) {
                anchors.append(identifier)
            }
        }

        return anchors
    }

    private func paragraphRole(for tagName: String, text: String) -> BookParagraphRole {
        if tagName.hasPrefix("h") {
            return .heading
        }

        if text == "○" || text == "●" {
            return .separator
        }

        switch tagName {
        case "blockquote":
            return .quote
        case "li":
            return .listItem
        default:
            return .body
        }
    }

    private func loadText(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)

        if let text = String(data: data, encoding: .utf8) {
            return text
        }

        if let text = String(data: data, encoding: .unicode) {
            return text
        }

        if let text = String(data: data, encoding: .shiftJIS) {
            return text
        }

        return String(decoding: data, as: UTF8.self)
    }

    private func chapterID(for href: String) -> String {
        normalizedRelativePath(href)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    private func resolveHref(_ href: String, relativeTo baseHref: String) -> String {
        let components = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let pathComponent = components.first ?? ""
        let anchor = components.count > 1 ? components[1] : nil

        let resolvedPath: String
        if pathComponent.isEmpty {
            resolvedPath = normalizedRelativePath(baseHref)
        } else {
            let baseDirectory = (baseHref as NSString).deletingLastPathComponent
            resolvedPath = normalizedRelativePath((baseDirectory as NSString).appendingPathComponent(pathComponent))
        }

        if let anchor, !anchor.isEmpty {
            return "\(resolvedPath)#\(anchor)"
        }

        return resolvedPath
    }

    private func normalizedRelativePath(_ path: String) -> String {
        let expanded = ("/" as NSString).appendingPathComponent(path)
        let standardized = (expanded as NSString).standardizingPath
        return String(standardized.drop(while: { $0 == "/" }))
    }

    private func normalizedText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{3000}", with: "　")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func fingerprint(for url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }
}

private struct ExtractedChapter {
    let chapter: BookChapter
    let anchorToParagraph: [String: String]
}

private struct ManifestItem {
    let id: String
    let href: String
    let mediaType: String
    let properties: Set<String>
}

private struct SpineItem {
    let idref: String
    let linear: Bool
}

private struct NavigationReference {
    let id: String
    let title: String
    let src: String
    let children: [NavigationReference]
}

private struct OPFDocument {
    let title: String
    let author: String
    let manifest: [String: ManifestItem]
    let spineItems: [SpineItem]
    let coverHref: String?
    let ncxItem: ManifestItem?
    let navigationItem: ManifestItem?
    let pageProgression: PageProgression

    init(packageRelativePath: String, xml: String) throws {
        let parser = OPFParser()
        guard parser.parse(xml: xml) else {
            throw EPUBImportError.invalidPackage
        }

        title = parser.title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? String(localized: "Untitled Novel")
        author = parser.author?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? String(localized: "Unknown Author")
        manifest = parser.manifest
        spineItems = parser.spine
        pageProgression = parser.pageProgression

        if let coverID = parser.coverID, let href = parser.manifest[coverID]?.href {
            coverHref = href
        } else if let id = parser.coverPropertyID, let href = parser.manifest[id]?.href {
            coverHref = href
        } else {
            coverHref = nil
        }

        if let tocID = parser.tocID {
            ncxItem = parser.manifest[tocID]
        } else {
            ncxItem = parser.manifest.values.first(where: { $0.mediaType == "application/x-dtbncx+xml" })
        }

        navigationItem = parser.manifest.values.first(where: { $0.properties.contains("nav") })
        _ = packageRelativePath
    }
}

private final class OPFParser: NSObject, XMLParserDelegate {
    private var currentCharacters = ""

    var title: String?
    var author: String?
    var coverID: String?
    var coverPropertyID: String?
    var tocID: String?
    var pageProgression: PageProgression = .default
    var manifest: [String: ManifestItem] = [:]
    var spine: [SpineItem] = []

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

        if elementName == "item",
           let id = attributeDict["id"],
           let href = attributeDict["href"],
           let mediaType = attributeDict["media-type"] {
            manifest[id] = ManifestItem(
                id: id,
                href: href,
                mediaType: mediaType,
                properties: Set((attributeDict["properties"] ?? "").split(separator: " ").map(String.init))
            )

            if (attributeDict["properties"] ?? "").contains("cover-image") {
                coverPropertyID = id
            }
        }

        if elementName == "spine" {
            tocID = attributeDict["toc"]
            switch attributeDict["page-progression-direction"]?.lowercased() {
            case "rtl":
                pageProgression = .rightToLeft
            case "ltr":
                pageProgression = .leftToRight
            default:
                pageProgression = .default
            }
        }

        if elementName == "itemref", let idref = attributeDict["idref"] {
            let linear = attributeDict["linear"]?.lowercased() != "no"
            spine.append(SpineItem(idref: idref, linear: linear))
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

private final class NCXParser: NSObject, XMLParserDelegate {
    private struct MutablePoint {
        var id: String
        var title: String = ""
        var src: String = ""
        var children: [MutablePoint] = []
    }

    private let baseHref: String
    private var stack: [MutablePoint] = []
    private var roots: [MutablePoint] = []
    private var currentText = ""
    private var isInsideNavLabelText = false

    init(baseHref: String) {
        self.baseHref = baseHref
    }

    func parse(xml: String) -> [NavigationReference] {
        guard let data = xml.data(using: .utf8) else { return [] }
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else { return [] }
        return roots.map(toNavigationReference)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentText = ""

        if elementName == "navPoint" {
            stack.append(MutablePoint(id: attributeDict["id"] ?? UUID().uuidString))
        } else if elementName == "content", var point = stack.popLast() {
            point.src = resolveHref(attributeDict["src"] ?? "")
            stack.append(point)
        } else if elementName == "text" {
            isInsideNavLabelText = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "text", isInsideNavLabelText, var point = stack.popLast() {
            point.title = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            stack.append(point)
            isInsideNavLabelText = false
        } else if elementName == "navPoint", let point = stack.popLast() {
            if var parent = stack.popLast() {
                parent.children.append(point)
                stack.append(parent)
            } else {
                roots.append(point)
            }
        }

        currentText = ""
    }

    private func resolveHref(_ href: String) -> String {
        let components = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let pathComponent = components.first ?? ""
        let baseDirectory = (baseHref as NSString).deletingLastPathComponent
        let resolvedPath = normalizedRelativePath((baseDirectory as NSString).appendingPathComponent(pathComponent))
        if components.count > 1 {
            return "\(resolvedPath)#\(components[1])"
        }
        return resolvedPath
    }

    private func normalizedRelativePath(_ path: String) -> String {
        let expanded = ("/" as NSString).appendingPathComponent(path)
        let standardized = (expanded as NSString).standardizingPath
        return String(standardized.drop(while: { $0 == "/" }))
    }

    private func toNavigationReference(_ point: MutablePoint) -> NavigationReference {
        NavigationReference(
            id: point.id,
            title: point.title,
            src: point.src,
            children: point.children.map(toNavigationReference)
        )
    }
}

private extension Element {
    func tagNameNormalised() -> String {
        tagName().lowercased()
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
