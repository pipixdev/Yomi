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
    var chapters: [BookChapter]
    var epubRelativePath: String
    var coverRelativePath: String?
}

struct BookChapter: Identifiable, Codable, Hashable {
    let id: String
    var title: String
    var paragraphs: [String]
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
