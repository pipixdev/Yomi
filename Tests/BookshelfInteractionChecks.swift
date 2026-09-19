import Foundation

@main struct BookshelfInteractionChecks {
    static func main() {
        let a = UUID(), b = UUID()
        var shelf = BookshelfInteraction()
        shelf.showActions(for: a)
        // Both visible-menu taps and taps during native dismissal must be ignored.
        for _ in 0..<3 {
            shelf.openBook(a)
            shelf.openBook(b)
            precondition(shelf.phase == .actions(a) && shelf.readerID == nil)
        }
        precondition(shelf.finishActions(for: b) == nil)
        precondition(shelf.phase == .actions(a), "An unrelated menu callback cannot unlock")
        precondition(shelf.finishActions(for: a) == nil)
        precondition(shelf.phase == .browsing)
        shelf.openBook(b)
        precondition(shelf.readerID == b, "Next tap after dismissal must open")
        shelf.openBook(a)
        shelf.showActions(for: a)
        precondition(shelf.readerID == b)
        shelf.closeReader(a)
        precondition(shelf.readerID == b, "A stale close must not close another book")
        shelf.closeReader(b)
        shelf.openBook(a)
        precondition(shelf.readerID == a, "Immediate reopen must work")
        shelf.closeReader(a)

        for action in [BookAction.translate, .cancelTranslation, .rebuild, .remove] {
            shelf.showActions(for: a)
            shelf.selectAction(action, for: b)
            shelf.selectAction(action, for: a)
            shelf.selectAction(.remove, for: a)
            shelf.openBook(b)
            precondition(shelf.phase == .actions(a), "Action selection must await dismissal")
            precondition(shelf.finishActions(for: a) == action)
            precondition(shelf.phase == .browsing)
            precondition(shelf.finishActions(for: a) == nil, "Execute a selected action once")
        }
        shelf.selectAction(.remove, for: a)
        shelf.showActions(for: a)
        precondition(shelf.finishActions(for: a) == nil, "Ignore stale selection after dismissal")
        for _ in 0..<10_000 {
            shelf.showActions(for: a)
            shelf.openBook(a)
            precondition(shelf.readerID == nil)
            _ = shelf.finishActions(for: a)
            shelf.openBook(b)
            shelf.closeReader(b)
        }
        print("PASS: native menu visibility/dismissal gate, deferred actions exactly once, stale callbacks, immediate reopen, 10,000 cycles")
    }
}
