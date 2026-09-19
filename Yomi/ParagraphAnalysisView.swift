//
//  ParagraphAnalysisView.swift
//  Yomi
//

import SwiftUI
#if canImport(UIKit)
import UIKit
import WebKit
#endif

struct ParagraphAnalysisView: View {
    @ObservedObject var store: LibraryStore
    let bookID: UUID
    let bookmarkLocator: (Int) -> String?
    let paragraphs: [String]
    let onParagraphChange: (Int) -> Void
    @State private var textAnalyzer = ParagraphTokenizationService()
    @State private var isTokenizing = true

    @AppStorage("analysis.fontScale") private var analysisFontScale = 1.0
    @AppStorage(DictionaryLookupPreferences.externalLookupEnabledKey) private var isExternalDictionaryEnabled = false
    @AppStorage(DictionaryLookupPreferences.externalLookupURLTemplateKey) private var externalDictionaryURLTemplate = ""
    @State private var activePresentation: TokenPresentation?
    @State private var contentHeight: CGFloat = 1
    @State private var currentIndex: Int
    @State private var isAtScrollBottom = false
    @State private var isAtScrollTop = true
    @State private var paragraphDragStartedAtBottom: Bool?
    @State private var paragraphDragStartedAtTop: Bool?
    @State private var tokens: [ReaderToken]
    @State private var translationRequestID: UUID?
    @State private var translationState = ParagraphTranslationState.idle
#if canImport(UIKit)
    @StateObject private var speechPlayback = SpeechPlaybackController()
    @State private var highlightedSpeechRange: NSRange?
#endif

    init(
        paragraphs: [String],
        initialIndex: Int,
        store: LibraryStore,
        bookID: UUID,
        bookmarkLocator: @escaping (Int) -> String?,
        onParagraphChange: @escaping (Int) -> Void
    ) {
        // The reader bridge already filters empty paragraphs. Preserve its indices so
        // bookmark locators and return-to-paragraph navigation stay aligned.
        let safeParagraphs = paragraphs.isEmpty ? [""] : paragraphs
        let safeIndex = min(max(initialIndex, 0), safeParagraphs.count - 1)

        self.store = store
        self.bookID = bookID
        self.bookmarkLocator = bookmarkLocator
        self.paragraphs = safeParagraphs
        self.onParagraphChange = onParagraphChange
        _currentIndex = State(initialValue: safeIndex)
        _tokens = State(initialValue: [])
    }

    private var speechText: String {
        tokens.map(\.surface).joined()
    }

