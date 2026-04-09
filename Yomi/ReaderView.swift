//
//  ReaderView.swift
//  Yomi
//

import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

#if canImport(ReadiumNavigator) && canImport(ReadiumShared) && canImport(ReadiumStreamer) && canImport(UIKit)
import ReadiumNavigator
import ReadiumShared
import ReadiumStreamer
#endif

struct ReaderView: View {
    let bookID: UUID

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: LibraryStore

    private var book: BookRecord? {
        store.book(id: bookID)
    }

    var body: some View {
        Group {
            if let book, let epubURL = store.epubURL(for: book) {
#if canImport(ReadiumNavigator) && canImport(ReadiumShared) && canImport(ReadiumStreamer) && canImport(UIKit)
                ReadiumReaderContainer(
                    bookID: book.id,
                    epubURL: epubURL,
                    initialLocatorJSON: book.lastReadLocatorJSON,
                    onLocationChange: { locator in
                        store.updateReadingProgress(for: book.id, locator: locator)
                    }
                )
                .ignoresSafeArea()
#else
                ContentUnavailableView(
                    "Reader unavailable",
                    systemImage: "book.closed",
                    description: Text("Readium integration is not available on this platform.")
                )
#endif
            } else {
                ContentUnavailableView(
                    "Book unavailable",
                    systemImage: "book.closed",
                    description: Text("This book may have been removed from your library.")
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(String(localized: "Close Reader")) {
                    dismiss()
                }
            }
        }
    }
}

#if canImport(ReadiumNavigator) && canImport(ReadiumShared) && canImport(ReadiumStreamer) && canImport(UIKit)
private struct ReadiumReaderContainer: UIViewControllerRepresentable {
    let bookID: UUID
    let epubURL: URL
    let initialLocatorJSON: String?
    let onLocationChange: (Locator) -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = ReadiumReaderViewController(
            bookID: bookID,
            epubURL: epubURL,
            initialLocatorJSON: initialLocatorJSON,
            onLocationChange: onLocationChange
        )
        return UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}
}

private final class ReadiumReaderViewController: UIViewController, EPUBNavigatorDelegate {
    private let bookID: UUID
    private let epubURL: URL
    private let initialLocatorJSON: String?
    private let onLocationChange: (Locator) -> Void

    private let spinner = UIActivityIndicatorView(style: .large)
    private let readium = ReadiumRuntime()

    private var publication: Publication?
    private var navigator: EPUBNavigatorViewController?

    init(
        bookID: UUID,
        epubURL: URL,
        initialLocatorJSON: String?,
        onLocationChange: @escaping (Locator) -> Void
    ) {
        self.bookID = bookID
        self.epubURL = epubURL
        self.initialLocatorJSON = initialLocatorJSON
        self.onLocationChange = onLocationChange
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never
        setupSpinner()

        Task {
            await loadReader()
        }
    }

    deinit {
        publication?.close()
    }

    private func setupSpinner() {
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    private func loadReader() async {
        do {
            guard let absoluteURL = epubURL.anyURL.absoluteURL else {
                throw CocoaError(.fileReadUnknown)
            }

            let asset = try await readium.assetRetriever.retrieve(url: absoluteURL).get()
            let rubyPipeline = readium.rubyPipeline
            let publication = try await readium.publicationOpener.open(
                asset: asset,
                allowUserInteraction: true,
                onCreatePublication: { [bookID] manifest, container, _ in
                    container = JapaneseRubyAnnotatedContainer(
                        bookID: bookID,
                        container: container,
                        htmlHREFs: JapaneseRubyAnnotatedContainer.htmlHREFs(from: manifest),
                        pipeline: rubyPipeline
                    )
                },
                sender: self
            ).get()

            guard publication.conforms(to: .epub) else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }

            let initialLocator: Locator?
            if let initialLocatorJSON {
                initialLocator = try? Locator(jsonString: initialLocatorJSON)
            } else {
                initialLocator = nil
            }

            let preferences = EPUBPreferences(
                columnCount: .one,
                publisherStyles: false,
                readingProgression: .ltr,
                scroll: false,
                verticalText: false
            )

            let navigator = try EPUBNavigatorViewController(
                publication: publication,
                initialLocation: initialLocator,
                config: EPUBNavigatorViewController.Configuration(
                    preferences: preferences,
                    preloadPreviousPositionCount: 0,
                    preloadNextPositionCount: 2
                )
            )
            navigator.delegate = self

            self.publication = publication
            self.navigator = navigator

            embed(navigator)
            spinner.stopAnimating()
            spinner.removeFromSuperview()
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func embed(_ child: UIViewController) {
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child.view)

        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: view.topAnchor),
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        child.didMove(toParent: self)
    }

    private func showError(_ message: String) {
        spinner.stopAnimating()
        spinner.removeFromSuperview()

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.text = message
        view.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
        ])
    }

    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        onLocationChange(locator)
    }

    func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
        showError(error.localizedDescription)
    }
}

private final class ReadiumRuntime {
    let httpClient = DefaultHTTPClient()
    let rubyPipeline = JapaneseRubyAnnotationPipeline()
    lazy var assetRetriever = AssetRetriever(httpClient: httpClient)
    lazy var publicationOpener = PublicationOpener(
        parser: DefaultPublicationParser(
            httpClient: httpClient,
            assetRetriever: assetRetriever,
            pdfFactory: DefaultPDFDocumentFactory()
        )
    )
}
#endif
