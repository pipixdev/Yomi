import Foundation

/// Disk remains authoritative; continuous reading must not retain an entire book's translations.
nonisolated struct TranslationMemoryCache {
    private struct Entry {
        let lines: [String]
        let byteCount: Int
    }
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private(set) var byteCount = 0
    private let maximumEntries: Int
    private let maximumBytes: Int

    init(maximumEntries: Int = 128, maximumBytes: Int = 1_048_576) {
        self.maximumEntries = max(0, maximumEntries)
        self.maximumBytes = max(0, maximumBytes)
    }

    mutating func value(for key: String) -> [String]? {
        guard let entry = entries[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return entry.lines
    }

    mutating func insert(_ lines: [String], for key: String) {
        remove(key)
        let size = lines.reduce(0) { $0 + $1.utf8.count }
        guard maximumEntries > 0, size <= maximumBytes else { return }
        while order.count >= maximumEntries || byteCount + size > maximumBytes {
            guard let oldest = order.first else { break }
            remove(oldest)
        }
        entries[key] = Entry(lines: lines, byteCount: size)
        order.append(key)
        byteCount += size
    }

    private mutating func remove(_ key: String) {
        if let entry = entries.removeValue(forKey: key) { byteCount -= entry.byteCount }
        order.removeAll { $0 == key }
    }
}
