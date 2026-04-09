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
import WebKit
#endif

struct ReaderView: View {
    let bookID: UUID

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: LibraryStore
    @AppStorage("reader.fontScale") private var readerFontScale = 1.0
    @AppStorage("reader.pageMarginsScale") private var readerPageMarginsScale = 1.0

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
                    fontScale: readerFontScale,
                    pageMarginsScale: readerPageMarginsScale,
                    onClose: {
                        dismiss()
                    },
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
    }
}

#if canImport(ReadiumNavigator) && canImport(ReadiumShared) && canImport(ReadiumStreamer) && canImport(UIKit)
private struct ReadiumReaderContainer: UIViewControllerRepresentable {
    let bookID: UUID
    let epubURL: URL
    let initialLocatorJSON: String?
    let fontScale: Double
    let pageMarginsScale: Double
    let onClose: () -> Void
    let onLocationChange: (Locator) -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = ReadiumReaderViewController(
            bookID: bookID,
            epubURL: epubURL,
            initialLocatorJSON: initialLocatorJSON,
            initialFontScale: fontScale,
            initialPageMarginsScale: pageMarginsScale,
            onClose: onClose,
            onLocationChange: onLocationChange
        )
        return UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {
        guard let reader = uiViewController.viewControllers.first as? ReadiumReaderViewController else {
            return
        }
        reader.applyUserPreferences(fontScale: fontScale, pageMarginsScale: pageMarginsScale)
    }
}

private final class ReadiumReaderViewController: UIViewController, EPUBNavigatorDelegate, UIGestureRecognizerDelegate {
    private let bookID: UUID
    private let epubURL: URL
    private let initialLocatorJSON: String?
    private let onClose: () -> Void
    private let onLocationChange: (Locator) -> Void
    private var readerFontScale: Double
    private var readerPageMarginsScale: Double

    private let spinner = UIActivityIndicatorView(style: .large)
    private let readium = ReadiumRuntime()

    private var publication: Publication?
    private var navigator: EPUBNavigatorViewController?
    private var isChromeVisible = false
    private var hideChromeTask: Task<Void, Never>?

    init(
        bookID: UUID,
        epubURL: URL,
        initialLocatorJSON: String?,
        initialFontScale: Double,
        initialPageMarginsScale: Double,
        onClose: @escaping () -> Void,
        onLocationChange: @escaping (Locator) -> Void
    ) {
        self.bookID = bookID
        self.epubURL = epubURL
        self.initialLocatorJSON = initialLocatorJSON
        self.onClose = onClose
        self.onLocationChange = onLocationChange
        readerFontScale = initialFontScale
        readerPageMarginsScale = initialPageMarginsScale
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
        setupNavigationChrome()
        setupTapToToggleChrome()

        Task {
            await loadReader()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        hideChrome(animated: false)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        hideChromeTask?.cancel()
        hideChromeTask = nil
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

    private func setupNavigationChrome() {
        let closeItem = UIBarButtonItem(
            image: UIImage(systemName: "chevron.left"),
            style: .plain,
            target: self,
            action: #selector(closeReaderTapped)
        )
        closeItem.accessibilityLabel = String(localized: "Close Reader")
        navigationItem.leftBarButtonItem = closeItem
        navigationItem.title = nil
    }

    private func setupTapToToggleChrome() {
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleScreenTap(_:)))
        tapGesture.cancelsTouchesInView = false
        tapGesture.delegate = self
        view.addGestureRecognizer(tapGesture)
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

            let navigator = try EPUBNavigatorViewController(
                publication: publication,
                initialLocation: initialLocator,
                config: EPUBNavigatorViewController.Configuration(
                    preferences: makeUserPreferences(),
                    contentInset: [
                        .compact: (top: 20, bottom: 20),
                        .regular: (top: 28, bottom: 28),
                    ],
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
            showChrome(animated: false)
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

    @objc
    private func closeReaderTapped() {
        onClose()
    }

    @objc
    private func handleScreenTap(_ gesture: UITapGestureRecognizer) {
        toggleChrome()
    }

    private func toggleChrome() {
        if isChromeVisible {
            hideChrome(animated: true)
        } else {
            showChrome(animated: true)
        }
    }

    private func showChrome(animated: Bool) {
        hideChromeTask?.cancel()
        isChromeVisible = true
        navigationController?.setNavigationBarHidden(false, animated: animated)

        hideChromeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                self.hideChrome(animated: true)
            }
        }
    }

    private func hideChrome(animated: Bool) {
        hideChromeTask?.cancel()
        hideChromeTask = nil
        isChromeVisible = false
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    func navigator(_ navigator: EPUBNavigatorViewController, setupUserScripts userContentController: WKUserContentController) {
        let script = """
        (() => {
          if (document.getElementById('yomi-layout-fix-style')) return;
          const style = document.createElement('style');
          style.id = 'yomi-layout-fix-style';
          style.textContent = \(javaScriptStringLiteral(Self.layoutFixCSS));
          document.head.appendChild(style);
        })();
        """
        userContentController.addUserScript(
            WKUserScript(
                source: script,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
    }

    func applyUserPreferences(fontScale: Double, pageMarginsScale: Double) {
        let normalizedFontScale = max(0.7, min(fontScale, 2.2))
        let normalizedMargins = max(0.0, min(pageMarginsScale, 2.5))
        let didChange = abs(normalizedFontScale - readerFontScale) > 0.0001
            || abs(normalizedMargins - readerPageMarginsScale) > 0.0001

        guard didChange else {
            return
        }

        readerFontScale = normalizedFontScale
        readerPageMarginsScale = normalizedMargins
        navigator?.submitPreferences(makeUserPreferences())
    }

    private func makeUserPreferences() -> EPUBPreferences {
        EPUBPreferences(
            columnCount: .one,
            fontSize: readerFontScale,
            pageMargins: readerPageMarginsScale,
            publisherStyles: false,
            readingProgression: .ltr,
            scroll: false,
            textNormalization: true,
            verticalText: false
        )
    }

    private func javaScriptStringLiteral(_ text: String) -> String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: [text]),
            let json = String(data: data, encoding: .utf8)
        else {
            return "\"\""
        }

        return String(json.dropFirst().dropLast())
    }

    private static let layoutFixCSS = """
    html, body {
      max-width: 100% !important;
      overflow-x: hidden !important;
      box-sizing: border-box !important;
    }

    h1, h2, h3, h4, h5, h6 {
      max-width: 100% !important;
      box-sizing: border-box !important;
      overflow-wrap: anywhere !important;
      word-break: break-word !important;
      margin-left: 0 !important;
      margin-right: 0 !important;
    }

    p, div, section, article, header, main, blockquote, li {
      max-width: 100% !important;
      box-sizing: border-box !important;
      overflow-wrap: anywhere !important;
      word-break: break-word !important;
    }

    img, svg, video, canvas, table, pre, code {
      max-width: 100% !important;
      box-sizing: border-box !important;
    }

    table {
      display: block !important;
      overflow-x: auto !important;
    }
    """
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