    var body: some View {
        GeometryReader { viewportGeometry in
            ScrollViewReader { scrollProxy in
                ParagraphScrollContainer(onDragEnded: { translation, atTop, atBottom in
                    handleParagraphDrag(
                        translation: translation,
                        startedAtTop: atTop,
                        startedAtBottom: atBottom,
                        scrollProxy: scrollProxy
                    )
                }) {
                    VStack(spacing: 0) {
                        Color.clear
                            .frame(height: 1)
                            .id(ScrollTarget.top)

                        if isTokenizing {
                            ProgressView().padding(20)
                        } else if tokens.isEmpty {
                            CompatibilityUnavailableView(
                                "No tokens found",
                                systemImage: "text.word.spacing"
                            )
                            .padding(20)
                        } else {
                            VStack(spacing: 20) {
                                tokenContent

                                translationContent
                            }
                                .id(currentIndex)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 16)
                        }
                    }
                    .background {
#if !canImport(UIKit)
                        GeometryReader { geometry in
                            let frame = geometry.frame(in: .named(ScrollCoordinateSpace.name))
                            Color.clear.preference(
                                key: ScrollContentFramePreferenceKey.self,
                                value: frame
                            )
                        }
#endif
                    }
                }
#if !canImport(UIKit)
                .coordinateSpace(name: ScrollCoordinateSpace.name)
                .trackScrollBoundaries(
                    viewportHeight: viewportGeometry.size.height,
                    isAtTop: $isAtScrollTop,
                    isAtBottom: $isAtScrollBottom
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { _ in
                            if paragraphDragStartedAtTop == nil {
                                paragraphDragStartedAtTop = isAtScrollTop
                            }
                            if paragraphDragStartedAtBottom == nil {
                                paragraphDragStartedAtBottom = isAtScrollBottom
                            }
                        }
                        .onEnded { value in
                            handleParagraphDrag(
                                translation: value.translation,
                                startedAtTop: paragraphDragStartedAtTop ?? isAtScrollTop,
                                startedAtBottom: paragraphDragStartedAtBottom ?? isAtScrollBottom,
                                scrollProxy: scrollProxy
                            )
                            paragraphDragStartedAtTop = nil
                            paragraphDragStartedAtBottom = nil
                        }
                )
#endif
            }
        }
        .alert("Bookmark error", isPresented: Binding(get: { store.bookmarkError != nil }, set: { if !$0 { store.bookmarkError = nil } })) {
            Button("OK") { store.bookmarkError = nil }
        } message: { Text(store.bookmarkError ?? "") }
        .navigationTitle(String(localized: "Parse"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: currentIndex) {
            let index = currentIndex
            let result = await textAnalyzer.tokens(for: paragraphs[index])
            guard !Task.isCancelled, currentIndex == index else { return }
            tokens = result
            isTokenizing = false
        }
        .task(id: translationCacheIdentity) {
            await restoreCachedTranslation()
        }
#if canImport(UIKit)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(String(localized: "Parse"))
                        .font(.headline)
                    Text("\(currentIndex + 1) / \(paragraphs.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if let locator = bookmarkLocator(currentIndex) {
                    let saved = store.isBookmarked(bookID: bookID, locatorJSON: locator)
                    Button {
                        store.toggleBookmark(bookID: bookID, text: paragraphs[currentIndex], locatorJSON: locator)
                    } label: {
                        Image(systemName: saved ? "bookmark.fill" : "bookmark")
                    }
                    .accessibilityLabel(String(localized: saved ? "Remove bookmark" : "Bookmark paragraph"))
                }
                Button {
                    translateCurrentParagraph()
                } label: {
                    if translationState.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(
                            systemName: translationState.hasTranslation
                                ? "character.bubble.fill"
                                : "character.bubble"
                        )
                    }
                }
                .disabled(translationState.isLoading)
                .accessibilityLabel(String(localized: "Translate paragraph"))

                Button {
                    speechPlayback.toggle(speechText)
                } label: {
                    speechPlaybackImage
                }
                .disabled(isTokenizing)
                .accessibilityLabel(
                    speechPlayback.isSpeaking
                        ? String(localized: "Stop reading")
                        : String(localized: "Start reading")
                )
            }
        }
        .onAppear {
            speechPlayback.onRangeChange = { range in
                highlightedSpeechRange = range
            }
        }
        .onDisappear {
            translationRequestID = nil
            speechPlayback.stop()
            speechPlayback.onRangeChange = nil
        }
#endif
        .sheet(item: $activePresentation) { presentation in
            TokenPresentationSheet(presentation: presentation)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

#if canImport(UIKit)
    @ViewBuilder
    private var speechPlaybackImage: some View {
        if #available(iOS 17.0, *) {
            Image(systemName: speechPlayback.isSpeaking ? "stop.fill" : "speaker.wave.2")
                .contentTransition(.symbolEffect(.replace))
        } else {
            Image(systemName: speechPlayback.isSpeaking ? "stop.fill" : "speaker.wave.2")
        }
    }
