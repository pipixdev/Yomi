//
//  Models.swift
//  Yomi
//

import Foundation

struct BookRecord: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var author: String
    var importedAt: Date
    var epubRelativePath: String
    var normalizedRelativePath: String?
    var normalizedVersion: Int?
    var coverRelativePath: String?
    var sourceFingerprint: String?
    var lastReadLocatorJSON: String?
    var readingProgression: Double?

    init(
        id: UUID,
        title: String,
        author: String,
        importedAt: Date,
        epubRelativePath: String,
        normalizedRelativePath: String? = nil,
        normalizedVersion: Int? = nil,
        coverRelativePath: String? = nil,
        sourceFingerprint: String? = nil,
        lastReadLocatorJSON: String? = nil,
        readingProgression: Double? = nil
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.importedAt = importedAt
        self.epubRelativePath = epubRelativePath
        self.normalizedRelativePath = normalizedRelativePath
        self.normalizedVersion = normalizedVersion
        self.coverRelativePath = coverRelativePath
        self.sourceFingerprint = sourceFingerprint
        self.lastReadLocatorJSON = lastReadLocatorJSON
        self.readingProgression = readingProgression
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case author
        case importedAt
        case epubRelativePath
        case normalizedRelativePath
        case normalizedVersion
        case coverRelativePath
        case sourceFingerprint
        case lastReadLocatorJSON
        case readingProgression
    }

    // Keep backward decoding support for old persisted library records.
    private enum LegacyCodingKeys: String, CodingKey {
        case readingProgress
    }

    var progressSummary: String {
        guard let readingProgression else {
            return String(localized: "Not started")
        }

        let percentage = max(0, min(100, Int((readingProgression * 100).rounded())))
        return String(format: String(localized: "%lld%%"), percentage)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        author = try container.decode(String.self, forKey: .author)
        importedAt = try container.decode(Date.self, forKey: .importedAt)
        epubRelativePath = try container.decode(String.self, forKey: .epubRelativePath)
        normalizedRelativePath = try container.decodeIfPresent(String.self, forKey: .normalizedRelativePath)
        normalizedVersion = try container.decodeIfPresent(Int.self, forKey: .normalizedVersion)
        coverRelativePath = try container.decodeIfPresent(String.self, forKey: .coverRelativePath)
        sourceFingerprint = try container.decodeIfPresent(String.self, forKey: .sourceFingerprint)
        lastReadLocatorJSON = try container.decodeIfPresent(String.self, forKey: .lastReadLocatorJSON)
        readingProgression = try container.decodeIfPresent(Double.self, forKey: .readingProgression)

        // If this is an old schema book, keep the value nil and let reader start from beginning.
        if readingProgression == nil {
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            if legacy.contains(.readingProgress) {
                readingProgression = 0
            }
        }
    }
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
