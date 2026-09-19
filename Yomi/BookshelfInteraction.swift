import Foundation

enum BookAction {
    case translate, cancelTranslation, rebuild, remove
}

/// Only a native menu dismissal completion may leave the actions state.
struct BookshelfInteraction {
    enum Phase: Equatable {
        case browsing
        case actions(UUID)
        case reading(UUID)
    }

    private(set) var phase: Phase = .browsing
    private var pendingAction: BookAction?

    var readerID: UUID? {
        if case let .reading(id) = phase { return id }
        return nil
    }

    mutating func openBook(_ id: UUID) {
        guard phase == .browsing else { return }
        phase = .reading(id)
    }

    mutating func showActions(for id: UUID) {
        guard phase == .browsing else { return }
        phase = .actions(id)
    }

    mutating func selectAction(_ action: BookAction, for id: UUID) {
        guard phase == .actions(id), pendingAction == nil else { return }
        pendingAction = action
    }

    mutating func finishActions(for id: UUID) -> BookAction? {
        guard phase == .actions(id) else { return nil }
        let action = pendingAction
        pendingAction = nil
        phase = .browsing
        return action
    }

    mutating func closeReader(_ id: UUID) {
        guard readerID == id else { return }
        phase = .browsing
    }
}
