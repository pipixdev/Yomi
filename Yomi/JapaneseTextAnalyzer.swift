//
//  JapaneseTextAnalyzer.swift
//  Yomi
//

import Foundation
import Dictionary
import IPADic
import Mecab_Swift

struct JapaneseTextAnalyzer {
    private let tokenizer: Tokenizer

    init() {
        do {
            tokenizer = try Tokenizer(dictionary: IPADic())
        } catch {
            fatalError("Failed to initialize MeCab tokenizer: \(error)")
        }
    }

    func tokens(for text: String) -> [ReaderToken] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        return tokenizer.tokenize(text: trimmed, transliteration: .hiragana).enumerated().compactMap { index, token in
            let surface = token.base.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !surface.isEmpty else { return nil }

            let reading = normalizedReading(token.reading, fallback: surface)
            let dictionaryForm = normalizedDictionaryForm(token.dictionaryForm, fallback: surface)
            return ReaderToken(
                id: index,
                surface: surface,
                reading: reading,
                partOfSpeech: partOfSpeech(for: token.partOfSpeech.description),
                dictionaryForm: dictionaryForm
            )
        }
    }

    private func normalizedReading(_ reading: String?, fallback: String) -> String? {
        guard let reading, !reading.isEmpty else { return nil }
        return reading == fallback ? nil : reading
    }

    private func normalizedDictionaryForm(_ dictionaryForm: String?, fallback: String) -> String? {
        guard let dictionaryForm, !dictionaryForm.isEmpty else { return nil }
        return dictionaryForm == fallback ? nil : dictionaryForm
    }

    private func partOfSpeech(for description: String) -> ReaderPartOfSpeech {
        switch description.lowercased() {
        case "noun":
            return .noun
        case "verb":
            return .verb
        case "particle":
            return .particle
        case "adjective":
            return .adjective
        case "adverb":
            return .adverb
        case "prefix":
            return .prefix
        case "symbol":
            return .symbol
        default:
            return .other
        }
    }
}
