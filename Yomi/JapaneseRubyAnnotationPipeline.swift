//
//  JapaneseRubyAnnotationPipeline.swift
//  Yomi
//

import CryptoKit
import Foundation

#if canImport(ReadiumShared)
import ReadiumShared

actor JapaneseRubyAnnotationPipeline {
    private let analyzer = JapaneseTextAnalyzer()
    private var cachedHTML: [String: String] = [:]
    private var cacheOrder: [String] = []

    private let maxCachedDocuments = 6
    private let maxHTMLLength = 260_000
    private let maxTextNodeLength = 12_000

    func annotate(html: String, bookID: UUID, href: AnyURL) -> String {
        guard html.count <= maxHTMLLength, html.containsJapaneseText else {
            return html
        }

        let cacheKey = makeCacheKey(bookID: bookID, href: href, html: html)
        if let cached = cachedHTML[cacheKey] {
            touch(cacheKey)
            return cached
        }

        let transformed = JapaneseRubyHTMLAnnotator(
            analyzer: analyzer,
            maxTextNodeLength: maxTextNodeLength
        ).annotate(html)

        cachedHTML[cacheKey] = transformed
        cacheOrder.removeAll { $0 == cacheKey }
        cacheOrder.append(cacheKey)
        trimCacheIfNeeded()
        return transformed
    }

    private func makeCacheKey(bookID: UUID, href: AnyURL, html: String) -> String {
        let digest = SHA256.hash(data: Data(html.utf8))
        let fingerprint = digest.map { String(format: "%02x", $0) }.joined()
        return "\(bookID.uuidString)::\(href.string)::\(fingerprint)"
    }

    private func touch(_ key: String) {
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
    }

    private func trimCacheIfNeeded() {
        while cacheOrder.count > maxCachedDocuments {
            let oldestKey = cacheOrder.removeFirst()
            cachedHTML.removeValue(forKey: oldestKey)
        }
    }
}

final class JapaneseRubyAnnotatedContainer: Container {
    let sourceURL: AbsoluteURL? = nil

    private let container: Container
    private let pipeline: JapaneseRubyAnnotationPipeline
    private let bookID: UUID
    private let htmlHREFs: Set<AnyURL>
    private let lock = NSLock()
    private var wrappedResources: [AnyURL: Resource] = [:]

    init(
        bookID: UUID,
        container: Container,
        htmlHREFs: Set<AnyURL>,
        pipeline: JapaneseRubyAnnotationPipeline
    ) {
        self.bookID = bookID
        self.container = container
        self.htmlHREFs = htmlHREFs
        self.pipeline = pipeline
    }

    var entries: Set<AnyURL> {
        container.entries
    }

    subscript(url: any URLConvertible) -> Resource? {
        let href = normalized(url.anyURL)

        if let cached = lock.withLock({ wrappedResources[href] }) {
            return cached
        }

        guard let resource = container[url] else {
            return nil
        }

        let wrapped: Resource
        if shouldAnnotateResource(at: href) {
            wrapped = JapaneseRubyAnnotatedResource(
                bookID: bookID,
                href: href,
                resource: resource,
                pipeline: pipeline
            )
        } else {
            wrapped = resource
        }

        lock.withLock {
            wrappedResources[href] = wrapped
        }
        return wrapped
    }

    @available(*, deprecated, message: "The container is automatically closed when deallocated")
    func close() {
        container.close()
    }

    static func htmlHREFs(from manifest: Manifest) -> Set<AnyURL> {
        let candidates = manifest.readingOrder + manifest.resources + manifest.links + manifest.tableOfContents
        return Set(candidates.compactMap { link in
            guard link.mediaType?.isHTML == true || Self.looksLikeHTML(link.href) else {
                return nil
            }
            return AnyURL(string: link.href).map { Self.normalized($0) }
        })
    }

