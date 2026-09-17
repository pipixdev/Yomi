import Foundation

struct BookTranslationProgress {
    enum Phase { case running, finished, failed }
    var completed = 0
    var total = 0
    var phase = Phase.running
}

/// Read exactly the metadata used by the reader, preserving its cache identity.
enum BookTranslationParagraphs {
    nonisolated static func load(from directory: URL) throws -> [String] {
        var enumerationError: Error?
        guard let files = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else { throw CocoaError(.fileReadNoSuchFile) }
        let urls = files.compactMap { $0 as? URL }.sorted { $0.path < $1.path }
        if let enumerationError { throw enumerationError }
        let pattern = try NSRegularExpression(pattern: #"data-yomi-paragraph-text="([^"]*)""#)
        var paragraphs: [String] = []
        for url in urls where ["html", "xhtml", "htm"].contains(url.pathExtension.lowercased()) {
            try Task.checkCancellation()
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let html = try String(contentsOf: url, encoding: .utf8)
            for match in pattern.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard let range = Range(match.range(at: 1), in: html) else { continue }
                // Reverse the normalizer's attribute escaping, decoding ampersands last.
                let paragraph = String(html[range])
                    .replacingOccurrences(of: "&quot;", with: "\"")
                    .replacingOccurrences(of: "&lt;", with: "<")
                    .replacingOccurrences(of: "&gt;", with: ">")
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !paragraph.isEmpty { paragraphs.append(paragraph) }
            }
        }
        return paragraphs
    }
}

enum BookTranslationPreferences {
    static let concurrencyKey = "translation.concurrency"
    static let defaultConcurrency = 60
    static let concurrencyRange = 1...120

    static func concurrency() -> Int {
        let stored = UserDefaults.standard.object(forKey: concurrencyKey) as? Int ?? defaultConcurrency
        return min(max(stored, concurrencyRange.lowerBound), concurrencyRange.upperBound)
    }
}
