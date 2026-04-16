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
        let controller = ReadiumReaderViewController(
            bookID: bookID,
            normalizedURL: normalizedURL,
            epubURL: epubURL,
            initialLocatorJSON: initialLocatorJSON,
            initialFontScale: fontScale,
            initialPageMarginsScale: pageMarginsScale,
            initialFontOptionRawValue: fontOptionRawValue,
            onClose: onClose,
            onLocationChange: onLocationChange
        )
        return UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {
        guard let reader = uiViewController.viewControllers.first as? ReadiumReaderViewController else {
            return
        }
        reader.applyUserPreferences(
            fontScale: fontScale,
            pageMarginsScale: pageMarginsScale,
            fontOptionRawValue: fontOptionRawValue
        )
    }
}

private final class ReadiumReaderViewController: UIViewController, EPUBNavigatorDelegate, UIGestureRecognizerDelegate, WKScriptMessageHandler {
    private let bookID: UUID
    private let normalizedURL: URL?
    private let epubURL: URL
    private let initialLocatorJSON: String?
    private let onClose: () -> Void
    private let onLocationChange: (Locator) -> Void
    private var readerFontScale: Double
    private var readerPageMarginsScale: Double
    private var readerFontOption: ReaderFontOption

    private let spinner = UIActivityIndicatorView(style: .large)
    private let readium = ReadiumRuntime()

    private var publication: Publication?
    private var navigator: EPUBNavigatorViewController?
    private var isChromeVisible = false
    private var hideChromeTask: Task<Void, Never>?
    private let speechSynthesizer = AVSpeechSynthesizer()
    private let textAnalyzer = JapaneseTextAnalyzer()

