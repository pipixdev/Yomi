//
//  EPUBImportNormalizer.swift
//  Yomi
//

import Foundation

#if canImport(ReadiumShared) && canImport(ReadiumStreamer)
import ReadiumShared
import ReadiumStreamer

final class EPUBImportNormalizer {
    static let version = 2

    private let rubyPipeline = JapaneseRubyAnnotationPipeline()

    func normalize(
        container: Container,
        bookID: UUID,
        outputDirectory: URL,
        progress: @escaping (_ fraction: Double, _ label: String) -> Void
    ) async throws {
        let entries = container.entries.sorted { $0.string < $1.string }
        let totalEntries = max(entries.count, 1)

        for (index, href) in entries.enumerated() {
            let resourceProgress = Double(index) / Double(totalEntries)
            progress(
                0.35 + (resourceProgress * 0.55),
                String(localized: "Normalizing book content…")
            )

            guard let resource = container[href] else {
                continue
            }

            let destinationURL = outputDirectory.appendingPathComponent(href.string)
            let parentURL = destinationURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)

            let data = try await resource.read().get()
            let outputData: Data

            if Self.isHTMLResource(href.string), let html = String(data: data, encoding: .utf8) {
                let normalizedHTML = await normalizeHTML(html, bookID: bookID, href: href)
                outputData = normalizedHTML.data(using: .utf8) ?? data
            } else {
                outputData = data
            }

            try outputData.write(to: destinationURL, options: [.atomic])
        }

