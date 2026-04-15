//
//  JapaneseTextAnalyzer.swift
//  Yomi
//

import Foundation
import Dictionary
import IPADic
import Mecab_Swift

struct JapaneseTextAnalyzer {
    nonisolated(unsafe) private let tokenizer: Tokenizer

    nonisolated init() {
        do {
            tokenizer = try Tokenizer(dictionary: IPADic())
        } catch {
            fatalError("Failed to initialize MeCab tokenizer: \(error)")
        }
    }

    nonisolated func tokens(for text: String) -> [ReaderToken] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        return tokenizer.tokenize(text: trimmed, transliteration: .hiragana).enumerated().compactMap { index, token in
            let surface = token.base.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !surface.isEmpty else { return nil }

            let reading = normalizedReading(token.reading, fallback: surface)
            let dictionaryForm = normalizedDictionaryForm(token.dictionaryForm, fallback: surface)
            let partOfSpeech = partOfSpeech(for: token.partOfSpeech.description)
            return ReaderToken(
                id: index,
                surface: surface,
                reading: reading,
                partOfSpeech: partOfSpeech,
                dictionaryForm: dictionaryForm,
                verbGroup: verbGroup(for: partOfSpeech, surface: surface, reading: reading, dictionaryForm: dictionaryForm)
            )
        }
    }

    nonisolated private func normalizedReading(_ reading: String?, fallback: String) -> String? {
        guard let reading, !reading.isEmpty else { return nil }
        return reading == fallback ? nil : reading
    }

    nonisolated private func normalizedDictionaryForm(_ dictionaryForm: String?, fallback: String) -> String? {
        guard let dictionaryForm, !dictionaryForm.isEmpty else { return nil }
        return dictionaryForm == fallback ? nil : dictionaryForm
    }

    nonisolated private func partOfSpeech(for description: String) -> ReaderPartOfSpeech {
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

    nonisolated private func verbGroup(
        for partOfSpeech: ReaderPartOfSpeech,
        surface: String,
        reading: String?,
        dictionaryForm: String?
    ) -> ReaderVerbGroup? {
        guard partOfSpeech == .verb else { return nil }

        let base = dictionaryForm ?? reading ?? surface
        if base.hasSuffix("する") || base.hasSuffix("ずる") {
            return .sahen
        }

        if base == "くる" {
            return .kahen
        }

        if base.hasSuffix("る") {
            if isLikelyIchidan(base) {
                return .ichidan
            }
            return .godan
        }

        if let last = base.last, "うくぐすつぬぶむ".contains(last) {
            return .godan
        }

        return .irregular
    }

    nonisolated private func isLikelyIchidan(_ base: String) -> Bool {
        let exceptions: Set<String> = [
            "はいる", "かえる", "しる", "はしる", "まじる", "にぎる",
            "すべる", "しゃべる", "ひねる", "よる", "かぎる", "まいる"
        ]

        if exceptions.contains(base) {
            return false
        }

        guard let penultimate = base.dropLast().last else {
            return false
        }

        return "いきぎしじちぢにひびぴみりえけげせぜてでねへべぺめれ".contains(penultimate)
    }
}
