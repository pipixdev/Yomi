import SwiftUI
#if canImport(UIKit)
import UIKit
import WebKit
import Combine
#endif

struct ParagraphAnalysisView: View {
    @ObservedObject var store: LibraryStore
    let bookID: UUID
    let bookmarkLocator: (Int) -> String?
    let paragraphs: [String]
    let initialIndex: Int
    let onParagraphChange: (Int) -> Void
    @AppStorage("analysis.fontScale") private var fontScale = 1.0
    @AppStorage(DictionaryLookupPreferences.externalLookupEnabledKey) private var externalDictionary = false
    @AppStorage(DictionaryLookupPreferences.externalLookupURLTemplateKey) private var dictionaryTemplate = ""
    @State private var currentIndex: Int
    @State private var dictionaryTerm: DictionaryTerm?

    init(paragraphs: [String], initialIndex: Int, store: LibraryStore, bookID: UUID,
         bookmarkLocator: @escaping (Int) -> String?, onParagraphChange: @escaping (Int) -> Void) {
        let paragraphs = paragraphs.isEmpty ? [""] : paragraphs
        let index = min(max(initialIndex, 0), paragraphs.count - 1)
        self.paragraphs = paragraphs
        self.initialIndex = index
        self.store = store
        self.bookID = bookID
        self.bookmarkLocator = bookmarkLocator
        self.onParagraphChange = onParagraphChange
        _currentIndex = State(initialValue: index)
    }