    private func shouldAnnotateResource(at href: AnyURL) -> Bool {
        htmlHREFs.contains(href) || Self.looksLikeHTML(href.string)
    }

    private static func normalized(_ href: AnyURL) -> AnyURL {
        href.removingQuery().removingFragment().normalized
    }

    private func normalized(_ href: AnyURL) -> AnyURL {
        Self.normalized(href)
    }

    private static func looksLikeHTML(_ href: String) -> Bool {
        let lowercased = href.lowercased()
        return lowercased.hasSuffix(".html") || lowercased.hasSuffix(".xhtml") || lowercased.hasSuffix(".htm")
    }
}

private final class JapaneseRubyAnnotatedResource: Resource {
    let sourceURL: AbsoluteURL? = nil

    private let bookID: UUID
    private let href: AnyURL
    private let resource: Resource
    private let pipeline: JapaneseRubyAnnotationPipeline

    private let lock = NSLock()
    private var transformedDataTask: Task<ReadResult<Data>, Never>?

    init(
        bookID: UUID,
        href: AnyURL,
        resource: Resource,
        pipeline: JapaneseRubyAnnotationPipeline
    ) {
        self.bookID = bookID
        self.href = href
        self.resource = resource
        self.pipeline = pipeline
    }

    func properties() async -> ReadResult<ResourceProperties> {
        await resource.properties()
    }

    func estimatedLength() async -> ReadResult<UInt64?> {
        .success(nil)
    }

    func stream(range: Range<UInt64>?, consume: @escaping (Data) -> Void) async -> ReadResult<Void> {
        await data().map { data in
            let length = UInt64(data.count)
            if let range = range?.clamped(to: 0 ..< length) {
                consume(data[range])
            } else {
                consume(data)
            }
            return ()
        }
    }

    private func data() async -> ReadResult<Data> {
        let task = lock.withLock { () -> Task<ReadResult<Data>, Never> in
            if let transformedDataTask {
                return transformedDataTask
            }

            let task = Task<ReadResult<Data>, Never> {
                let readResult = await resource.read()
                switch readResult {
                case let .success(data):
                    guard let html = String(data: data, encoding: .utf8) else {
                        return .success(data)
                    }

                    let transformedHTML = await pipeline.annotate(html: html, bookID: bookID, href: href)
                    return .success(transformedHTML.data(using: .utf8) ?? data)

                case let .failure(error):
                    return .failure(error)
                }
            }

            transformedDataTask = task
            return task
        }

        return await task.value
    }
}

private struct JapaneseRubyHTMLAnnotator {
    private let analyzer: JapaneseTextAnalyzer
    private let maxTextNodeLength: Int

    private let ignoredTags: Set<String> = [
        "code",
        "head",
        "math",
        "pre",
        "ruby",
        "script",
        "style",
        "svg",
        "textarea",
        "title",
    ]

    nonisolated init(analyzer: JapaneseTextAnalyzer, maxTextNodeLength: Int) {
        self.analyzer = analyzer
        self.maxTextNodeLength = maxTextNodeLength
    }

    nonisolated func annotate(_ html: String) -> String {
        var cursor = HTMLTokenCursor(html: html)
        var activeTags: [String] = []
        var output = String()
        output.reserveCapacity(html.utf8.count + (html.utf8.count / 8))

        while let token = cursor.next() {
            switch token {
            case let .markup(raw, event):
                output += raw
                updateActiveTags(with: event, activeTags: &activeTags)

            case let .text(text):
                if shouldSkipText(for: activeTags) {
                    output += text
                } else {
                    output += annotateTextNode(text)
                }
            }
        }

        return output
    }

    nonisolated private func shouldSkipText(for activeTags: [String]) -> Bool {
        activeTags.contains { ignoredTags.contains($0) }
    }

    nonisolated private func updateActiveTags(with event: HTMLMarkupEvent?, activeTags: inout [String]) {
        guard let event else { return }

        switch event {
        case let .opening(name):
            activeTags.append(name)

        case let .closing(name):
            if let index = activeTags.lastIndex(of: name) {
                activeTags.removeSubrange(index...)
            }

        case .other:
            break
        }
    }