#endif

    @discardableResult
    private func handleParagraphDrag(
        translation: CGSize,
        startedAtTop: Bool,
        startedAtBottom: Bool,
        scrollProxy: ScrollViewProxy
    ) -> Bool {
        let verticalDistance = translation.height
        guard
            abs(verticalDistance) >= 55,
            abs(verticalDistance) > abs(translation.width)
        else {
            return false
        }

        let proposedIndex: Int
        if verticalDistance < 0, startedAtBottom {
            proposedIndex = currentIndex + 1
        } else if verticalDistance > 0, startedAtTop {
            proposedIndex = currentIndex - 1
        } else {
            return false
        }

        guard paragraphs.indices.contains(proposedIndex) else { return false }

#if canImport(UIKit)
        speechPlayback.stop()
        highlightedSpeechRange = nil
#endif
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            activePresentation = nil
            contentHeight = 1
            translationRequestID = nil
            translationState = .idle
            currentIndex = proposedIndex
            tokens = []
            isTokenizing = true
#if !canImport(UIKit)
            scrollProxy.scrollTo(ScrollTarget.top, anchor: .top)
#endif
        }
        onParagraphChange(proposedIndex)
        return true
    }

    @ViewBuilder
    private var tokenContent: some View {
#if canImport(UIKit)
        AnalysisTokensWebView(
            tokens: tokens,
            fontScale: analysisFontScale,
            highlightedRange: highlightedSpeechRange,
            contentHeight: $contentHeight,
            onSelectToken: { token in
                openDictionary(for: token)
            }
        )
        .frame(height: max(contentHeight, 1))
#else
        Text(tokens.map(\.surface).joined(separator: " "))
            .frame(maxWidth: .infinity, alignment: .leading)
#endif
    }

    @ViewBuilder
    private var translationContent: some View {
        switch translationState {
        case .idle:
            EmptyView()

        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(String(localized: "Translating…"))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))

        case .translated(let lines):
            VStack(alignment: .leading, spacing: 12) {
                Label(String(localized: "Translation"), systemImage: "character.bubble.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
            .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))

        case .failed:
            VStack(alignment: .leading, spacing: 12) {
                Label(
                    String(localized: "Translation unavailable"),
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.secondary)

                Button(String(localized: "Try Again")) {
                    translateCurrentParagraph()
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func translateCurrentParagraph() {
        let sourceLines = translationSourceLines
        guard !sourceLines.isEmpty else { return }

        let requestID = UUID()
        translationRequestID = requestID
        withAnimation(.easeInOut(duration: 0.18)) {
            translationState = .loading
        }

        Task {
            do {
                let translatedLines = try await BingTranslateClient.translate(
                    sourceLines,
                    targetLanguage: BingTranslateClient.preferredTargetLanguage()
                )
                guard translationRequestID == requestID else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    translationState = .translated(translatedLines)
                }
            } catch is CancellationError {
                return
            } catch {
                guard translationRequestID == requestID else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    translationState = .failed
                }
            }
        }
    }

    private var translationSourceLines: [String] {
        BingTranslateClient.sourceLines(for: paragraphs[currentIndex])
    }

    private var translationCacheIdentity: String {
        ([BingTranslateClient.preferredTargetLanguage()] + translationSourceLines)
            .joined(separator: "\u{1F}")
    }

    private func restoreCachedTranslation() async {
        guard translationState == .idle else { return }

        let paragraphIndex = currentIndex
        let sourceLines = translationSourceLines
        let targetLanguage = BingTranslateClient.preferredTargetLanguage()
        guard !sourceLines.isEmpty else { return }

        guard let translatedLines = await BingTranslateClient.cachedTranslation(
            for: sourceLines,
            targetLanguage: targetLanguage
        ) else {
            return
        }

        guard
            !Task.isCancelled,
            currentIndex == paragraphIndex,
            translationState == .idle
        else {
            return
        }

        withAnimation(.easeInOut(duration: 0.18)) {
            translationState = .translated(translatedLines)
        }
    }

#if canImport(UIKit)
    private func openDictionary(for token: ReaderToken) {
        let presentation = TokenPresentation.forToken(token)
        guard
            isExternalDictionaryEnabled,
            let url = DictionaryLookupPreferences.externalLookupURL(
                for: presentation.term,
                template: externalDictionaryURLTemplate
            )
        else {
            activePresentation = presentation
            return
        }

        UIApplication.shared.open(url, options: [:]) { didOpen in
            guard !didOpen else { return }
            activePresentation = presentation
        }
    }
#endif
}

private enum ParagraphTranslationState: Equatable {
    case idle
    case loading
    case translated([String])
    case failed

    var isLoading: Bool {
        self == .loading
    }

    var hasTranslation: Bool {
        if case .translated = self {
            return true
        }
        return false
    }
}

