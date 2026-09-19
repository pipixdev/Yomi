import SwiftUI

#if os(iOS)
import UIKit

/// System menu with dismissal completion exposed to the bookshelf's presentation state.
struct BookActionsMenu: UIViewRepresentable {
    let isTranslating: Bool
    let canTranslate: Bool
    let canPresent: Bool
    let onBegin: () -> Void
    let onSelect: (BookAction) -> Void
    let onEnd: () -> Void

    func makeUIView(context: Context) -> MenuButton {
        let button = MenuButton(type: .system)
        var configuration = UIButton.Configuration.gray()
        configuration.image = UIImage(systemName: "ellipsis")
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(weight: .bold)
        configuration.cornerStyle = .capsule
        configuration.baseForegroundColor = .label
        button.configuration = configuration
        button.showsMenuAsPrimaryAction = true
        button.preferredMenuElementOrder = .fixed
        // Setting a menu enables UIButton's native context-menu interaction.
        button.menu = UIMenu(children: [])
        return button
    }

    func updateUIView(_ button: MenuButton, context: Context) {
        button.accessibilityLabel = String(localized: "Book actions")
        button.canPresent = canPresent
        button.onBegin = onBegin
        button.onEnd = onEnd
        // Build only when requested, using the latest translation/import state.
        button.makeMenu = {
            UIMenu(children: [
                UIAction(
                    title: isTranslating ? String(localized: "Cancel translation") : String(localized: "Translate entire book"),
                    image: UIImage(systemName: isTranslating ? "stop.circle" : "character.bubble"),
                    attributes: isTranslating || canTranslate ? [] : .disabled
                ) { _ in onSelect(isTranslating ? .cancelTranslation : .translate) },
                UIAction(title: String(localized: "Rebuild"), image: UIImage(systemName: "arrow.triangle.2.circlepath")) { _ in onSelect(.rebuild) },
                UIAction(title: String(localized: "Remove"), image: UIImage(systemName: "trash"), attributes: .destructive) { _ in onSelect(.remove) }
            ])
        }
    }

    static func dismantleUIView(_ button: MenuButton, coordinator: ()) {
        button.contextMenuInteraction?.dismissMenu()
    }

    final class MenuButton: UIButton {
        var canPresent = true
        var makeMenu: (() -> UIMenu)?
        var onBegin: (() -> Void)?
        var onEnd: (() -> Void)?

        override func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
            guard canPresent else { return nil }
            menu = makeMenu?()
            return super.contextMenuInteraction(interaction, configurationForMenuAtLocation: location)
        }

        override func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willDisplayMenuFor configuration: UIContextMenuConfiguration, animator: (any UIContextMenuInteractionAnimating)?) {
            super.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: animator)
            onBegin?()
        }

        override func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willEndFor configuration: UIContextMenuConfiguration, animator: (any UIContextMenuInteractionAnimating)?) {
            super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
            // Keep the shelf in menu state throughout dismissal, including the tap
            // that cancels it. Never present a reader/dialog from willEnd itself.
            let completion = onEnd
            if let animator {
                animator.addCompletion { completion?() }
            } else {
                completion?()
            }
        }
    }
}
#else
struct BookActionsMenu: View {
    let isTranslating: Bool
    let canTranslate: Bool
    let canPresent: Bool
    let onBegin: () -> Void
    let onSelect: (BookAction) -> Void
    let onEnd: () -> Void

    var body: some View {
        Menu {
            if isTranslating {
                Button("Cancel translation", systemImage: "stop.circle") { perform(.cancelTranslation) }
            } else {
                Button("Translate entire book", systemImage: "character.bubble") { perform(.translate) }
                    .disabled(!canTranslate)
            }
            Button("Rebuild", systemImage: "arrow.triangle.2.circlepath") { perform(.rebuild) }
            Button("Remove", systemImage: "trash", role: .destructive) { perform(.remove) }
        } label: {
            Image(systemName: "ellipsis")
        }
        .disabled(!canPresent)
        .accessibilityLabel("Book actions")
    }

    private func perform(_ action: BookAction) {
        onBegin()
        onSelect(action)
        onEnd()
    }
}
#endif