    nonisolated private func annotateTextNode(_ text: String) -> String {
        guard text.count <= maxTextNodeLength, text.containsJapaneseText else {
            return text
        }

        var output = String()
        output.reserveCapacity(text.utf8.count + (text.utf8.count / 4))

        var index = text.startIndex
        while index < text.endIndex {
            if text[index].isWhitespace {
                let start = index
                while index < text.endIndex, text[index].isWhitespace {
                    index = text.index(after: index)
                }
                output += text[start..<index]
            } else {
                let start = index
                while index < text.endIndex, !text[index].isWhitespace {
                    index = text.index(after: index)
                }
                output += annotateSegment(String(text[start..<index]))
            }
        }

        return output
    }

    nonisolated private func annotateSegment(_ segment: String) -> String {
        guard segment.containsKanji else {
            return segment
        }

        let tokens = analyzer.tokens(for: segment)
        guard !tokens.isEmpty else {
            return segment
        }

        let reconstructed = tokens.map(\.surface).joined()
        guard reconstructed == segment else {
            return segment
        }

        var output = String()
        output.reserveCapacity(segment.utf8.count + (segment.utf8.count / 2))

        for token in tokens {
            output += annotatedHTML(for: token) ?? token.surface
        }

        return output
    }

    nonisolated private func annotatedHTML(for token: ReaderToken) -> String? {
        guard shouldAnnotate(token), let reading = token.reading else {
            return nil
        }

        if token.surface.allSatisfy(\.isKanjiLike) {
            return rubyHTML(base: token.surface, reading: reading)
        }

        guard let segments = alignRubySegments(surface: Array(token.surface), reading: Array(reading)) else {
            return nil
        }

        return segments.map { segment in
            if let reading = segment.reading {
                return rubyHTML(base: segment.surface, reading: reading)
            }
            return segment.surface
        }.joined()
    }

    nonisolated private func shouldAnnotate(_ token: ReaderToken) -> Bool {
        guard let reading = token.reading, !reading.isEmpty else {
            return false
        }

        return token.surface.containsKanji
    }

    nonisolated private func rubyHTML(base: String, reading: String) -> String {
        #"<ruby class="yomi-ruby"><rb>"#
            + escapeHTML(base)
            + #"</rb><rt class="yomi-rt">"#
            + escapeHTML(reading)
            + "</rt></ruby>"
    }

    nonisolated private func alignRubySegments(surface: [Character], reading: [Character]) -> [RubySegment]? {
        guard !surface.isEmpty else {
            return reading.isEmpty ? [] : nil
        }

        if surface.allSatisfy(\.isKanjiLike) {
            guard !reading.isEmpty else { return nil }
            return [RubySegment(surface: String(surface), reading: String(reading))]
        }

        let first = surface[0]
        if first.isKanaLike {
            guard !reading.isEmpty, first.matchesKana(reading[0]) else {
                return nil
            }

            guard let suffix = alignRubySegments(surface: Array(surface.dropFirst()), reading: Array(reading.dropFirst())) else {
                return nil
            }
            return [RubySegment(surface: String(first), reading: nil)] + suffix
        }

        var anchorStart: Int?
        for index in surface.indices {
            if surface[index].isKanaLike {
                anchorStart = index
                break
            }
        }

        guard let anchorStart else {
            guard !reading.isEmpty else { return nil }
            return [RubySegment(surface: String(surface), reading: String(reading))]
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

            guard let suffix = alignRubySegments(surface: suffixSurface, reading: Array(reading[(matchStart + anchor.count)...])) else {
                continue
            }

            return [RubySegment(surface: kanjiPrefix, reading: rubyReading), RubySegment(surface: String(anchor), reading: nil)] + suffix
        }

        return nil
    }