/// Own the scroll view rather than searching SwiftUI's private view hierarchy.
#if canImport(UIKit)
private struct ParagraphScrollContainer<Content: View>: UIViewControllerRepresentable {
    let onDragEnded: (CGSize, Bool, Bool) -> Bool
    @ViewBuilder let content: () -> Content

    func makeUIViewController(context: Context) -> Controller {
        Controller(content: content(), onDragEnded: onDragEnded)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.host.rootView = content()
        controller.onDragEnded = onDragEnded
    }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        let scrollView = UIScrollView()
        let host: UIHostingController<Content>
        var onDragEnded: ((CGSize, Bool, Bool) -> Bool)?
        private var startingBoundary: ScrollBoundaryState?

        init(content: Content, onDragEnded: @escaping (CGSize, Bool, Bool) -> Bool) {
            host = UIHostingController(rootView: content)
            self.onDragEnded = onDragEnded
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            scrollView.bounces = false
            scrollView.alwaysBounceVertical = false
            view.addSubview(scrollView)
            addChild(host)
            host.sizingOptions = .intrinsicContentSize
            host.view.backgroundColor = .clear
            host.view.translatesAutoresizingMaskIntoConstraints = false
            scrollView.addSubview(host.view)
            host.didMove(toParent: self)
            NSLayoutConstraint.activate([
                scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                scrollView.topAnchor.constraint(equalTo: view.topAnchor),
                scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                host.view.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
                host.view.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
                host.view.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
            ])
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.delegate = self
            pan.cancelsTouchesInView = false
            pan.maximumNumberOfTouches = 1
            // Attach to the viewport, so blank space below short text also accepts swipes.
            view.addGestureRecognizer(pan)
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: view)
            return abs(velocity.y) > abs(velocity.x)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            switch gesture.state {
            case .began:
                let top = -scrollView.adjustedContentInset.top
                let bottom = max(
                    top,
                    scrollView.contentSize.height - scrollView.bounds.height
                        + scrollView.adjustedContentInset.bottom
                )
                startingBoundary = ScrollBoundaryState(
                    isAtTop: scrollView.contentOffset.y <= top + 2,
                    isAtBottom: scrollView.contentOffset.y >= bottom - 2
                )
            case .ended:
                let boundary = startingBoundary
                startingBoundary = nil
                guard let boundary else { return }
                let translation = gesture.translation(in: scrollView)
                let didSwitch = onDragEnded?(
                    CGSize(width: translation.x, height: translation.y),
                    boundary.isAtTop,
                    boundary.isAtBottom
                ) ?? false
                if didSwitch {
                    // Do not carry the previous paragraph's fling into the new page.
                    scrollView.panGestureRecognizer.isEnabled = false
                    scrollView.panGestureRecognizer.isEnabled = true
                    scrollView.setContentOffset(
                        CGPoint(x: scrollView.contentOffset.x, y: -scrollView.adjustedContentInset.top),
                        animated: false
                    )
                }
            case .cancelled, .failed:
                startingBoundary = nil
            default:
                break
            }
        }
    }
}
#else
private struct ParagraphScrollContainer<Content: View>: View {
    let onDragEnded: (CGSize, Bool, Bool) -> Bool
    @ViewBuilder let content: () -> Content

    var body: some View { ScrollView { content() } }
}
#endif

private enum ScrollTarget: Hashable {
    case top
}

private enum ScrollCoordinateSpace {
    static let name = "paragraph-analysis-scroll"
}

private struct ScrollBoundaryState: Equatable {
    let isAtTop: Bool
    let isAtBottom: Bool
}