        progress(0.95, String(localized: "Finishing import…"))
    }

    private func normalizeHTML(_ html: String, bookID: UUID, href: AnyURL) async -> String {
        var normalized = html
        normalized = Self.removeHeadStyles(from: normalized)
        normalized = Self.removeInlineStyles(from: normalized)
        normalized = Self.promoteLeadingHeadingCandidate(in: normalized)
        normalized = Self.injectParagraphActionSlots(into: normalized)
        normalized = Self.injectNormalizedStyle(into: normalized)
        return await rubyPipeline.annotate(html: normalized, bookID: bookID, href: href)
    }

    private static func isHTMLResource(_ href: String) -> Bool {
        let lowercased = href.lowercased()
        return lowercased.hasSuffix(".html") || lowercased.hasSuffix(".xhtml") || lowercased.hasSuffix(".htm")
    }

    private static func removeHeadStyles(from html: String) -> String {
        var result = html
        result = replacing(
            pattern: #"(?is)<style\b[^>]*>.*?</style>"#,
            in: result,
            with: ""
        )
        result = replacing(
            pattern: #"(?is)<link\b(?=[^>]*\brel\s*=\s*["'][^"']*stylesheet[^"']*["'])[^>]*>"#,
            in: result,
            with: ""
        )
        return result
    }

    private static func removeInlineStyles(from html: String) -> String {
        replacing(
            pattern: #"\sstyle\s*=\s*("([^"]*)"|'([^']*)')"#,
            in: html,
            with: ""
        )
    }

    private static func promoteLeadingHeadingCandidate(in html: String) -> String {
        guard
            let bodyStart = html.range(of: "<body", options: .caseInsensitive),
            let bodyContentStart = html[bodyStart.upperBound...].firstIndex(of: ">"),
            let bodyEnd = html.range(of: "</body>", options: .caseInsensitive)?.lowerBound
        else {
            return html
        }

        let scanRange = bodyContentStart..<bodyEnd
        let scanText = String(html[scanRange])
        let regex = try? NSRegularExpression(pattern: #"(?is)<p\b([^>]*)>(.*?)</p>"#)
        guard let regex else {
            return html
        }

        let nsRange = NSRange(scanText.startIndex..<scanText.endIndex, in: scanText)
        let matches = regex.matches(in: scanText, options: [], range: nsRange)
        guard !matches.isEmpty else {
            return html
        }

        for match in matches {
            guard
                let fullRange = Range(match.range(at: 0), in: scanText),
                let attrsRange = Range(match.range(at: 1), in: scanText),
                let innerRange = Range(match.range(at: 2), in: scanText)
            else {
                continue
            }

            let innerHTML = String(scanText[innerRange])
            let plainText = plainText(from: innerHTML)
            if plainText.isEmpty {
                continue
            }

            if plainText.count > 60 {
                break
            }

            guard isHeadingCandidate(plainText) else {
                continue
            }

            let replacement = "<h1\(scanText[attrsRange])>\(innerHTML)</h1>"
            let fullHTMLStart = html.index(
                scanRange.lowerBound,
                offsetBy: scanText.distance(from: scanText.startIndex, to: fullRange.lowerBound)
            )
            let fullHTMLEnd = html.index(
                scanRange.lowerBound,
                offsetBy: scanText.distance(from: scanText.startIndex, to: fullRange.upperBound)
            )
            let fullHTMLRange = fullHTMLStart..<fullHTMLEnd

            var updatedHTML = html
            updatedHTML.replaceSubrange(fullHTMLRange, with: replacement)
            return updatedHTML
        }

        return html
    }

    private static func plainText(from html: String) -> String {
        let withoutTags = replacing(
            pattern: #"(?is)<[^>]+>"#,
            in: html,
            with: ""
        )
        return withoutTags
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "\u{3000}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isHeadingCandidate(_ text: String) -> Bool {
        guard text.count <= 40 else {
            return false
        }

        let punctuation = CharacterSet(charactersIn: "。！？!?")
        guard text.rangeOfCharacter(from: punctuation) == nil else {
            return false
        }

        return text.unicodeScalars.contains { scalar in
            scalar.properties.isIdeographic || scalar.properties.isAlphabetic || CharacterSet.decimalDigits.contains(scalar)
        }
    }

    private static func injectNormalizedStyle(into html: String) -> String {
        let styleTag = """
        <style id="yomi-normalized-style">
        html {
          writing-mode: horizontal-tb !important;
          text-orientation: mixed !important;
          overflow-x: hidden !important;
          max-width: 100% !important;
        }
        body {
          writing-mode: horizontal-tb !important;
          text-orientation: mixed !important;
          margin: 0 !important;
          padding: 0 !important;
          line-height: 1.75 !important;
          text-indent: 0 !important;
          overflow-x: hidden !important;
          max-width: 100% !important;
        }
        body * {
          box-sizing: border-box !important;
          max-width: 100% !important;
        }
        h1, h2, h3, h4, h5, h6 {
          display: block !important;
          position: static !important;
          inset: auto !important;
          transform: none !important;
          float: none !important;
          clear: both !important;
          margin: 1.2em 0 0.6em 0 !important;
          padding: 0 !important;
          text-indent: 0 !important;
          line-height: 1.35 !important;
          overflow-wrap: anywhere !important;
          word-break: break-word !important;
          white-space: normal !important;
        }
        p, div, li, blockquote, dd, dt, article, section, main, header, footer {
          position: static !important;
          inset: auto !important;
          transform: none !important;
          float: none !important;
          clear: none !important;
          margin-left: 0 !important;
          margin-right: 0 !important;
          padding-left: 0 !important;
          padding-right: 0 !important;
          text-indent: 0 !important;
          overflow-wrap: anywhere !important;
          word-break: break-word !important;
          white-space: normal !important;
        }
        p {
          margin-top: 0 !important;
          margin-bottom: 1em !important;
        }
        .yomi-paragraph-slot {
          display: flex !important;
          justify-content: flex-end !important;
          align-items: center !important;
          min-height: 1.35em !important;
          margin: -0.2em 0 1em 0 !important;
          padding: 0 !important;
          text-indent: 0 !important;
        }
        .yomi-paragraph-toolbar {
          display: flex !important;
          flex-wrap: nowrap !important;
          justify-content: flex-end !important;
          align-items: center !important;
          gap: 0.4em !important;
          width: 100% !important;
        }
        .yomi-paragraph-action {
          display: inline-flex !important;
          justify-content: center !important;
          align-items: center !important;
          width: 2em !important;
          height: 2em !important;
          border: 0 !important;
          border-radius: 999px !important;
          background: rgba(60, 60, 67, 0.12) !important;
          color: inherit !important;
          padding: 0 !important;
          margin: 0 !important;
          line-height: 1 !important;
          font: inherit !important;
          cursor: pointer !important;
        }
        .yomi-paragraph-action.is-feedback {
          background: rgba(52, 199, 89, 0.24) !important;
        }
        img, svg, video, canvas {
          display: block !important;
          max-width: 100% !important;
          height: auto !important;
          margin-left: auto !important;
          margin-right: auto !important;
        }
        table {
          display: block !important;
          overflow-x: auto !important;
          max-width: 100% !important;
        }
        ruby, rb, rt, rp {
          white-space: normal !important;
        }
        </style>
        """

        if let headRange = html.range(of: "</head>", options: .caseInsensitive) {
            var updatedHTML = html
            updatedHTML.insert(contentsOf: styleTag, at: headRange.lowerBound)
            return updatedHTML
        }

        return styleTag + html
    }

    private static func injectParagraphActionSlots(into html: String) -> String {
        guard
            let bodyStart = html.range(of: "<body", options: .caseInsensitive),
            let bodyContentStart = html[bodyStart.upperBound...].firstIndex(of: ">"),
            let bodyEnd = html.range(of: "</body>", options: .caseInsensitive)?.lowerBound
        else {
            return html
        }

        let scanRange = html.index(after: bodyContentStart)..<bodyEnd
        let scanText = String(html[scanRange])
        let regex = try? NSRegularExpression(pattern: #"(?is)<(p|h[1-6]|blockquote)\b([^>]*)>(.*?)</\1>"#)
        guard let regex else {
            return html
        }

        let matches = regex.matches(
            in: scanText,
            options: [],
            range: NSRange(scanText.startIndex..<scanText.endIndex, in: scanText)
        )

        guard !matches.isEmpty else {
            return html
        }

        var updatedHTML = html

        for match in matches.reversed() {
            guard
                let fullRange = Range(match.range(at: 0), in: scanText),
                let innerRange = Range(match.range(at: 3), in: scanText)
            else {
                continue
            }

            let originalBlockHTML = String(scanText[fullRange])
            if originalBlockHTML.contains("yomi-paragraph-slot") {
                continue
            }

            let innerHTML = String(scanText[innerRange])
            let cleanText = cleanParagraphText(from: innerHTML)
            guard !cleanText.isEmpty else {
                continue
            }

            let slotHTML = """
            <div class="yomi-paragraph-slot" data-yomi-paragraph-text="\(htmlAttributeEscaped(cleanText))"></div>
            """

            let fullHTMLEnd = updatedHTML.index(
                scanRange.lowerBound,
                offsetBy: scanText.distance(from: scanText.startIndex, to: fullRange.upperBound)
            )

            updatedHTML.insert(contentsOf: slotHTML, at: fullHTMLEnd)
        }

        return updatedHTML
    }

    private static func replacing(pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }

    private static func cleanParagraphText(from html: String) -> String {
        let withoutRubyNotes = replacing(
            pattern: #"(?is)<rt\b[^>]*>.*?</rt>|<rp\b[^>]*>.*?</rp>"#,
            in: html,
            with: ""
        )
        let withoutRubyWrappers = replacing(
            pattern: #"(?is)</?(ruby|rb)\b[^>]*>"#,
            in: withoutRubyNotes,
            with: ""
        )
        let collapsed = plainText(from: withoutRubyWrappers)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")

        return collapsed.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
    }

    private static func htmlAttributeEscaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
#endif
