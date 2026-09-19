import Foundation

/// Called on the tokenization actor, including ruby alignment and HTML escaping.
nonisolated enum AnalysisTokenMarkup {
    static func render(_ tokens: [ReaderToken]) -> String {
        var utf16Offset = 0
        return tokens.enumerated().map { index, token in
            let segments = token.displaySegments
            let hasRuby = segments.contains { !($0.reading ?? "").isEmpty }
            let rubyHTML = segments.map(\.html).joined()
            let tokenClasses = "token \(hasRuby ? "has-ruby" : "plain-token")"
            let lineClass = token.isInteractive ? "token-line" : "token-line token-line-static"
            let startOffset = utf16Offset
            utf16Offset += token.surface.utf16.count
            let endOffset = utf16Offset

            if token.isInteractive {
                let label = "\(token.surface) \(token.reading ?? "")".trimmingCharacters(in: .whitespaces)
                return """
                <button class="\(tokenClasses)" type="button" data-index="\(index)" data-start="\(startOffset)" data-end="\(endOffset)" aria-label="\(label.htmlEscaped)">
                  <span class="\(lineClass)" style="--token-color: \(token.partOfSpeech.cssColor);">\(rubyHTML)</span>
                </button>
                """
            }

            return """
            <span class="\(tokenClasses)" data-start="\(startOffset)" data-end="\(endOffset)" aria-hidden="true">
              <span class="\(lineClass)" style="--token-color: \(token.partOfSpeech.cssColor);">\(rubyHTML)</span>
            </span>
            """
        }.joined(separator: "\n")

    }
}

private struct TokenDisplaySegment: Hashable {
    let surface: String
    let reading: String?

    nonisolated var html: String {
        if let reading, !reading.isEmpty {
            return #"<ruby><rb>"#
                + surface.htmlEscaped
                + #"</rb><rt>"#
                + reading.htmlEscaped
                + "</rt></ruby>"
        }

        return surface.htmlEscaped
    }
}

private extension ReaderToken {
    nonisolated var isInteractive: Bool {
        partOfSpeech != .symbol
    }

    nonisolated var displaySegments: [TokenDisplaySegment] {
        guard
            let reading,
            !reading.isEmpty,
            surface.containsKanji
        else {
            return [TokenDisplaySegment(surface: surface, reading: nil)]
        }

        if surface.allSatisfy(\.isKanjiLike) {
            return [TokenDisplaySegment(surface: surface, reading: reading)]
        }

        guard let segments = ParagraphRubyAlignment.align(surface: Array(surface), reading: Array(reading)) else {
            return [TokenDisplaySegment(surface: surface, reading: nil)]
        }

        return segments.map { TokenDisplaySegment(surface: $0.surface, reading: $0.reading) }
    }

}

private enum ParagraphRubyAlignment {
    nonisolated static func align(surface: [Character], reading: [Character]) -> [TokenDisplaySegment]? {
        guard !surface.isEmpty else {
            return reading.isEmpty ? [] : nil
        }

        if surface.allSatisfy(\.isKanjiLike) {
            guard !reading.isEmpty else { return nil }
            return [TokenDisplaySegment(surface: String(surface), reading: String(reading))]
        }

        let first = surface[0]
        if first.isKanaLike {
            guard !reading.isEmpty, first.matchesKana(reading[0]) else {
                return nil
            }

            guard let suffix = align(surface: Array(surface.dropFirst()), reading: Array(reading.dropFirst())) else {
                return nil
            }
            return [TokenDisplaySegment(surface: String(first), reading: nil)] + suffix
        }

        var anchorStart: Int?
        for index in surface.indices where surface[index].isKanaLike {
            anchorStart = index
            break
        }

        guard let anchorStart else {
            guard !reading.isEmpty else { return nil }
            return [TokenDisplaySegment(surface: String(surface), reading: String(reading))]
        }

        var anchorEnd = anchorStart
        while anchorEnd < surface.count, surface[anchorEnd].isKanaLike {
            anchorEnd += 1
        }

        let kanjiPrefix = String(surface[..<anchorStart])
        let anchor = Array(surface[anchorStart..<anchorEnd])
        let suffixSurface = Array(surface[anchorEnd...])

        for matchStart in reading.indices where matchStart + anchor.count <= reading.count {
            let readingAnchor = Array(reading[matchStart..<(matchStart + anchor.count)])
            guard kanaSlicesMatch(anchor, readingAnchor) else {
                continue
            }

            let rubyReading = String(reading[..<matchStart])
            guard !rubyReading.isEmpty else {
                continue
            }

            guard let suffix = align(surface: suffixSurface, reading: Array(reading[(matchStart + anchor.count)...])) else {
                continue
            }

            return [TokenDisplaySegment(surface: kanjiPrefix, reading: rubyReading), TokenDisplaySegment(surface: String(anchor), reading: nil)] + suffix
        }

        return nil
    }

    nonisolated private static func kanaSlicesMatch(_ lhs: [Character], _ rhs: [Character]) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }

        return zip(lhs, rhs).allSatisfy { $0.matchesKana($1) }
    }
}

private extension ReaderPartOfSpeech {
    nonisolated var cssColor: String {
        switch self {
        case .noun:
            return "#f2c94c"
        case .verb:
            return "#4caf50"
        case .particle:
            return "#56ccf2"
        case .adjective:
            return "#ff6b9a"
        case .adverb:
            return "#9b51e0"
        case .prefix:
            return "#f2994a"
        case .symbol:
            return "#8e8e93"
        case .other:
            return "#2f80ed"
        }
    }
}

private extension String {
    nonisolated var containsKanji: Bool {
        unicodeScalars.contains(where: \.isKanji)
    }

    nonisolated var htmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

private extension Character {
    nonisolated var isKanaLike: Bool {
        unicodeScalars.allSatisfy { $0.isHiragana || $0.isKatakana }
    }

    nonisolated var isKanjiLike: Bool {
        unicodeScalars.contains(where: \.isKanji)
    }

    nonisolated func matchesKana(_ other: Character) -> Bool {
        normalizedKana == other.normalizedKana
    }

    nonisolated private var normalizedKana: String {
        String(String(self).applyingTransform(.hiraganaToKatakana, reverse: true) ?? String(self))
    }
}

private extension UnicodeScalar {
    nonisolated var isKanji: Bool {
        (0x3400...0x4DBF).contains(value)
            || (0x4E00...0x9FFF).contains(value)
            || (0xF900...0xFAFF).contains(value)
    }

    nonisolated var isHiragana: Bool {
        (0x3040...0x309F).contains(value)
    }

    nonisolated var isKatakana: Bool {
        (0x30A0...0x30FF).contains(value)
            || (0x31F0...0x31FF).contains(value)
            || (0xFF66...0xFF9F).contains(value)
    }
}