private struct ScrollContentFramePreferenceKey: PreferenceKey {
    static var defaultValue = CGRect.null

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

private extension View {
    @ViewBuilder
    func trackScrollBoundaries(
        viewportHeight: CGFloat,
        isAtTop: Binding<Bool>,
        isAtBottom: Binding<Bool>
    ) -> some View {
        if #available(iOS 18.0, *) {
            onScrollGeometryChange(for: ScrollBoundaryState.self) { geometry in
                ScrollBoundaryState(
                    isAtTop: geometry.visibleRect.minY <= 2,
                    isAtBottom: geometry.visibleRect.maxY >= geometry.contentSize.height - 2
                )
            } action: { _, boundaryState in
                isAtTop.wrappedValue = boundaryState.isAtTop
                isAtBottom.wrappedValue = boundaryState.isAtBottom
            }
        } else {
            onPreferenceChange(ScrollContentFramePreferenceKey.self) { contentFrame in
                guard !contentFrame.isNull else { return }
                isAtTop.wrappedValue = contentFrame.minY >= -2
                isAtBottom.wrappedValue = contentFrame.maxY <= viewportHeight + 2
            }
        }
    }
}

private enum TokenPresentation: Identifiable {
    case dictionary(term: String)

    var term: String {
        switch self {
        case .dictionary(let term):
            return term
        }
    }

    var id: String {
        switch self {
        case .dictionary(let term):
            return "dictionary-\(term)"
        }
    }

    static func forToken(_ token: ReaderToken) -> Self {
        switch token.partOfSpeech {
        case .noun, .verb, .adjective:
            return .dictionary(term: token.dictionaryLookupTerm)
        default:
            return .dictionary(term: token.surface)
        }
    }
}

