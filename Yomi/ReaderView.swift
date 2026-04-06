//
//  ReaderView.swift
//  Yomi
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct ReaderView: View {
    let book: BookRecord

    @Environment(\.dismiss) private var dismiss
    @AppStorage("reader.fontScale") private var fontScale = 1.0

    @State private var isFontPanelVisible = false
    @State private var isBookmarked = true

    private let analyzer = JapaneseTextAnalyzer()

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 30) {
                    ForEach(book.chapters) { chapter in
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(Array(chapter.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                                ParagraphView(
                                    tokens: analyzer.tokens(for: paragraph),
                                    fontScale: fontScale
                                )
                                .padding(.horizontal, 20)
                            }
                        }
                        .padding(.top, 8)
                    }
                }
                .padding(.vertical, 22)
            }
            .safeAreaInset(edge: .bottom) {
                bottomControlBar
            }
#if !os(macOS)
            .safeAreaInset(edge: .top) {
                topBar
            }
#endif
            .background(Color.black)
            .navigationTitle("")
#if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
#if os(macOS)
                ToolbarItem {
                    closeButton
                }

                ToolbarItemGroup {
                    topActionButtons
                }
#endif
            }
        }
        .preferredColorScheme(.dark)
        .tint(Color(red: 0.36, green: 0.87, blue: 0.56))
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Color(red: 0.30, green: 0.86, blue: 0.53))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close Reader")
    }

#if !os(macOS)
    private var topBar: some View {
        HStack {
            closeButton
            Spacer()
            shareButton
            bookmarkButton
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .background(Color.black)
    }
#endif

    private var topActionButtons: some View {
        HStack {
            shareButton
            bookmarkButton
        }
    }

    private var shareButton: some View {
        ShareLink(item: book.title) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(Color(red: 0.30, green: 0.86, blue: 0.53))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Share")
    }

    private var bookmarkButton: some View {
        Button {
            isBookmarked.toggle()
        } label: {
            Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(Color(red: 0.30, green: 0.86, blue: 0.53))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Bookmark")
    }

    private var bottomControlBar: some View {
        VStack(spacing: 10) {
            if isFontPanelVisible {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("字体大小")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.9))
                        Spacer()
                        Text("\(Int(fontScale * 100))%")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.68))
                    }

                    Slider(value: $fontScale, in: 0.75 ... 1.4, step: 0.05)
                        .tint(Color(red: 0.39, green: 0.80, blue: 0.98))
                }
                .padding(14)
                .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            HStack(spacing: 8) {
                Label("词性标记", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .labelStyle(.titleAndIcon)
                    .padding(.vertical, 9)
                    .padding(.horizontal, 13)
                    .background(Color.white.opacity(0.18), in: Capsule())
                    .foregroundStyle(.white)

                controlButton(title: "字体大小", icon: "textformat", isActive: isFontPanelVisible) {
                    isFontPanelVisible.toggle()
                }
            }
            .padding(6)
            .background(Color(red: 0.15, green: 0.15, blue: 0.16), in: Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private func controlButton(title: String, icon: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 15, weight: .semibold))
                .labelStyle(.titleAndIcon)
                .padding(.vertical, 9)
                .padding(.horizontal, 13)
                .background(isActive ? Color.white.opacity(0.18) : .clear, in: Capsule())
                .foregroundStyle(.white.opacity(isActive ? 1 : 0.8))
        }
        .buttonStyle(.plain)
    }
}

private struct ParagraphView: View {
    let tokens: [ReaderToken]
    let fontScale: Double

