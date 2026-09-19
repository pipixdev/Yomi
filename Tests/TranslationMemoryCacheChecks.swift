import Foundation

@main struct TranslationMemoryCacheChecks {
    static func main() {
        var cache = TranslationMemoryCache(maximumEntries: 2, maximumBytes: 12)
        cache.insert(["漢字"], for: "a")
        cache.insert(["😀"], for: "b")
        precondition(cache.byteCount == 10)
        precondition(cache.value(for: "a") == ["漢字"])
        cache.insert(["12345"], for: "c")
        precondition(cache.value(for: "b") == nil, "Evict least recently read entry")
        precondition(cache.byteCount == 11)
        cache.insert(["abc"], for: "a")
        precondition(cache.byteCount == 8, "Replacement must remove old byte count")
        cache.insert([String(repeating: "x", count: 13)], for: "a")
        precondition(cache.value(for: "a") == nil, "Oversized entry must not remain cached")
        precondition(cache.value(for: "c") == ["12345"])
        for index in 0..<10_000 {
            cache.insert(["😀"], for: String(index))
            precondition(cache.byteCount <= 12)
        }
        precondition(cache.value(for: "9997") == nil)
        precondition(cache.value(for: "9998") != nil)
        var disabled = TranslationMemoryCache(maximumEntries: 0)
        disabled.insert(["abc"], for: "a")
        precondition(disabled.value(for: "a") == nil)
        print("PASS: translation cache LRU, UTF-8 byte budget, replacement, oversized entries, 10,000 insertions.")
    }
}