#if canImport(UIKit)
private struct AnalysisTokensWebView: UIViewRepresentable {
    let tokens: [ReaderToken]
    let fontScale: Double
    let highlightedRange: NSRange?
    @Binding var contentHeight: CGFloat
    let onSelectToken: (ReaderToken) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            tokens: tokens,
            contentHeight: $contentHeight,
            onSelectToken: onSelectToken
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: Coordinator.selectHandlerName)

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.backgroundColor = .clear
        webView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        webView.setContentHuggingPriority(.required, for: .vertical)
        webView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        webView.setContentCompressionResistancePriority(.required, for: .vertical)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onSelectToken = onSelectToken
        context.coordinator.highlightedRange = highlightedRange
        let scale = min(max(fontScale, 0.7), 2.2)
        guard context.coordinator.renderedFontScale != scale || context.coordinator.tokens != tokens else {
            context.coordinator.applyHighlight(in: webView)
            return
        }
        context.coordinator.tokens = tokens
        context.coordinator.renderedFontScale = scale
        context.coordinator.isDocumentReady = false
        context.coordinator.appliedHighlight = nil
        webView.loadHTMLString(Self.documentHTML(for: tokens, fontScale: scale), baseURL: nil)
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.navigationDelegate = nil
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.selectHandlerName)
        uiView.stopLoading()
    }

    private static func documentHTML(for tokens: [ReaderToken], fontScale: Double) -> String {
        let clampedScale = min(max(fontScale, 0.7), 2.2)
        let baseFontSize = 17.0 * clampedScale
        let rubyFontSize = 10.0 * clampedScale
        let tokenBottomSpacing = 14.0 * clampedScale
        let tokenTrailingSpacing = 6.0
        let plainTopPadding = 0.95 * baseFontSize

        var utf16Offset = 0
        let tokenHTML = tokens.enumerated().map { index, token in
            let tokenClasses = "token \(token.hasRuby ? "has-ruby" : "plain-token")"
            let lineClass = token.isInteractive ? "token-line" : "token-line token-line-static"
            let startOffset = utf16Offset
            utf16Offset += token.surface.utf16.count
            let endOffset = utf16Offset

            if token.isInteractive {
                let label = "\(token.surface) \(token.reading ?? "")".trimmingCharacters(in: .whitespaces)
                return """
                <button class="\(tokenClasses)" type="button" data-index="\(index)" data-start="\(startOffset)" data-end="\(endOffset)" aria-label="\(label.htmlEscaped)">
                  <span class="\(lineClass)" style="--token-color: \(token.partOfSpeech.cssColor);">\(token.rubyHTML)</span>
                </button>
                """
            }

            return """
            <span class="\(tokenClasses)" data-start="\(startOffset)" data-end="\(endOffset)" aria-hidden="true">
              <span class="\(lineClass)" style="--token-color: \(token.partOfSpeech.cssColor);">\(token.rubyHTML)</span>
            </span>
            """
        }.joined(separator: "\n")

        return """
        <!doctype html>
        <html lang="ja">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
          <style>
            :root {
              color-scheme: light dark;
            }
            html, body {
              margin: 0;
              padding: 0;
              background: transparent;
            }
            body {
              color: rgb(28, 28, 30);
              font-family: -apple-system, BlinkMacSystemFont, "Hiragino Mincho ProN", "YuMincho", serif;
              font-size: \(baseFontSize.cssNumber)px;
              font-weight: 600;
              line-height: 1.25;
              -webkit-text-size-adjust: 100%;
              text-rendering: optimizeLegibility;
            }
            #tokens {
              width: 100%;
              font-size: 0;
            }
            .token {
              display: inline-block;
              vertical-align: baseline;
              border: 0;
              background: transparent;
              padding: 0 1px;
              margin: 0 \(tokenTrailingSpacing.cssNumber)px \(tokenBottomSpacing.cssNumber)px 0;
              color: inherit;
              font: inherit;
              text-align: left;
              cursor: pointer;
              appearance: none;
              -webkit-appearance: none;
              -webkit-tap-highlight-color: transparent;
              line-height: 1.25;
            }
            .token-line {
              display: inline-block;
              padding-bottom: 3px;
              border-bottom: 2px dotted var(--token-color);
              white-space: nowrap;
              font-size: \(baseFontSize.cssNumber)px;
            }
            .token-line-static {
              border-bottom: 0;
            }
            .token.is-speaking .token-line {
              border-radius: 7px;
              background: color-mix(in srgb, #ffcc33 58%, transparent);
              box-shadow: 0 0 0 3px color-mix(in srgb, #ffcc33 22%, transparent);
            }
            ruby {
              ruby-position: over;
              ruby-align: center;
              ruby-overhang: auto;
            }
            .plain-token {
              padding-top: \(plainTopPadding.cssNumber)px;
            }
            rt {
              font-size: \(rubyFontSize.cssNumber)px;
              font-weight: 500;
              line-height: 1;
              color: rgba(60, 60, 67, 0.72);
              user-select: none;
              -webkit-user-select: none;
            }
          </style>
        </head>
        <body>
          <div id="tokens">\(tokenHTML)</div>
          <script>
            (() => {
              const handler = window.webkit?.messageHandlers?.\(Coordinator.selectHandlerName.jsIdentifier);
              const tokens = Array.from(document.querySelectorAll('.token'));
              const starts = tokens.map(token => Number(token.dataset.start));
              const ends = tokens.map(token => Number(token.dataset.end));
              let highlighted = [];
              window.yomiHighlightRange = (start, length) => {
                const lower = Number(start) || 0;
                const upper = lower + (Number(length) || 0);
                // Token offsets are ordered. Find the first overlap without scanning the paragraph.
                let lo = 0, hi = tokens.length;
                while (lo < hi) {
                  const mid = (lo + hi) >>> 1;
                  if (ends[mid] <= lower) lo = mid + 1;
                  else hi = mid;
                }
                const next = [];
                if (upper > lower) {
                  for (let i = lo; i < tokens.length && starts[i] < upper; i++) next.push(i);
                }
                const nextSet = new Set(next);
                const previousSet = new Set(highlighted);
                highlighted.forEach(i => { if (!nextSet.has(i)) tokens[i].classList.remove('is-speaking'); });
                next.forEach(i => { if (!previousSet.has(i)) tokens[i].classList.add('is-speaking'); });
                highlighted = next;
              };
              const reportHeight = () => {
                const root = document.documentElement;
                const body = document.body;
                const height = Math.max(root.scrollHeight, body.scrollHeight, root.offsetHeight, body.offsetHeight);
                document.title = String(height);
              };
              document.querySelectorAll('.token').forEach(button => {
                button.addEventListener('click', event => {
                  event.preventDefault();
                  const value = Number(button.dataset.index);
                  if (handler && Number.isFinite(value)) {
                    handler.postMessage(value);
                  }
                });
              });
              reportHeight();
              window.addEventListener('load', reportHeight, { once: true });
              if (document.fonts?.ready) {
                document.fonts.ready.then(reportHeight).catch(() => {});
              }
              new ResizeObserver(reportHeight).observe(document.body);
            })();
          </script>
        </body>
        </html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let selectHandlerName = "yomiSelectToken"

        var tokens: [ReaderToken]
        @Binding var contentHeight: CGFloat
        var onSelectToken: (ReaderToken) -> Void
        var renderedFontScale: Double?
        var isDocumentReady = false
        var appliedHighlight: NSRange?
        var highlightedRange: NSRange?

        init(
            tokens: [ReaderToken],
            contentHeight: Binding<CGFloat>,
            onSelectToken: @escaping (ReaderToken) -> Void
        ) {
            self.tokens = tokens
            _contentHeight = contentHeight
            self.onSelectToken = onSelectToken
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isDocumentReady = true
            updateHeight(from: webView)
            applyHighlight(in: webView)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            updateHeight(from: webView)
        }

        func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
            updateHeight(from: webView)
        }

        func webView(_ webView: WKWebView, didReceive message: WKScriptMessage) {
            userContentController(webView.configuration.userContentController, didReceive: message)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard
                message.name == Self.selectHandlerName,
                let index = message.body as? Int,
                tokens.indices.contains(index)
            else {
                return
            }

            onSelectToken(tokens[index])
        }

        private func updateHeight(from webView: WKWebView) {
            webView.evaluateJavaScript("document.title") { [weak self] result, _ in
                guard
                    let self,
                    let title = result as? String,
                    let value = Double(title)
                else {
                    return
                }

                let height = CGFloat(value)
                DispatchQueue.main.async {
                    if abs(self.contentHeight - height) > 0.5 {
                        self.contentHeight = max(height, 1)
                    }
                }
            }
        }

        func applyHighlight(in webView: WKWebView) {
            guard isDocumentReady else { return }
            let range = highlightedRange ?? NSRange(location: 0, length: 0)
            guard appliedHighlight != range else { return }
            appliedHighlight = range
            webView.evaluateJavaScript(
                "window.yomiHighlightRange?.(\(range.location), \(range.length));"
            )
        }
    }
}

private extension String {
    var jsIdentifier: String {
        filter { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}

private extension Double {
    var cssNumber: String {
        String(format: "%.2f", self)
    }
}
#endif

private struct TokenDisplaySegment: Hashable {
    let surface: String
    let reading: String?

    var html: String {
        if let reading, !reading.isEmpty {
            return #"<ruby><rb>"#
                + surface.htmlEscaped
                + #"</rb><rt>"#
                + reading.htmlEscaped
                + "</rt></ruby>"
        }

        return surface.htmlEscaped
    }
}

private struct TokenPresentationSheet: View {
    let presentation: TokenPresentation

    var body: some View {
        switch presentation {
        case .dictionary(let term):
            DictionaryLookupView(term: term)
        }
    }
}

#if canImport(UIKit)
private struct DictionaryLookupView: UIViewControllerRepresentable {
    let term: String

    func makeUIViewController(context: Context) -> UIReferenceLibraryViewController {
        UIReferenceLibraryViewController(term: term)
    }

    func updateUIViewController(_ uiViewController: UIReferenceLibraryViewController, context: Context) {}
}
#endif

private extension ReaderToken {
    var isInteractive: Bool {
        partOfSpeech != .symbol
    }

    var dictionaryLookupTerm: String {
        dictionaryForm ?? surface
    }

    var displaySegments: [TokenDisplaySegment] {
        guard
            let reading,
            !reading.isEmpty,
            surface.containsKanji
        else {
            return [TokenDisplaySegment(surface: surface, reading: nil)]
        }

        if surface.allSatisfy(\.isKanjiLike) {
            return [TokenDisplaySegment(surface: surface, reading: reading)]
        }

        guard let segments = ParagraphRubyAlignment.align(surface: Array(surface), reading: Array(reading)) else {
            return [TokenDisplaySegment(surface: surface, reading: nil)]
        }

        return segments.map { TokenDisplaySegment(surface: $0.surface, reading: $0.reading) }
    }

    var rubyHTML: String {
        displaySegments.map(\.html).joined()
    }

    var hasRuby: Bool {
        displaySegments.contains { segment in
            guard let reading = segment.reading else { return false }
            return !reading.isEmpty
        }
    }
}

private enum ParagraphRubyAlignment {
    static func align(surface: [Character], reading: [Character]) -> [TokenDisplaySegment]? {
        guard !surface.isEmpty else {
            return reading.isEmpty ? [] : nil
        }

        if surface.allSatisfy(\.isKanjiLike) {
            guard !reading.isEmpty else { return nil }
            return [TokenDisplaySegment(surface: String(surface), reading: String(reading))]
        }

        let first = surface[0]
        if first.isKanaLike {
            guard !reading.isEmpty, first.matchesKana(reading[0]) else {
                return nil
            }

            guard let suffix = align(surface: Array(surface.dropFirst()), reading: Array(reading.dropFirst())) else {
                return nil
            }
            return [TokenDisplaySegment(surface: String(first), reading: nil)] + suffix
        }

        var anchorStart: Int?
        for index in surface.indices where surface[index].isKanaLike {
            anchorStart = index
            break
        }

        guard let anchorStart else {
            guard !reading.isEmpty else { return nil }
            return [TokenDisplaySegment(surface: String(surface), reading: String(reading))]
        }

        var anchorEnd = anchorStart
        while anchorEnd < surface.count, surface[anchorEnd].isKanaLike {
            anchorEnd += 1
        }

        let kanjiPrefix = String(surface[..<anchorStart])
        let anchor = Array(surface[anchorStart..<anchorEnd])
        let suffixSurface = Array(surface[anchorEnd...])

        for matchStart in reading.indices where matchStart + anchor.count <= reading.count {
            let readingAnchor = Array(reading[matchStart..<(matchStart + anchor.count)])
            guard kanaSlicesMatch(anchor, readingAnchor) else {
                continue
            }

            let rubyReading = String(reading[..<matchStart])
            guard !rubyReading.isEmpty else {
                continue
            }

            guard let suffix = align(surface: suffixSurface, reading: Array(reading[(matchStart + anchor.count)...])) else {
                continue
            }

            return [TokenDisplaySegment(surface: kanjiPrefix, reading: rubyReading), TokenDisplaySegment(surface: String(anchor), reading: nil)] + suffix
        }

        return nil
    }

    private static func kanaSlicesMatch(_ lhs: [Character], _ rhs: [Character]) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }

        return zip(lhs, rhs).allSatisfy { $0.matchesKana($1) }
    }
}

private extension ReaderPartOfSpeech {
    var cssColor: String {
        switch self {
        case .noun:
            return "#f2c94c"
        case .verb:
            return "#4caf50"
        case .particle:
            return "#56ccf2"
        case .adjective:
            return "#ff6b9a"
        case .adverb:
            return "#9b51e0"
        case .prefix:
            return "#f2994a"
        case .symbol:
            return "#8e8e93"
        case .other:
            return "#2f80ed"
        }
    }
}

private extension String {
    var containsKanji: Bool {
        unicodeScalars.contains(where: \.isKanji)
    }

    var htmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

private extension Character {
    var isKanaLike: Bool {
        unicodeScalars.allSatisfy { $0.isHiragana || $0.isKatakana }
    }

    var isKanjiLike: Bool {
        unicodeScalars.contains(where: \.isKanji)
    }

    func matchesKana(_ other: Character) -> Bool {
        normalizedKana == other.normalizedKana
    }

    private var normalizedKana: String {
        String(String(self).applyingTransform(.hiraganaToKatakana, reverse: true) ?? String(self))
    }
}

private extension UnicodeScalar {
    var isKanji: Bool {
        (0x3400...0x4DBF).contains(value)
            || (0x4E00...0x9FFF).contains(value)
            || (0xF900...0xFAFF).contains(value)
    }

    var isHiragana: Bool {
        (0x3040...0x309F).contains(value)
    }

    var isKatakana: Bool {
        (0x30A0...0x30FF).contains(value)
            || (0x31F0...0x31FF).contains(value)
            || (0xFF66...0xFF9F).contains(value)
    }
}
