//
//  JapaneseTextAnalyzer.swift
//  Yomi
//

import Foundation
import Dictionary
import IPADic
import Mecab_Swift

struct JapaneseTextAnalyzer {
    private struct RawToken {
        let surface: String
        let reading: String?
        let dictionaryForm: String?
        let partOfSpeech: ReaderPartOfSpeech
        let rawPartOfSpeech: String
    }

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

        let rawTokens: [RawToken] = tokenizer.tokenize(text: trimmed, transliteration: .hiragana).compactMap { token in
            let surface = token.base.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !surface.isEmpty else { return nil }

            let reading = normalizedReading(token.reading, fallback: surface)
            let dictionaryForm = normalizedDictionaryForm(token.dictionaryForm, fallback: surface)
            let rawPartOfSpeech = token.partOfSpeech.description.lowercased()
            let partOfSpeech = partOfSpeech(for: rawPartOfSpeech)
            return RawToken(
                surface: surface,
                reading: reading,
                dictionaryForm: dictionaryForm,
                partOfSpeech: partOfSpeech,
                rawPartOfSpeech: rawPartOfSpeech
            )
        }

        return mergeDisplayPhrases(in: rawTokens).enumerated().map { index, token in
            ReaderToken(
                id: index,
                surface: token.surface,
                reading: token.reading,
                partOfSpeech: token.partOfSpeech,
                dictionaryForm: token.dictionaryForm,
                verbGroup: verbGroup(
                    for: token.partOfSpeech,
                    surface: token.surface,
                    reading: token.reading,
                    dictionaryForm: token.dictionaryForm
                )
            )
        }
    }

    nonisolated private func mergeDisplayPhrases(in tokens: [RawToken]) -> [RawToken] {
        guard !tokens.isEmpty else { return [] }

        var merged: [RawToken] = []
        merged.reserveCapacity(tokens.count)

        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            guard shouldStartMergedPhrase(with: token) else {
                merged.append(token)
                index += 1
                continue
            }

            var phraseTokens = [token]
            var lookahead = index + 1

            while lookahead < tokens.count, shouldMerge(tokens[lookahead], intoPhrase: phraseTokens) {
                phraseTokens.append(tokens[lookahead])
                lookahead += 1
            }

            merged.append(mergePhraseComponents(phraseTokens))
            index = lookahead
        }

        return merged
    }

    nonisolated private func shouldStartMergedPhrase(with token: RawToken) -> Bool {
        token.partOfSpeech == .verb || token.partOfSpeech == .adjective
    }

    nonisolated private func shouldMerge(_ next: RawToken, intoPhrase phraseTokens: [RawToken]) -> Bool {
        guard let first = phraseTokens.first, let previous = phraseTokens.last else {
            return false
        }

        switch first.partOfSpeech {
        case .verb:
            return shouldMergeVerb(next, previous: previous)
        case .adjective:
            return shouldMergeAdjective(next, previous: previous)
        default:
            return false
        }
    }

    nonisolated private func shouldMergeVerb(_ next: RawToken, previous: RawToken) -> Bool {
        if isVerbConnectorParticle(next) {
            return true
        }

        if isAuxiliaryLike(next) || isSuffixLike(next) || isLikelyInflectionPiece(next) {
            return true
        }

        if next.partOfSpeech == .adjective {
            return isVerbConnectorParticle(previous) || isLikelyNegativeAuxiliary(next)
        }

        if next.partOfSpeech == .verb {
            return isVerbConnectorParticle(previous)
                || isAuxiliaryLike(previous)
                || isSuffixLike(previous)
        }

        return false
    }

    nonisolated private func shouldMergeAdjective(_ next: RawToken, previous: RawToken) -> Bool {
        if isAuxiliaryLike(next) || isSuffixLike(next) || isLikelyAdjectiveInflectionPiece(next) {
            return true
        }

        if next.partOfSpeech == .adjective {
            return isLikelyNegativeAuxiliary(next)
        }

        if next.partOfSpeech == .verb {
            return isAuxiliaryLike(previous) || isSuffixLike(previous)
        }

        return false
    }

    nonisolated private func mergePhraseComponents(_ tokens: [RawToken]) -> RawToken {
        guard let first = tokens.first else {
            preconditionFailure("Phrase merging requires at least one token.")
        }

        guard tokens.count > 1 else {
            return first
        }

        let mergedSurface = tokens.map(\.surface).joined()
        let mergedReading = normalizedReading(
            tokens.map { resolvedReading(for: $0) }.joined(),
            fallback: mergedSurface
        )

        return RawToken(
            surface: mergedSurface,
            reading: mergedReading,
            dictionaryForm: first.dictionaryForm,
            partOfSpeech: first.partOfSpeech,
            rawPartOfSpeech: first.rawPartOfSpeech
        )
    }

    nonisolated private func normalizedReading(_ reading: String?, fallback: String) -> String? {
        guard let reading, !reading.isEmpty else { return nil }
        return reading == fallback ? nil : reading
    }

    nonisolated private func resolvedReading(for token: RawToken) -> String {
        token.reading ?? token.surface
    }

    nonisolated private func isAuxiliaryLike(_ token: RawToken) -> Bool {
        token.rawPartOfSpeech.contains("auxiliary")
    }

    nonisolated private func isSuffixLike(_ token: RawToken) -> Bool {
        token.rawPartOfSpeech.contains("suffix")
    }

    nonisolated private func isVerbConnectorParticle(_ token: RawToken) -> Bool {
        token.partOfSpeech == .particle && ["て", "で", "ちゃ", "じゃ"].contains(token.surface)
    }

    nonisolated private func isLikelyInflectionPiece(_ token: RawToken) -> Bool {
        [
            "ます", "まし", "ませ", "ません", "ましょう",
            "た", "だ", "ない", "なかっ", "なく", "なけれ",
            "れる", "られる", "せる", "させる",
            "たい", "たく", "たかっ", "そう", "すぎる",
            "ぬ", "ず", "う", "よう"
        ].contains(token.surface)
    }

    nonisolated private func isLikelyNegativeAuxiliary(_ token: RawToken) -> Bool {
        ["ない", "なかっ", "なく", "なけれ", "ず", "ぬ"].contains(token.surface)
    }

    nonisolated private func isLikelyAdjectiveInflectionPiece(_ token: RawToken) -> Bool {
        [
            "た", "だ", "ない", "なかっ", "なく", "なけれ",
            "そう", "すぎる", "さ"
        ].contains(token.surface)
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
