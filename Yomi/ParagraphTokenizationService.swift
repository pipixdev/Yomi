import Foundation

/// MeCab is not thread-safe. Each service owns its tokenizer and accesses it only on this actor.
actor ParagraphTokenizationService {
    private var analyzer: JapaneseTextAnalyzer?
    private var cache: [String: [ReaderToken]] = [:]
    private var order: [String] = []
    private var cachedTokenCount = 0

    func tokens(for text: String) -> [ReaderToken] {
        guard !Task.isCancelled else { return [] }
        if let cached = cache[text] {
            order.removeAll { $0 == text }
            order.append(text)
            return cached
        }
        if analyzer == nil { analyzer = JapaneseTextAnalyzer() }
        let result = analyzer!.tokens(for: text)
        guard !Task.isCancelled else { return [] }
        // Do not retain exceptionally large paragraphs after they leave the screen.
        if result.count <= 12_000, text.utf8.count <= 256_000 {
            cache[text] = result
            order.append(text)
            cachedTokenCount += result.count
            while order.count > 16 || cachedTokenCount > 12_000 {
                let key = order.removeFirst()
                cachedTokenCount -= cache.removeValue(forKey: key)?.count ?? 0
            }
        }
        return result
    }
}
