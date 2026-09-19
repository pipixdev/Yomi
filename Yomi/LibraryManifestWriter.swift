import Foundation

/// The sole writer of library.json, including synchronous library mutations and
/// asynchronous reading checkpoints. Snapshot encoding and disk I/O run on this queue.
nonisolated final class LibraryManifestWriter: Sendable {
    private let queue = DispatchQueue(label: "com.pipix.Yomi.library-persistence", qos: .utility)

    func enqueue(_ books: [BookRecord], to url: URL, completion: @escaping @Sendable (Error?) -> Void) {
        queue.async {
            do {
                try Self.write(books, to: url)
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    func writeSynchronously(_ books: [BookRecord], to url: URL) throws {
        try queue.sync { try Self.write(books, to: url) }
    }

    private static func write(_ books: [BookRecord], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(books).write(to: url, options: .atomic)
    }
}
