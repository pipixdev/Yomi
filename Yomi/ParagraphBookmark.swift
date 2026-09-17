import Foundation

struct ParagraphBookmark: Identifiable, Codable, Hashable {
    let id: UUID
    let bookID: UUID
    let text: String
    let locatorJSON: String
    let createdAt: Date
}