    var body: some View {
        Group {
#if canImport(UIKit)
            ContinuousAnalysisWebView(
                paragraphs: paragraphs, initialIndex: initialIndex, fontScale: fontScale,
                store: store, bookID: bookID, bookmarkLocator: bookmarkLocator,
                onParagraphChange: { index in
                    currentIndex = index
                    onParagraphChange(index)
                }, onSelectToken: openDictionary
            )
#else
            ScrollView { LazyVStack { ForEach(paragraphs.indices, id: \.self) { Text(paragraphs[$0]) } } }
#endif
        }
        .navigationTitle(String(localized: "Parse"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(String(localized: "Parse")).font(.headline)
                    Text("\(currentIndex + 1) / \(paragraphs.count)")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .alert("Bookmark error", isPresented: Binding(
            get: { store.bookmarkError != nil },
            set: { if !$0 { store.bookmarkError = nil } }
        )) {
            Button("OK") { store.bookmarkError = nil }
        } message: { Text(store.bookmarkError ?? "") }
#if canImport(UIKit)
        .sheet(item: $dictionaryTerm) { term in
            DictionaryLookupView(term: term.value)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
#endif
    }

#if canImport(UIKit)
    private func openDictionary(_ token: ReaderToken) {
        let term: String
        switch token.partOfSpeech {
        case .noun, .verb, .adjective: term = token.dictionaryForm ?? token.surface
        default: term = token.surface
        }
        guard externalDictionary,
              let url = DictionaryLookupPreferences.externalLookupURL(for: term, template: dictionaryTemplate)
        else { dictionaryTerm = DictionaryTerm(value: term); return }
        UIApplication.shared.open(url, options: [:]) { opened in
            if !opened { dictionaryTerm = DictionaryTerm(value: term) }
        }
    }
#endif
}

private struct DictionaryTerm: Identifiable {
    let value: String
    var id: String { value }
}

#if canImport(UIKit)
private struct DictionaryLookupView: UIViewControllerRepresentable {
    let term: String
    func makeUIViewController(context: Context) -> UIReferenceLibraryViewController {
        UIReferenceLibraryViewController(term: term)
    }
    func updateUIViewController(_ controller: UIReferenceLibraryViewController, context: Context) {}
}

/// One scrolling surface for the whole chapter. Native state is bounded to the DOM's live window.
private struct ContinuousAnalysisWebView: UIViewRepresentable {
    let paragraphs: [String]
    let initialIndex: Int
    let fontScale: Double
    let store: LibraryStore
    let bookID: UUID
    let bookmarkLocator: (Int) -> String?
    let onParagraphChange: (Int) -> Void
    let onSelectToken: (ReaderToken) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(WeakHandler(context.coordinator), name: "analysis")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground
        // SwiftUI already places this view inside the navigation safe area.
        // A second UIKit inset adjustment during the push would move the HTML anchor.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.delegate = context.coordinator
        webView.navigationDelegate = context.coordinator
        context.coordinator.start(webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.updatePreferences()
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
        webView.navigationDelegate = nil
        webView.scrollView.delegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "analysis")
        webView.stopLoading()
    }

    private final class WeakHandler: NSObject, WKScriptMessageHandler {
        weak var target: Coordinator?
        init(_ target: Coordinator) { self.target = target }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            target?.userContentController(controller, didReceive: message)
        }
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, UIScrollViewDelegate {
        var parent: ContinuousAnalysisWebView
        private weak var webView: WKWebView?
        private let analyzer = ParagraphTokenizationService()
        private let speech = SpeechPlaybackController()
        private var speechObservation: AnyCancellable?
        private var speakingIndex: Int?
        private var loadTask: Task<Void, Never>?
        private var rows: [Int: Row] = [:]
        // Only user overrides persist outside the window; translated text remains in the disk cache.
        private var hiddenTranslations: Set<Int> = []
        private var shownTranslations: Set<Int> = []
        private var ready = false
        private var renderedScale: Double?
        private var lastBookmarks: [ParagraphBookmark] = []

        private final class Row {
            let generation: String
            init(generation: String) { self.generation = generation }
            var tokens: [ReaderToken] = []
            var load: Task<Void, Never>?
            var translation: Task<Void, Never>?
            var translationID: UUID?
            var translationVisible = false
            var locator: String?
            deinit { load?.cancel(); translation?.cancel() }
        }

        init(_ parent: ContinuousAnalysisWebView) { self.parent = parent }

        func start(_ webView: WKWebView) {
            self.webView = webView
            let paragraphs = parent.paragraphs
            let initialIndex = parent.initialIndex
            let labels = [
                "bookmark": String(localized: "Bookmark paragraph"),
                "unbookmark": String(localized: "Remove bookmark"),
                "translate": String(localized: "Translate paragraph"),
                "hideTranslation": String(localized: "Hide translation"),
                "play": String(localized: "Start reading"),
                "stop": String(localized: "Stop reading"),
                "loading": String(localized: "Translating…"),
                "translation": String(localized: "Translation"),
                "failed": String(localized: "Translation unavailable"),
                "retry": String(localized: "Try Again")
            ]
            loadTask = Task { [weak self] in
                let html = await AnalysisDocumentBuilder.shared.document(paragraphs: paragraphs, initialIndex: initialIndex, labels: labels)
                guard !Task.isCancelled, let self else { return }
                self.webView?.loadHTMLString(html, baseURL: nil)
            }
            speech.onRangeChange = { [weak self] range in
                guard let self, let index = self.speakingIndex else { return }
                self.send("highlight", ["index": index, "start": range?.location ?? 0, "length": range?.length ?? 0])
            }
            speechObservation = speech.$isSpeaking.removeDuplicates().sink { [weak self] speaking in
                guard let self, let index = self.speakingIndex else { return }
                self.send("speech", ["index": index, "active": speaking])
            }
        }

        func stop() {
            ready = false
            loadTask?.cancel()
            rows.values.forEach { $0.load?.cancel(); $0.translation?.cancel() }
            rows.removeAll()
            speech.stop()
            speech.onRangeChange = nil
            speechObservation = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            updatePreferences()
            send("start", [:])
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            send("userScroll", [:])
        }

        func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
            send("userScroll", [:])
            return true
        }

        func updatePreferences() {
            guard ready else { return }
            let scale = min(max(parent.fontScale, 0.7), 2.2)
            if renderedScale != scale {
                renderedScale = scale
                send("scale", ["value": scale])
            }
            if lastBookmarks != parent.store.bookmarks {
                lastBookmarks = parent.store.bookmarks
                for (index, row) in rows { updateBookmark(index, row) }
            }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard ready, let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
            if action == "window", let indices = body["indices"] as? [Int] {
                reconcile(indices, generations: body["generations"] as? [String: String] ?? [:])
                return
            }
            guard let index = body["index"] as? Int, parent.paragraphs.indices.contains(index) else { return }
            if action == "position" { parent.onParagraphChange(index); return }
            guard let row = rows[index] else { return }
            switch action {
            case "bookmark":
                if let locator = row.locator {
                    parent.store.toggleBookmark(bookID: parent.bookID, text: parent.paragraphs[index], locatorJSON: locator)
                    updateBookmark(index, row)
                }
            case "translate": toggleTranslation(index, row)
            case "retry": requestTranslation(index, row)
            case "speech":
                if speakingIndex == index, speech.isSpeaking { speech.stop() }
                else {
                    speech.stop()
                    speakingIndex = index
                    speech.speak(row.tokens.map(\.surface).joined())
                }
            case "token":
                if let tokenIndex = body["token"] as? Int, row.tokens.indices.contains(tokenIndex) {
                    parent.onSelectToken(row.tokens[tokenIndex])
                }
            default: break
            }
        }

        private func reconcile(_ requested: [Int], generations: [String: String]) {
            let indices = Array(requested.filter { parent.paragraphs.indices.contains($0) }.prefix(33))
            let retained = Set(indices)
            for index in Array(rows.keys) where !retained.contains(index) || rows[index]?.generation != generations[String(index)] {
                let row = rows.removeValue(forKey: index)
                row?.load?.cancel()
                row?.translation?.cancel()
                if speakingIndex == index { speech.stop(); speakingIndex = nil }
            }
            for index in indices where rows[index] == nil {
                guard let generation = generations[String(index)] else { continue }
                let row = Row(generation: generation)
                row.locator = parent.bookmarkLocator(index)
                rows[index] = row
                let text = parent.paragraphs[index]
                let analyzer = analyzer
                row.load = Task { [weak self, weak row] in
                    let result = await analyzer.renderedParagraph(for: text)
                    guard !Task.isCancelled, let self, let row, self.rows[index] === row else { return }
                    row.tokens = result.tokens
                    self.send("render", ["index": index, "generation": row.generation, "html": result.html])
                    self.updateBookmark(index, row)
                    guard !self.hiddenTranslations.contains(index) else { return }
                    let source = BingTranslateClient.sourceLines(for: text)
                    let cached = await BingTranslateClient.cachedTranslation(for: source, targetLanguage: BingTranslateClient.preferredTargetLanguage())
                    guard !Task.isCancelled, self.rows[index] === row,
                          row.translationID == nil, !self.hiddenTranslations.contains(index) else { return }
                    if let cached {
                        row.translationVisible = true
                        self.sendTranslation(index, row, state: "translated", lines: cached)
                    } else if self.shownTranslations.contains(index) {
                        self.requestTranslation(index, row)
                    }
                }
            }
        }

        private func updateBookmark(_ index: Int, _ row: Row) {
            send("bookmark", ["index": index, "available": row.locator != nil,
                "active": row.locator.map { parent.store.isBookmarked(bookID: parent.bookID, locatorJSON: $0) } ?? false])
        }

        private func toggleTranslation(_ index: Int, _ row: Row) {
            if row.translationVisible {
                row.translation?.cancel()
                row.translationID = nil
                row.translationVisible = false
                hiddenTranslations.insert(index)
                shownTranslations.remove(index)
                sendTranslation(index, row, state: "hidden")
            } else {
                hiddenTranslations.remove(index)
                shownTranslations.insert(index)
                requestTranslation(index, row)
            }
        }

        private func requestTranslation(_ index: Int, _ row: Row) {
            row.translation?.cancel()
            let id = UUID()
            row.translationID = id
            row.translationVisible = true
            sendTranslation(index, row, state: "loading")
            let source = BingTranslateClient.sourceLines(for: parent.paragraphs[index])
            row.translation = Task { [weak self, weak row] in
                do {
                    let lines = try await BingTranslateClient.translate(source, targetLanguage: BingTranslateClient.preferredTargetLanguage())
                    guard !Task.isCancelled, let self, let row, self.rows[index] === row, row.translationID == id else { return }
                    self.sendTranslation(index, row, state: "translated", lines: lines)
                } catch {
                    guard !Task.isCancelled, let self, let row, self.rows[index] === row, row.translationID == id else { return }
                    self.sendTranslation(index, row, state: "failed")
                }
            }
        }

        private func sendTranslation(_ index: Int, _ row: Row, state: String, lines: [String] = []) {
            send("translation", ["index": index, "generation": row.generation, "state": state, "lines": lines])
        }

        private func send(_ action: String, _ value: [String: Any]) {
            guard ready else { return }
            // Structured arguments keep book/translation text out of executable JavaScript.
            webView?.callAsyncJavaScript("window.analysisReceive(action, value)", arguments: ["action": action, "value": value], in: nil, in: .page, completionHandler: nil)
        }
    }
}
#endif
