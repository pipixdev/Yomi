//
//  ReaderView.swift
//  Yomi
//

import SwiftUI

#if canImport(UIKit)
import AVFoundation
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
    @AppStorage("reader.fontOption") private var readerFontOptionRawValue = ReaderFontOption.mincho.rawValue

    private var book: BookRecord? {
        store.book(id: bookID)
    }

    var body: some View {
        Group {
            if let book, let epubURL = store.epubURL(for: book) {
#if canImport(ReadiumNavigator) && canImport(ReadiumShared) && canImport(ReadiumStreamer) && canImport(UIKit)
                ReadiumReaderContainer(
                    bookID: bookID,
                    normalizedURL: store.normalizedURL(for: book),
                    epubURL: epubURL,
                    initialLocatorJSON: book.lastReadLocatorJSON,
                    fontScale: readerFontScale,
                    pageMarginsScale: readerPageMarginsScale,
                    fontOptionRawValue: readerFontOptionRawValue,
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
    let normalizedURL: URL?
    let epubURL: URL
    let initialLocatorJSON: String?
    let fontScale: Double
    let pageMarginsScale: Double
    let fontOptionRawValue: String
    let onClose: () -> Void
    let onLocationChange: (Locator) -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let readerController = ReadiumReaderViewController(
            bookID: bookID,
            normalizedURL: normalizedURL,
            epubURL: epubURL,
            initialLocatorJSON: initialLocatorJSON,
            initialFontScale: fontScale,
            initialPageMarginsScale: pageMarginsScale,
            initialFontOptionRawValue: fontOptionRawValue,
            onLocationChange: onLocationChange
        )
        let dismissalController = ReaderDismissalViewController(onClose: onClose)
        let navigationController = UINavigationController(rootViewController: dismissalController)
        navigationController.setViewControllers(
            [dismissalController, readerController],
            animated: false
        )
        return navigationController
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {
        guard let reader = uiViewController.viewControllers
            .compactMap({ $0 as? ReadiumReaderViewController })
            .first
        else {
            return
        }
        reader.applyUserPreferences(
            fontScale: fontScale,
            pageMarginsScale: pageMarginsScale,
            fontOptionRawValue: fontOptionRawValue
        )
    }
}

private final class ReadiumReaderViewController: UIViewController, EPUBNavigatorDelegate, WKScriptMessageHandler {
    private let bookID: UUID
    private let normalizedURL: URL?
    private let epubURL: URL
    private let initialLocatorJSON: String?
    private let onLocationChange: (Locator) -> Void
    private var readerFontScale: Double
    private var readerPageMarginsScale: Double
    private var readerFontOption: ReaderFontOption

    private let spinner = UIActivityIndicatorView(style: .large)
    private let readium = ReadiumRuntime()

    private var publication: Publication?
    private var navigator: EPUBNavigatorViewController?
    private var pendingAnalysisParagraphIndex: Int?

    init(
        bookID: UUID,
        normalizedURL: URL?,
        epubURL: URL,
        initialLocatorJSON: String?,
        initialFontScale: Double,
        initialPageMarginsScale: Double,
        initialFontOptionRawValue: String,
        onLocationChange: @escaping (Locator) -> Void
    ) {
        self.bookID = bookID
        self.normalizedURL = normalizedURL
        self.epubURL = epubURL
        self.initialLocatorJSON = initialLocatorJSON
        self.onLocationChange = onLocationChange
        readerFontScale = initialFontScale
        readerPageMarginsScale = initialPageMarginsScale
        readerFontOption = ReaderFontOption(rawValue: initialFontOptionRawValue) ?? .mincho
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        edgesForExtendedLayout = []
        navigationItem.largeTitleDisplayMode = .never
        setupSpinner()
        setupNavigationChrome()

        Task {
            await loadReader()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        revealPendingAnalysisParagraph()
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
        navigationItem.backButtonDisplayMode = .minimal
        navigationItem.title = nil
    }

    private func loadReader() async {
        do {
            let asset = try await makeReaderAsset()
            let publication = try await readium.publicationOpener.open(
                asset: asset,
                allowUserInteraction: true,
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
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func makeReaderAsset() async throws -> Asset {
        if let normalizedURL {
            let standardizedURL = normalizedURL.standardizedFileURL
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory),
               isDirectory.boolValue,
               let directoryFileURL = FileURL(url: standardizedURL) {
                let container = try await DirectoryContainer(directory: directoryFileURL)
                return try await readium.assetRetriever.retrieve(
                    container: container,
                    hints: FormatHints(mediaType: .epub)
                ).get()
            }
        }

        guard let absoluteURL = epubURL.anyURL.absoluteURL else {
            throw CocoaError(.fileReadUnknown)
        }

        return try await readium.assetRetriever.retrieve(url: absoluteURL).get()
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

    func navigatorContentInset(_ navigator: VisualNavigator) -> UIEdgeInsets? {
        UIEdgeInsets(
            top: 16,
            left: 0,
            bottom: max(view.safeAreaInsets.bottom, 20),
            right: 0
        )
    }

    func navigator(_ navigator: EPUBNavigatorViewController, setupUserScripts userContentController: WKUserContentController) {
        userContentController.removeScriptMessageHandler(forName: Self.analyzeParagraphHandlerName)
        userContentController.add(self, name: Self.analyzeParagraphHandlerName)
        userContentController.addUserScript(
            WKUserScript(
                source: Self.paragraphAnalysisScript(
                    analyzeParagraphLabel: String(localized: "Analyze paragraph")
                ),
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.analyzeParagraphHandlerName else {
            return
        }

        guard
            let body = message.body as? [String: Any],
            let paragraphs = body["paragraphs"] as? [String],
            let index = body["index"] as? Int
        else {
            return
        }

        presentParagraphAnalysis(paragraphs: paragraphs, initialIndex: index)
    }

    func applyUserPreferences(fontScale: Double, pageMarginsScale: Double, fontOptionRawValue: String) {
        let normalizedFontScale = max(0.7, min(fontScale, 2.2))
        let normalizedMargins = max(0.0, min(pageMarginsScale, 2.5))
        let normalizedFontOption = ReaderFontOption(rawValue: fontOptionRawValue) ?? .mincho
        let didChange = abs(normalizedFontScale - readerFontScale) > 0.0001
            || abs(normalizedMargins - readerPageMarginsScale) > 0.0001
            || normalizedFontOption != readerFontOption

        guard didChange else {
            return
        }

        readerFontScale = normalizedFontScale
        readerPageMarginsScale = normalizedMargins
        readerFontOption = normalizedFontOption
        navigator?.submitPreferences(makeUserPreferences())
    }

    private func makeUserPreferences() -> EPUBPreferences {
        EPUBPreferences(
            columnCount: .one,
            fontFamily: resolvedFontFamily(for: readerFontOption),
            fontSize: readerFontScale,
            pageMargins: readerPageMarginsScale,
            publisherStyles: false,
            readingProgression: .ltr,
            scroll: false,
            textNormalization: true,
            verticalText: false
        )
    }

    private func resolvedFontFamily(for option: ReaderFontOption) -> FontFamily {
        switch option {
        case .mincho:
            // Book-like serif style to make small kana distinctions clearer.
            return FontFamily(rawValue: "Hiragino Mincho ProN")
        case .gothic:
            return FontFamily(rawValue: "Hiragino Sans")
        }
    }

    private func presentParagraphAnalysis(paragraphs: [String], initialIndex: Int) {
        guard !paragraphs.isEmpty, paragraphs.indices.contains(initialIndex) else {
            return
        }

        pendingAnalysisParagraphIndex = initialIndex
        navigationController?.setNavigationBarHidden(false, animated: false)

        let controller = ReaderAnalysisHostingController(
            rootView: ParagraphAnalysisView(
                paragraphs: paragraphs,
                initialIndex: initialIndex,
                onParagraphChange: { [weak self] index in
                    self?.pendingAnalysisParagraphIndex = index
                }
            )
        )
        controller.title = String(localized: "Parse")
        navigationController?.pushViewController(controller, animated: true)
    }

    private func revealPendingAnalysisParagraph() {
        guard let index = pendingAnalysisParagraphIndex else { return }
        pendingAnalysisParagraphIndex = nil

        Task { [weak self] in
            _ = await self?.navigator?.evaluateJavaScript(
                "window.yomiRevealParagraph?.(\(index));"
            )
        }
    }

    private static let analyzeParagraphHandlerName = "yomiAnalyzeParagraph"

    private static func paragraphAnalysisScript(
        analyzeParagraphLabel: String
    ) -> String {
        let escapedAnalyzeLabel = analyzeParagraphLabel.javascriptStringEscaped()
        return """
    (() => {
      const SLOT_SELECTOR = '.yomi-paragraph-slot';
      const ANALYZE_HANDLER_NAME = '\(Self.analyzeParagraphHandlerName)';
      const ANALYZE_LABEL = '\(escapedAnalyzeLabel)';

      const paragraphEntries = () => Array.from(document.querySelectorAll(SLOT_SELECTOR))
        .map(slot => ({
          slot,
          target: slot.previousElementSibling,
          text: (slot.dataset.yomiParagraphText || '').trim()
        }))
        .filter(entry => entry.target && entry.text);

      const openAnalysis = target => {
        const entries = paragraphEntries();
        const index = entries.findIndex(entry => entry.target === target);
        if (index < 0) return;

        const handler = window.webkit?.messageHandlers?.[ANALYZE_HANDLER_NAME];
        if (!handler || !handler.postMessage) return;
        handler.postMessage({
          paragraphs: entries.map(entry => entry.text),
          index
        });
      };

      window.yomiRevealParagraph = index => {
        const entries = paragraphEntries();
        const entry = entries[Number(index)];
        if (!entry?.target) return false;
        entry.target.scrollIntoView({
          behavior: 'auto',
          block: 'center',
          inline: 'center'
        });
        return true;
      };

      const hydrateSlot = slot => {
        slot.style.setProperty('display', 'none', 'important');
        slot.replaceChildren();

        const target = slot.previousElementSibling;
        if (!target || target.dataset.yomiAnalysisBound === '1') return;
        target.dataset.yomiAnalysisBound = '1';
        target.setAttribute('role', 'button');
        target.setAttribute('tabindex', '0');
        target.setAttribute('aria-description', ANALYZE_LABEL);

        target.addEventListener('click', event => {
          if (event.target.closest('a, button, input, textarea, select')) return;
          const selection = window.getSelection();
          if (selection && !selection.isCollapsed) return;
          event.preventDefault();
          event.stopPropagation();
          openAnalysis(target);
        });

        target.addEventListener('keydown', event => {
          if (event.key !== 'Enter' && event.key !== ' ') return;
          event.preventDefault();
          openAnalysis(target);
        });
      };

      const hydrateTree = root => {
        if (root.matches && root.matches(SLOT_SELECTOR)) {
          hydrateSlot(root);
        }
        if (!root.querySelectorAll) return;
        root.querySelectorAll(SLOT_SELECTOR).forEach(hydrateSlot);
      };

      const bootstrap = () => {
        hydrateTree(document);
        const observer = new MutationObserver(mutations => {
          for (const mutation of mutations) {
            mutation.addedNodes.forEach(node => {
              if (node.nodeType === Node.ELEMENT_NODE) {
                hydrateTree(node);
              }
            });
          }
        });
        observer.observe(document.documentElement, { childList: true, subtree: true });
      };

      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', bootstrap, { once: true });
      } else {
        bootstrap();
      }
    })();
    """
    }
}

private final class ReaderDismissalViewController: UIViewController {
    private let onClose: () -> Void
    private var hasAppeared = false

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.backButtonDisplayMode = .minimal
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasAppeared else { return }
        hasAppeared = true
        onClose()
    }
}

private final class ReaderAnalysisHostingController<Content: View>: UIHostingController<Content> {
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: false)
    }
}

private final class ReadiumRuntime {
    let httpClient = DefaultHTTPClient()
    lazy var assetRetriever = AssetRetriever(httpClient: httpClient)
    lazy var publicationOpener = PublicationOpener(
        parser: DefaultPublicationParser(
            httpClient: httpClient,
            assetRetriever: assetRetriever,
            pdfFactory: DefaultPDFDocumentFactory()
        )
    )
}

private extension String {
    func javascriptStringEscaped() -> String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}
#endif
