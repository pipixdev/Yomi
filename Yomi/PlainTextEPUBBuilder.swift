//
//  PlainTextEPUBBuilder.swift
//  Yomi
//

import Foundation

struct PlainTextEPUBBuilder {
    func build(
        title: String,
        author: String,
        text: String,
        bookID: UUID,
        destinationURL: URL
    ) throws {
        let paragraphs = Self.paragraphs(from: text)
        guard !paragraphs.isEmpty else {
            throw PlainTextEPUBError.noContent
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines)
        let modified = ISO8601DateFormatter().string(from: .now)
        let escapedTitle = Self.escapeXML(trimmedTitle)
        let escapedAuthor = Self.escapeXML(trimmedAuthor)
        let creatorMetadata = trimmedAuthor.isEmpty
            ? ""
            : "\n    <dc:creator>\(escapedAuthor)</dc:creator>"
        let body = paragraphs
            .map { "    <p>\(Self.escapeXML($0))</p>" }
            .joined(separator: "\n")

        let container = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """

        let package = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package version="3.0" unique-identifier="book-id" xmlns="http://www.idpf.org/2007/opf">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="book-id">urn:uuid:\(bookID.uuidString)</dc:identifier>
            <dc:title>\(escapedTitle)</dc:title>\(creatorMetadata)
            <dc:language>und</dc:language>
            <meta property="dcterms:modified">\(modified)</meta>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="content" href="content.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="content"/>
          </spine>
        </package>
        """

        let navigation = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="und">
          <head><title>\(escapedTitle)</title></head>
          <body>
            <nav epub:type="toc" xmlns:epub="http://www.idpf.org/2007/ops">
              <h1>\(escapedTitle)</h1>
              <ol><li><a href="content.xhtml">\(escapedTitle)</a></li></ol>
            </nav>
          </body>
        </html>
        """

        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="und">
          <head>
            <meta charset="utf-8"/>
            <title>\(escapedTitle)</title>
          </head>
          <body>
        \(body)
          </body>
        </html>
        """

        let entries = [
            EPUBArchiveEntry(path: "mimetype", contents: Data("application/epub+zip".utf8)),
            EPUBArchiveEntry(path: "META-INF/container.xml", contents: Data(container.utf8)),
            EPUBArchiveEntry(path: "OEBPS/content.opf", contents: Data(package.utf8)),
            EPUBArchiveEntry(path: "OEBPS/nav.xhtml", contents: Data(navigation.utf8)),
            EPUBArchiveEntry(path: "OEBPS/content.xhtml", contents: Data(content.utf8)),
        ]

        try StoredZIPArchive(entries: entries).write(to: destinationURL)
    }

    static func paragraphs(from text: String) -> [String] {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func escapeXML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

private enum PlainTextEPUBError: LocalizedError {
    case noContent

    var errorDescription: String? {
        String(localized: "This text does not contain any content.")
    }
}

private struct EPUBArchiveEntry {
    let path: String
    let contents: Data
}

/// EPUB requires a ZIP container whose first `mimetype` entry is stored without compression.
/// Plain text books are small enough that storing every entry keeps this writer dependency-free.
private struct StoredZIPArchive {
    let entries: [EPUBArchiveEntry]

    func write(to url: URL) throws {
        var archive = Data()
        var centralDirectory = Data()

        for entry in entries {
            let name = Data(entry.path.utf8)
            let checksum = Self.crc32(entry.contents)
            let size = UInt32(entry.contents.count)
            let localOffset = UInt32(archive.count)

            archive.appendLittleEndian(UInt32(0x04034b50))
            archive.appendLittleEndian(UInt16(20))
            archive.appendLittleEndian(UInt16(0x0800))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(checksum)
            archive.appendLittleEndian(size)
            archive.appendLittleEndian(size)
            archive.appendLittleEndian(UInt16(name.count))
            archive.appendLittleEndian(UInt16(0))
            archive.append(name)
            archive.append(entry.contents)

            centralDirectory.appendLittleEndian(UInt32(0x02014b50))
            centralDirectory.appendLittleEndian(UInt16(20))
            centralDirectory.appendLittleEndian(UInt16(20))
            centralDirectory.appendLittleEndian(UInt16(0x0800))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(checksum)
            centralDirectory.appendLittleEndian(size)
            centralDirectory.appendLittleEndian(size)
            centralDirectory.appendLittleEndian(UInt16(name.count))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(UInt32(0))
            centralDirectory.appendLittleEndian(localOffset)
            centralDirectory.append(name)
        }

        let centralOffset = UInt32(archive.count)
        archive.append(centralDirectory)
        archive.appendLittleEndian(UInt32(0x06054b50))
        archive.appendLittleEndian(UInt16(0))
        archive.appendLittleEndian(UInt16(0))
        archive.appendLittleEndian(UInt16(entries.count))
        archive.appendLittleEndian(UInt16(entries.count))
        archive.appendLittleEndian(UInt32(centralDirectory.count))
        archive.appendLittleEndian(centralOffset)
        archive.appendLittleEndian(UInt16(0))

        try archive.write(to: url, options: .atomic)
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var checksum = UInt32.max
        for byte in data {
            checksum ^= UInt32(byte)
            for _ in 0..<8 {
                let mask = UInt32(bitPattern: -Int32(checksum & 1))
                checksum = (checksum >> 1) ^ (0xedb88320 & mask)
            }
        }
        return checksum ^ UInt32.max
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) {
            append(contentsOf: $0)
        }
    }
}
