// Standalone Foundation regression checks; no simulator or app launch required.
// Compile with Models.swift and LibraryManifestWriter.swift (see reader-performance.md).
import Foundation

@main
struct ReaderPersistenceChecks {
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("library.json")
        let writer = LibraryManifestWriter()
        var book = BookRecord(id: UUID(), title: "日本語😀", author: "著者", importedAt: Date(timeIntervalSince1970: 1000), epubRelativePath: "Books/book.epub")
        let completed = DispatchGroup()
        for index in 0..<100 {
            book.lastReadLocatorJSON = "position-\(index)"
            book.readingProgression = Double(index) / 100
            completed.enter()
            writer.enqueue([book], to: url) { error in
                precondition(!Thread.isMainThread, "Persistence must not execute on the UI thread")
                precondition(error == nil)
                completed.leave()
            }
        }
        precondition(completed.wait(timeout: .now() + 10) == .success)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = try decoder.decode([BookRecord].self, from: Data(contentsOf: url))
        precondition(loaded == [book], "Latest reading position and Unicode metadata must round-trip")

        // A queued old snapshot must finish before deletion/rebuild writes the new state.
        for _ in 0..<50 { writer.enqueue([book], to: url) { precondition($0 == nil) } }
        try writer.writeSynchronously([], to: url)
        precondition(tryLoad(url, decoder).isEmpty, "A stale checkpoint resurrected a deleted book")
        book.lastReadLocatorJSON = "rebuilt"
        try writer.writeSynchronously([book], to: url)
        precondition(tryLoad(url, decoder).first?.lastReadLocatorJSON == "rebuilt")

        let failed = DispatchSemaphore(value: 0)
        writer.enqueue([book], to: folder.appendingPathComponent("missing/library.json")) { error in
            precondition(error != nil, "Write failures must be reported")
            failed.signal()
        }
        precondition(failed.wait(timeout: .now() + 10) == .success)
        precondition(tryLoad(url, decoder) == [book], "A failed write damaged the valid manifest")
        print("PASS: background encoding/writes, 150 ordered checkpoints, deletion/rebuild ordering, Unicode/date round-trip, failure reporting.")
    }

    static func tryLoad(_ url: URL, _ decoder: JSONDecoder) -> [BookRecord] {
        try! decoder.decode([BookRecord].self, from: Data(contentsOf: url))
    }
}