    nonisolated private func kanaSlicesMatch(_ lhs: [Character], _ rhs: [Character]) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }

        return zip(lhs, rhs).allSatisfy { $0.matchesKana($1) }
    }

    nonisolated private func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

private struct RubySegment {
    let surface: String
    let reading: String?
}

private struct HTMLTokenCursor {
    private let html: String
    private var index: String.Index

    nonisolated init(html: String) {
        self.html = html
        index = html.startIndex
    }

    nonisolated mutating func next() -> HTMLToken? {
        guard index < html.endIndex else {
            return nil
        }

        if html[index] == "<", let end = scanMarkupEnd(from: index) {
            let raw = String(html[index..<end])
            index = end
            return .markup(raw, HTMLMarkupEvent(raw: raw))
        } else if html[index] == "<" {
            let raw = String(html[index..<html.endIndex])
            index = html.endIndex
            return .text(raw)
        }

        let start = index
        while index < html.endIndex, html[index] != "<" {
            index = html.index(after: index)
        }
        return .text(String(html[start..<index]))
    }

    nonisolated private func scanMarkupEnd(from start: String.Index) -> String.Index? {
        if html[start...].hasPrefix("<!--"),
           let range = html.range(of: "-->", range: start..<html.endIndex) {
            return range.upperBound
        }

        var quote: Character?
        var cursor = html.index(after: start)

        while cursor < html.endIndex {
            let character = html[cursor]
            if let currentQuote = quote {
                if character == currentQuote {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return html.index(after: cursor)
            }

            cursor = html.index(after: cursor)
        }

        return nil
    }
}

private enum HTMLToken {
    case markup(String, HTMLMarkupEvent?)
    case text(String)
}

private enum HTMLMarkupEvent {
    case opening(String)
    case closing(String)
    case other

    nonisolated init?(raw: String) {
        guard raw.count >= 3 else {
            self = .other
            return
        }

        let innerRangeStart = raw.index(after: raw.startIndex)
        let innerRangeEnd = raw.index(before: raw.endIndex)
        let inner = raw[innerRangeStart..<innerRangeEnd].trimmingCharacters(in: .whitespacesAndNewlines)

        guard !inner.isEmpty else {
            self = .other
            return
        }

        if inner.hasPrefix("!") || inner.hasPrefix("?") {
            self = .other
            return
        }

        var isClosing = false
        var cursor = inner.startIndex

        if inner[cursor] == "/" {
            isClosing = true
            cursor = inner.index(after: cursor)
        }

        while cursor < inner.endIndex, inner[cursor].isWhitespace {
            cursor = inner.index(after: cursor)
        }

        let nameStart = cursor
        while cursor < inner.endIndex, inner[cursor].isHTMLTagNameCharacter {
            cursor = inner.index(after: cursor)
        }

        guard nameStart < cursor else {
            self = .other
            return
        }

        let name = inner[nameStart..<cursor].lowercased()
        if isClosing {
            self = .closing(name)
        } else if HTMLMarkupEvent.voidTags.contains(name) || inner.hasSuffix("/") {
            self = .other
        } else {
            self = .opening(name)
        }
    }

    nonisolated private static let voidTags: Set<String> = [
        "area",
        "base",
        "br",
        "col",
        "embed",
        "hr",
        "img",
        "input",
        "link",
        "meta",
        "param",
        "source",
        "track",
        "wbr",
    ]
}

private extension Character {
    nonisolated var isHTMLTagNameCharacter: Bool {
        isLetter || isNumber || self == "-" || self == "_" || self == ":" || self == "."
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

private extension String {
    nonisolated var containsJapaneseText: Bool {
        unicodeScalars.contains { $0.isKanji || $0.isHiragana || $0.isKatakana }
    }

    nonisolated var containsKanji: Bool {
        unicodeScalars.contains(where: \.isKanji)
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

    private nonisolated var normalizedKana: String {
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
#endif