    init(
        bookID: UUID,
        normalizedURL: URL?,
        epubURL: URL,
        initialLocatorJSON: String?,
        initialFontScale: Double,
        initialPageMarginsScale: Double,
        initialFontOptionRawValue: String,
        onClose: @escaping () -> Void,
        onLocationChange: @escaping (Locator) -> Void
    ) {
        self.bookID = bookID
        self.normalizedURL = normalizedURL
        self.epubURL = epubURL
        self.initialLocatorJSON = initialLocatorJSON
        self.onClose = onClose
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
        speechSynthesizer.stopSpeaking(at: .immediate)
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
            showChrome(animated: false)
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
        userContentController.removeScriptMessageHandler(forName: Self.speakParagraphHandlerName)
        userContentController.removeScriptMessageHandler(forName: Self.analyzeParagraphHandlerName)
        userContentController.add(self, name: Self.speakParagraphHandlerName)
        userContentController.add(self, name: Self.analyzeParagraphHandlerName)
        userContentController.addUserScript(
            WKUserScript(
                source: Self.paragraphActionsScript(
                    copyParagraphLabel: String(localized: "Copy paragraph"),
                    readParagraphLabel: String(localized: "Read paragraph"),
                    analyzeParagraphLabel: String(localized: "Analyze paragraph"),
                    copyIconDataURI: Self.paragraphIconDataURI(systemName: "doc.on.doc"),
                    readIconDataURI: Self.paragraphIconDataURI(systemName: "speaker.wave.2"),
                    analyzeIconDataURI: Self.paragraphIconDataURI(systemName: "text.magnifyingglass")
                ),
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard
            message.name == Self.speakParagraphHandlerName || message.name == Self.analyzeParagraphHandlerName
        else {
            return
        }

        guard
            let body = message.body as? [String: Any],
            let text = body["text"] as? String
        else {
            return
        }

        if message.name == Self.speakParagraphHandlerName {
            requestParagraphSpeech(text: text)
        } else {
            presentParagraphAnalysis(for: text)
        }
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

    private func requestParagraphSpeech(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        speechSynthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = AVSpeechSynthesisVoice(language: "ja-JP")
        speechSynthesizer.speak(utterance)
    }

    private func presentParagraphAnalysis(for text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        hideChromeTask?.cancel()
        hideChromeTask = nil
        isChromeVisible = true
        navigationController?.setNavigationBarHidden(false, animated: false)

        let controller = ReaderAnalysisHostingController(
            rootView: ParagraphAnalysisView(
                tokens: textAnalyzer.tokens(for: trimmed)
            )
        )
        controller.title = String(localized: "Parse")
        navigationController?.pushViewController(controller, animated: true)
    }

    private static let speakParagraphHandlerName = "yomiSpeakParagraph"
    private static let analyzeParagraphHandlerName = "yomiAnalyzeParagraph"

    private static func paragraphActionsScript(
        copyParagraphLabel: String,
        readParagraphLabel: String,
        analyzeParagraphLabel: String,
        copyIconDataURI: String,
        readIconDataURI: String,
        analyzeIconDataURI: String
    ) -> String {
        let escapedCopyLabel = copyParagraphLabel.javascriptStringEscaped()
        let escapedReadLabel = readParagraphLabel.javascriptStringEscaped()
        let escapedAnalyzeLabel = analyzeParagraphLabel.javascriptStringEscaped()
        let escapedCopyIconDataURI = copyIconDataURI.javascriptStringEscaped()
        let escapedReadIconDataURI = readIconDataURI.javascriptStringEscaped()
        let escapedAnalyzeIconDataURI = analyzeIconDataURI.javascriptStringEscaped()
        return """
    (() => {
      const SLOT_SELECTOR = '.yomi-paragraph-slot';
      const TOOLBAR_CLASS = 'yomi-paragraph-toolbar';
      const BUTTON_CLASS = 'yomi-paragraph-action';
      const BUTTON_ICON_CLASS = 'yomi-paragraph-action-icon';
      const SPEAK_HANDLER_NAME = '\(Self.speakParagraphHandlerName)';
      const ANALYZE_HANDLER_NAME = '\(Self.analyzeParagraphHandlerName)';

      const actions = [
        {
          id: 'copy',
          iconDataURI: '\(escapedCopyIconDataURI)',
          label: '\(escapedCopyLabel)',
          perform: async (slot, button) => {
            const text = (slot.dataset.yomiParagraphText || '').trim();
            if (!text) return false;

            const copyWithClipboardApi = async () => {
              if (!navigator.clipboard || !navigator.clipboard.writeText) return false;
              try {
                await navigator.clipboard.writeText(text);
                return true;
              } catch {
                return false;
              }
            };

            const copyWithSelectionFallback = () => {
              const textarea = document.createElement('textarea');
              textarea.value = text;
              textarea.setAttribute('readonly', 'readonly');
              textarea.style.position = 'fixed';
              textarea.style.opacity = '0';
              textarea.style.pointerEvents = 'none';
              document.body.appendChild(textarea);
              textarea.focus();
              textarea.select();
              let copied = false;
              try {
                copied = document.execCommand('copy');
              } catch {
                copied = false;
              }
              textarea.remove();
              return copied;
            };

            const copied = await copyWithClipboardApi() || copyWithSelectionFallback();
            if (copied) {
              button.classList.add('is-feedback');
              window.setTimeout(() => button.classList.remove('is-feedback'), 900);
            }
            return copied;
          }
        },
        {
          id: 'speak',
          iconDataURI: '\(escapedReadIconDataURI)',
          label: '\(escapedReadLabel)',
          perform: async (slot, button) => {
            const text = (slot.dataset.yomiParagraphText || '').trim();
            if (!text) return false;
            const handler = window.webkit?.messageHandlers?.[SPEAK_HANDLER_NAME];
            if (!handler || !handler.postMessage) return false;
            try {
              handler.postMessage({ text });
              button.classList.add('is-feedback');
              window.setTimeout(() => button.classList.remove('is-feedback'), 900);
              return true;
            } catch {
              return false;
            }
          }
        },
        {
          id: 'analyze',
          iconDataURI: '\(escapedAnalyzeIconDataURI)',
          label: '\(escapedAnalyzeLabel)',
          perform: async (slot, button) => {
            const text = (slot.dataset.yomiParagraphText || '').trim();
            if (!text) return false;
            const handler = window.webkit?.messageHandlers?.[ANALYZE_HANDLER_NAME];
            if (!handler || !handler.postMessage) return false;
            try {
              handler.postMessage({ text });
              button.classList.add('is-feedback');
              window.setTimeout(() => button.classList.remove('is-feedback'), 900);
              return true;
            } catch {
              return false;
            }
          }
        }
      ];

      const buildButton = (action, slot) => {
        const button = document.createElement('button');
        button.type = 'button';
        button.className = BUTTON_CLASS;
        button.dataset.yomiAction = action.id;
        const icon = document.createElement('img');
        icon.className = BUTTON_ICON_CLASS;
        icon.src = action.iconDataURI;
        icon.alt = '';
        icon.setAttribute('aria-hidden', 'true');
        button.appendChild(icon);
        button.setAttribute('aria-label', action.label);
        button.setAttribute('title', action.label);
        button.addEventListener('click', async event => {
          event.preventDefault();
          event.stopPropagation();
          await action.perform(slot, button);
        });
        return button;
      };

      const hydrateSlot = slot => {
        if (slot.dataset.yomiActionsBound === '1') return;
        slot.dataset.yomiActionsBound = '1';

        const toolbar = document.createElement('div');
        toolbar.className = TOOLBAR_CLASS;
        for (const action of actions) {
          toolbar.appendChild(buildButton(action, slot));
        }
        slot.replaceChildren(toolbar);
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

    private static func paragraphIconDataURI(systemName: String) -> String {
        let config = UIImage.SymbolConfiguration(pointSize: 16, weight: .regular, scale: .medium)
        guard
            let symbolImage = UIImage(systemName: systemName, withConfiguration: config)?
                .withTintColor(.black, renderingMode: .alwaysOriginal),
            let pngData = symbolImage.pngData()
        else {
            return ""
        }
        return "data:image/png;base64,\(pngData.base64EncodedString())"
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