    private var tokenSegments: [[ReaderToken]] {
        guard !tokens.isEmpty else { return [] }

        var result: [[ReaderToken]] = [[]]
        let hardBreakPunctuation: Set<String> = ["。", "！", "？", "!", "?"]
        let softBreakPunctuation: Set<String> = ["、", "，", ","]

        for token in tokens {
            if softBreakPunctuation.contains(token.surface), !result[result.count - 1].isEmpty {
                result.append([])
            }

            result[result.count - 1].append(token)

            if hardBreakPunctuation.contains(token.surface) {
                result.append([])
            }
        }

        return result.filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(tokenSegments.enumerated()), id: \.offset) { _, segment in
                FlowLayout(spacing: 8, rowSpacing: 14) {
                    ForEach(segment) { token in
                        TokenView(
                            token: token,
                            fontScale: fontScale
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TokenView: View {
    let token: ReaderToken
    let fontScale: Double

    private var rubyLineHeight: CGFloat {
        max(11, 12 * fontScale)
    }

    private var partOfSpeechLineHeight: CGFloat {
        max(11, 12 * fontScale)
    }

    private var surfaceFontSize: CGFloat {
        28 * fontScale
    }

    private var rubyFontSize: CGFloat {
        max(10, 11 * fontScale)
    }

    private var tokenBubbleWidth: CGFloat {
        let surfaceWidth = TextWidthMeasurer.width(
            of: token.surface,
            font: PlatformFont.systemFont(ofSize: surfaceFontSize, weight: .bold)
        )
        return surfaceWidth + 24
    }

    private var rubyTracking: CGFloat {
        guard let reading = token.reading, reading.count > 1 else { return 0 }

        let rubyWidth = TextWidthMeasurer.width(
            of: reading,
            font: PlatformFont.systemFont(ofSize: rubyFontSize, weight: .medium)
        )
        let availableSpacing = tokenBubbleWidth - rubyWidth
        guard availableSpacing > 0 else { return 0 }

        // Spread kana to fit the kanji token width without becoming unnatural.
        return min(availableSpacing / CGFloat(reading.count - 1), 7)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(token.reading ?? " ")
                .font(.system(size: rubyFontSize, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.60))
                .tracking(rubyTracking)
                .lineLimit(1)
                .opacity(token.reading != nil && token.partOfSpeech != .symbol ? 1 : 0)
                .frame(width: tokenBubbleWidth, alignment: .center)
                .frame(height: rubyLineHeight, alignment: .bottomLeading)

            Text(token.surface)
                .font(
                    .system(
                        size: surfaceFontSize,
                        weight: .bold
                    )
                )
                .foregroundStyle(.white.opacity(0.97))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color(red: 0.18, green: 0.19, blue: 0.21))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                }
                .overlay(alignment: .bottomLeading) {
                    if token.partOfSpeech != .symbol {
                        Capsule(style: .continuous)
                            .fill(token.partOfSpeech.accentColor.opacity(0.95))
                            .frame(height: 3)
                            .padding(.horizontal, 7)
                            .padding(.bottom, 4)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .frame(width: tokenBubbleWidth, alignment: .center)

            Text(token.partOfSpeech.label)
                .font(.system(size: max(10, 11 * fontScale), weight: .medium))
                .foregroundStyle(Color.white.opacity(0.72))
                .opacity(token.partOfSpeech == .symbol ? 0 : 1)
                .frame(height: partOfSpeechLineHeight, alignment: .topLeading)
        }
        .accessibilityElement(children: .combine)
    }
}

private extension ReaderPartOfSpeech {
    var accentColor: Color {
        switch self {
        case .noun:
            return Color(red: 0.30, green: 0.72, blue: 1.0)
        case .verb:
            return Color(red: 0.45, green: 0.89, blue: 0.52)
        case .particle:
            return Color(red: 0.98, green: 0.84, blue: 0.33)
        case .adjective:
            return Color(red: 0.98, green: 0.65, blue: 0.39)
        case .adverb:
            return Color(red: 0.81, green: 0.66, blue: 1.0)
        case .prefix:
            return Color(red: 0.45, green: 0.86, blue: 0.88)
        case .symbol:
            return Color.white.opacity(0.45)
        case .other:
            return Color.white.opacity(0.62)
        }
    }
}

#if canImport(UIKit)
private typealias PlatformFont = UIFont
#elseif canImport(AppKit)
private typealias PlatformFont = NSFont
#endif

private enum TextWidthMeasurer {
    static func width(of text: String, font: PlatformFont) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let measured = (text as NSString).size(withAttributes: attributes).width
        return ceil(measured)
    }
}
