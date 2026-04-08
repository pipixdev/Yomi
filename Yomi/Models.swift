//
//  Models.swift
//  Yomi
//

import Foundation

struct BookRecord: Identifiable, Codable, Hashable {
    static let currentImportVersion = 2

    let id: UUID
    var title: String
    var author: String
    var importedAt: Date
    var chapters: [BookChapter]
    var tableOfContents: [BookNavigationPoint]
    var epubRelativePath: String
    var coverRelativePath: String?
    var sourceFingerprint: String?
    var importVersion: Int
    var pageProgression: PageProgression
    var readingProgress: ReaderLocation?
    var bookmarks: [BookBookmark]

    init(
        id: UUID,
        title: String,
        author: String,
        importedAt: Date,
        chapters: [BookChapter],
        tableOfContents: [BookNavigationPoint] = [],
        epubRelativePath: String,
        coverRelativePath: String? = nil,
        sourceFingerprint: String? = nil,
        importVersion: Int = BookRecord.currentImportVersion,
        pageProgression: PageProgression = .default,
        readingProgress: ReaderLocation? = nil,
        bookmarks: [BookBookmark] = []
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.importedAt = importedAt
        self.chapters = chapters
        self.tableOfContents = tableOfContents
        self.epubRelativePath = epubRelativePath
        self.coverRelativePath = coverRelativePath
        self.sourceFingerprint = sourceFingerprint
        self.importVersion = importVersion
        self.pageProgression = pageProgression
        self.readingProgress = readingProgress
        self.bookmarks = bookmarks
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case author
        case importedAt
        case chapters
        case tableOfContents
        case epubRelativePath
        case coverRelativePath
        case sourceFingerprint
        case importVersion
        case pageProgression
        case readingProgress
        case bookmarks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        author = try container.decode(String.self, forKey: .author)
        importedAt = try container.decode(Date.self, forKey: .importedAt)
        chapters = try container.decode([BookChapter].self, forKey: .chapters)
        tableOfContents = try container.decodeIfPresent([BookNavigationPoint].self, forKey: .tableOfContents) ?? []
        epubRelativePath = try container.decode(String.self, forKey: .epubRelativePath)
        coverRelativePath = try container.decodeIfPresent(String.self, forKey: .coverRelativePath)
        sourceFingerprint = try container.decodeIfPresent(String.self, forKey: .sourceFingerprint)
        importVersion = try container.decodeIfPresent(Int.self, forKey: .importVersion) ?? 1
        pageProgression = try container.decodeIfPresent(PageProgression.self, forKey: .pageProgression) ?? .default
        readingProgress = try container.decodeIfPresent(ReaderLocation.self, forKey: .readingProgress)
        bookmarks = try container.decodeIfPresent([BookBookmark].self, forKey: .bookmarks) ?? []
    }

    var firstLocation: ReaderLocation? {
        guard let chapter = chapters.first, let paragraph = chapter.paragraphs.first else { return nil }
        return ReaderLocation(chapterID: chapter.id, paragraphID: paragraph.id, updatedAt: importedAt)
    }

    var effectiveProgress: ReaderLocation? {
        if let readingProgress, contains(location: readingProgress) {
            return readingProgress
        }
        return firstLocation
    }

    func contains(location: ReaderLocation) -> Bool {
        chapters.contains { chapter in
            chapter.id == location.chapterID && chapter.paragraphs.contains { $0.id == location.paragraphID }
        }
    }

    func chapterIndex(for chapterID: String) -> Int? {
        chapters.firstIndex { $0.id == chapterID }
    }

    func chapter(for chapterID: String) -> BookChapter? {
        chapters.first { $0.id == chapterID }
    }

    func paragraphIndex(for location: ReaderLocation) -> Int? {
        chapter(for: location.chapterID)?.paragraphs.firstIndex { $0.id == location.paragraphID }
    }

    func chapter(for location: ReaderLocation) -> BookChapter? {
        chapter(for: location.chapterID)
    }

    func bookmark(for location: ReaderLocation) -> BookBookmark? {
        bookmarks.first { $0.chapterID == location.chapterID && $0.paragraphID == location.paragraphID }
    }

    var progressSummary: String {
        guard
            let location = effectiveProgress,
            let chapterIndex = chapterIndex(for: location.chapterID)
        else {
            return String(localized: "Not started")
        }

        return String(format: String(localized: "Chapter %lld / %lld"), chapterIndex + 1, chapters.count)
    }
}

struct BookChapter: Identifiable, Codable, Hashable {
    let id: String
    var title: String
    var sourceHref: String
    var anchor: String?
    var paragraphs: [BookParagraph]

    init(id: String, title: String, sourceHref: String, anchor: String? = nil, paragraphs: [BookParagraph]) {
        self.id = id
        self.title = title
        self.sourceHref = sourceHref
        self.anchor = anchor
        self.paragraphs = paragraphs
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case sourceHref
        case anchor
        case paragraphs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        sourceHref = try container.decodeIfPresent(String.self, forKey: .sourceHref) ?? id
        anchor = try container.decodeIfPresent(String.self, forKey: .anchor)

        if let paragraphs = try? container.decode([BookParagraph].self, forKey: .paragraphs) {
            self.paragraphs = paragraphs
        } else {
            let legacyParagraphs = try container.decode([String].self, forKey: .paragraphs)
            let chapterID = id
            self.paragraphs = legacyParagraphs.enumerated().map { index, text in
                BookParagraph(
                    id: "\(chapterID)-p\(index)",
                    text: text,
                    role: .body
                )
            }
        }
    }
}

struct BookParagraph: Identifiable, Codable, Hashable {
    let id: String
    var text: String
    var role: BookParagraphRole
    var anchor: String?
}

enum BookParagraphRole: String, Codable, Hashable {
    case heading
    case body
    case quote
    case listItem
    case separator
}

struct BookNavigationPoint: Identifiable, Codable, Hashable {
    let id: String
    var title: String
    var chapterID: String
    var paragraphID: String?
    var anchor: String?
    var children: [BookNavigationPoint]
}

struct ReaderLocation: Codable, Hashable {
    var chapterID: String
    var paragraphID: String
    var updatedAt: Date
}

struct BookBookmark: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var chapterID: String
    var paragraphID: String
    var createdAt: Date
}

enum PageProgression: String, Codable, Hashable {
    case defaultDirection
    case leftToRight
    case rightToLeft

    static let `default` = PageProgression.defaultDirection
}

struct ReaderToken: Identifiable, Hashable {
    let id: Int
    let surface: String
    let reading: String?
    let partOfSpeech: ReaderPartOfSpeech
    let dictionaryForm: String?
}

enum ReaderPartOfSpeech: String, Hashable, CaseIterable {
    case noun
    case verb
    case particle
    case adjective
    case adverb
    case prefix
    case symbol
    case other

    var label: String {
        switch self {
        case .noun:
            return "名词"
        case .verb:
            return "动词"
        case .particle:
            return "助词"
        case .adjective:
            return "形容词"
        case .adverb:
            return "副词"
        case .prefix:
            return "前缀"
        case .symbol:
            return "符号"
        case .other:
            return "其他"
        }
    }
}
