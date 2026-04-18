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
    let tokens: [ReaderToken]

    @AppStorage("analysis.fontScale") private var analysisFontScale = 1.0
    @State private var activePresentation: TokenPresentation?
    @State private var contentHeight: CGFloat = 1

    var body: some View {
        ScrollView {
            if tokens.isEmpty {
                ContentUnavailableView(
                    String(localized: "No tokens found"),
                    systemImage: "text.word.spacing"
                )
                .padding(20)
            } else {
                tokenContent
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
            }
        }
        .navigationTitle(String(localized: "Parse"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $activePresentation) { presentation in
            TokenPresentationSheet(presentation: presentation)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var tokenContent: some View {
#if canImport(UIKit)
        AnalysisTokensWebView(
            tokens: tokens,
            fontScale: analysisFontScale,
            contentHeight: $contentHeight,
            onSelectToken: { token in
                activePresentation = .forToken(token)
            }
        )
        .frame(height: max(contentHeight, 1))
#else
        Text(tokens.map(\.surface).joined(separator: " "))
            .frame(maxWidth: .infinity, alignment: .leading)
#endif
    }
}

private enum TokenPresentation: Identifiable {
    case dictionary(term: String)

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
        context.coordinator.tokens = tokens
        context.coordinator.onSelectToken = onSelectToken
        let html = Self.documentHTML(for: tokens, fontScale: fontScale)
        guard context.coordinator.currentHTML != html else { return }
        context.coordinator.currentHTML = html
        webView.loadHTMLString(html, baseURL: nil)
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

        let tokenHTML = tokens.enumerated().map { index, token in
            let tokenClasses = "token \(token.hasRuby ? "has-ruby" : "plain-token")"
            let lineClass = token.isInteractive ? "token-line" : "token-line token-line-static"

            if token.isInteractive {
                let label = "\(token.surface) \(token.reading ?? "")".trimmingCharacters(in: .whitespaces)
                return """
                <button class="\(tokenClasses)" type="button" data-index="\(index)" aria-label="\(label.htmlEscaped)">
                  <span class="\(lineClass)" style="--token-color: \(token.partOfSpeech.cssColor);">\(token.rubyHTML)</span>
                </button>
                """
            }

            return """
            <span class="\(tokenClasses)" aria-hidden="true">
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
        var currentHTML = ""

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
            updateHeight(from: webView)
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
