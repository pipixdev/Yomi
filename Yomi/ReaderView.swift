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
    let bookID: UUID

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: LibraryStore
    @AppStorage("reader.fontScale") private var fontScale = 1.0

    @State private var isFontPanelVisible = false
    @State private var isNavigatorVisible = false
    @State private var hasPerformedInitialScroll = false
    @State private var currentLocation: ReaderLocation?
    @State private var pendingJumpLocation: ReaderLocation?

    private var book: BookRecord? {
        store.book(id: bookID)
    }

    var body: some View {
        Group {
            if let book {
                readerBody(for: book)
            } else {
                ContentUnavailableView(
                    "Book unavailable",
                    systemImage: "book.closed",
                    description: Text("This book may have been removed from your library.")
                )
            }
        }
        .preferredColorScheme(.dark)
        .tint(Color(red: 0.36, green: 0.87, blue: 0.56))
        .sheet(isPresented: $isNavigatorVisible) {
            if let book {
                ReaderNavigatorSheet(
                    book: book,
                    currentLocation: currentLocation ?? book.effectiveProgress,
                    onSelect: { location in
                        pendingJumpLocation = location
                    }
                )
                .presentationDetents([.medium, .large])
            }
        }
    }

    private func readerBody(for book: BookRecord) -> some View {
        ScrollViewReader { proxy in
            NavigationStack {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 30) {
                        ForEach(Array(book.chapters.enumerated()), id: \.element.id) { chapterIndex, chapter in
                            VStack(alignment: .leading, spacing: 18) {
                                chapterHeader(chapter: chapter, chapterIndex: chapterIndex, totalChapters: book.chapters.count)

                                ForEach(Array(chapter.paragraphs.enumerated()), id: \.element.id) { paragraphIndex, paragraph in
                                    ParagraphContainerView(
                                        chapter: chapter,
                                        paragraph: paragraph,
                                        paragraphIndex: paragraphIndex,
                                        fontScale: fontScale
                                    )
                                    .id(paragraph.id)
                                    .padding(.horizontal, 20)
                                    .onAppear {
                                        syncVisibleLocation(
                                            ReaderLocation(
                                                chapterID: chapter.id,
                                                paragraphID: paragraph.id,
                                                updatedAt: .now
                                            ),
                                            for: book
                                        )
                                    }
                                }
                            }
                            .padding(.top, chapterIndex == 0 ? 8 : 18)
                        }
                    }
                    .padding(.vertical, 22)
                }
                .background(Color.black)
                .safeAreaInset(edge: .bottom) {
                    bottomControlBar(book: book, proxy: proxy)
                }
#if !os(macOS)
                .safeAreaInset(edge: .top) {
                    topBar(book: book)
                }
#endif
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
                        topActionButtons(book: book)
                    }
#endif
                }
                .task(id: book.id) {
                    guard !hasPerformedInitialScroll else { return }
                    let target = currentLocation ?? book.effectiveProgress ?? book.firstLocation
                    currentLocation = target
                    if let target {
                        await scroll(to: target, proxy: proxy, animated: false)
                    }
                    hasPerformedInitialScroll = true
                }
                .onChange(of: currentLocation) { _, newValue in
                    guard let newValue else { return }
                    store.updateProgress(for: book.id, location: newValue)
                }
                .onChange(of: pendingJumpLocation) { _, newValue in
                    guard let newValue else { return }
                    Task {
                        await scroll(to: newValue, proxy: proxy, animated: true)
                        pendingJumpLocation = nil
                    }
                }
            }
        }
    }

    private func chapterHeader(chapter: BookChapter, chapterIndex: Int, totalChapters: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Chapter \(chapterIndex + 1) / \(totalChapters)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.55))

            Text(chapter.title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white.opacity(0.96))
        }
        .padding(.horizontal, 20)
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
    private func topBar(book: BookRecord) -> some View {
        HStack {
            closeButton
            Spacer()
            topActionButtons(book: book)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .background(Color.black)
    }
#endif

    private func topActionButtons(book: BookRecord) -> some View {
        HStack(spacing: 14) {
            Button {
                isNavigatorVisible = true
            } label: {
                Image(systemName: "list.bullet.rectangle.portrait")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color(red: 0.30, green: 0.86, blue: 0.53))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open Navigator")

            if let epubURL = store.epubURL(for: book) {
                ShareLink(item: epubURL) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Color(red: 0.30, green: 0.86, blue: 0.53))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Share EPUB")
            }

            bookmarkButton(book: book)
        }
    }

    private func bookmarkButton(book: BookRecord) -> some View {
        let location = currentLocation ?? book.effectiveProgress
        let isBookmarked = location.flatMap(book.bookmark(for:)) != nil

        return Button {
            guard let location else { return }
            store.toggleBookmark(
                for: book.id,
                location: location,
                title: bookmarkTitle(in: book, for: location)
            )
        } label: {
            Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color(red: 0.30, green: 0.86, blue: 0.53))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Toggle Bookmark")
    }

    private func bottomControlBar(book: BookRecord, proxy: ScrollViewProxy) -> some View {
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

            VStack(spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(book.title)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        Text(readingSummary(book: book))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }

                    Spacer()

                    Button {
                        jumpToAdjacentChapter(in: book, direction: -1, proxy: proxy)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(previousChapterLocation(in: book) == nil)

                    Button {
                        jumpToAdjacentChapter(in: book, direction: 1, proxy: proxy)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(nextChapterLocation(in: book) == nil)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.white)

                if let chapter = currentChapter(in: book), chapter.paragraphs.count > 1 {
                    VStack(spacing: 6) {
                        HStack {
                            Text(chapter.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.82))
                                .lineLimit(1)
                            Spacer()
                            Text(paragraphProgressText(in: book, chapter: chapter))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.62))
                        }

                        Slider(
                            value: Binding(
                                get: { Double(currentParagraphIndex(in: book, chapter: chapter) ?? 0) },
                                set: { newValue in
                                    let targetIndex = Int(newValue.rounded())
                                    guard chapter.paragraphs.indices.contains(targetIndex) else { return }
                                    let target = ReaderLocation(
                                        chapterID: chapter.id,
                                        paragraphID: chapter.paragraphs[targetIndex].id,
                                        updatedAt: .now
                                    )
                                    Task {
                                        await scroll(to: target, proxy: proxy, animated: true)
                                    }
                                }
                            ),
                            in: 0 ... Double(chapter.paragraphs.count - 1),
                            step: 1
                        )
                        .tint(Color(red: 0.39, green: 0.80, blue: 0.98))
                    }
                }

                HStack(spacing: 8) {
                    controlButton(title: "词性标记", icon: "checkmark.seal.fill", isActive: true) {}
                        .allowsHitTesting(false)

                    controlButton(title: "目录", icon: "list.bullet", isActive: isNavigatorVisible) {
                        isNavigatorVisible = true
                    }

                    controlButton(title: "字体大小", icon: "textformat", isActive: isFontPanelVisible) {
                        isFontPanelVisible.toggle()
                    }
                }
            }
            .padding(12)
            .background(Color(red: 0.15, green: 0.15, blue: 0.16), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.black.opacity(0.92))
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

    private func syncVisibleLocation(_ location: ReaderLocation, for book: BookRecord) {
        guard book.contains(location: location) else { return }
        if let currentLocation,
           currentLocation.chapterID == location.chapterID,
           currentLocation.paragraphID == location.paragraphID {
            return
        }
        currentLocation = location
    }

    private func currentChapter(in book: BookRecord) -> BookChapter? {
        guard let location = currentLocation ?? book.effectiveProgress else { return book.chapters.first }
        return book.chapter(for: location)
    }

    private func currentParagraphIndex(in book: BookRecord, chapter: BookChapter) -> Int? {
        let location = currentLocation ?? book.effectiveProgress
        guard let location, location.chapterID == chapter.id else { return 0 }
        return chapter.paragraphs.firstIndex { $0.id == location.paragraphID } ?? 0
    }

    private func paragraphProgressText(in book: BookRecord, chapter: BookChapter) -> String {
        let currentParagraph = (currentParagraphIndex(in: book, chapter: chapter) ?? 0) + 1
        return "\(currentParagraph) / \(chapter.paragraphs.count)"
    }

    private func readingSummary(book: BookRecord) -> String {
        guard
            let location = currentLocation ?? book.effectiveProgress,
            let chapterIndex = book.chapterIndex(for: location.chapterID),
            let chapter = book.chapter(for: location)
        else {
            return "未开始"
        }

        let paragraphIndex = chapter.paragraphs.firstIndex { $0.id == location.paragraphID } ?? 0
        return "第 \(chapterIndex + 1) 章 · 段落 \(paragraphIndex + 1)"
    }

    private func bookmarkTitle(in book: BookRecord, for location: ReaderLocation) -> String {
        let chapterTitle = book.chapter(for: location)?.title ?? book.title
        let paragraphText = book.chapter(for: location)?
            .paragraphs
            .first(where: { $0.id == location.paragraphID })?
            .text ?? chapterTitle
        let trimmedParagraph = String(paragraphText.prefix(24))
        return "\(chapterTitle) · \(trimmedParagraph)"
    }

    private func previousChapterLocation(in book: BookRecord) -> ReaderLocation? {
        adjacentChapterLocation(in: book, direction: -1)
    }

    private func nextChapterLocation(in book: BookRecord) -> ReaderLocation? {
        adjacentChapterLocation(in: book, direction: 1)
    }

    private func adjacentChapterLocation(in book: BookRecord, direction: Int) -> ReaderLocation? {
        guard
            let currentLocation = currentLocation ?? book.effectiveProgress,
            let currentChapterIndex = book.chapterIndex(for: currentLocation.chapterID)
        else {
            return book.firstLocation
        }

        let targetIndex = currentChapterIndex + direction
        guard book.chapters.indices.contains(targetIndex), let paragraph = book.chapters[targetIndex].paragraphs.first else {
            return nil
        }

        return ReaderLocation(
            chapterID: book.chapters[targetIndex].id,
            paragraphID: paragraph.id,
            updatedAt: .now
        )
    }

    private func jumpToAdjacentChapter(in book: BookRecord, direction: Int, proxy: ScrollViewProxy) {
        guard let location = adjacentChapterLocation(in: book, direction: direction) else { return }
        Task {
            await scroll(to: location, proxy: proxy, animated: true)
        }
    }

    @MainActor
    private func scroll(to location: ReaderLocation, proxy: ScrollViewProxy, animated: Bool) async {
        currentLocation = location
        let operation = {
            proxy.scrollTo(location.paragraphID, anchor: .top)
        }

        if animated {
            withAnimation(.easeInOut(duration: 0.2), operation)
        } else {
            operation()
        }
    }
}

private struct ReaderNavigatorSheet: View {
    let book: BookRecord
    let currentLocation: ReaderLocation?
    let onSelect: (ReaderLocation) -> Void

    @Environment(\.dismiss) private var dismiss

    private struct FlattenedPoint: Identifiable {
        let id: String
        let point: BookNavigationPoint
        let indent: Int
    }

    private var currentChapter: BookChapter? {
        guard let currentLocation else { return book.chapters.first }
        return book.chapter(for: currentLocation)
    }

    private var flattenedContents: [FlattenedPoint] {
        flatten(book.tableOfContents)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("目录") {
                    if flattenedContents.isEmpty {
                        Text("暂无目录")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(flattenedContents) { item in
                            Button {
                                select(
                                    ReaderLocation(
                                        chapterID: item.point.chapterID,
                                        paragraphID: item.point.paragraphID ?? book.chapter(for: item.point.chapterID)?.paragraphs.first?.id ?? "",
                                        updatedAt: .now
                                    )
                                )
                            } label: {
                                HStack {
                                    Text(item.point.title)
                                        .padding(.leading, CGFloat(item.indent) * 12)
                                    Spacer()
                                    if currentLocation?.chapterID == item.point.chapterID {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }

                if let currentChapter {
                    Section("当前章节段落") {
                        ForEach(Array(currentChapter.paragraphs.enumerated()), id: \.element.id) { index, paragraph in
                            Button {
                                select(
                                    ReaderLocation(
                                        chapterID: currentChapter.id,
                                        paragraphID: paragraph.id,
                                        updatedAt: .now
                                    )
                                )
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("段落 \(index + 1)")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text(paragraph.text)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                }

                Section("书签") {
                    if book.bookmarks.isEmpty {
                        Text("还没有书签")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(book.bookmarks) { bookmark in
                            Button {
                                select(
                                    ReaderLocation(
                                        chapterID: bookmark.chapterID,
                                        paragraphID: bookmark.paragraphID,
                                        updatedAt: .now
                                    )
                                )
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(bookmark.title)
                                        .lineLimit(2)
                                    Text(bookmark.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("导航")
        }
    }

    private func flatten(_ points: [BookNavigationPoint], indent: Int = 0) -> [FlattenedPoint] {
        points.flatMap { point in
            [FlattenedPoint(id: point.id, point: point, indent: indent)] + flatten(point.children, indent: indent + 1)
        }
    }

    private func select(_ location: ReaderLocation) {
        guard !location.paragraphID.isEmpty else { return }
        onSelect(location)
        dismiss()
    }
}

private struct ParagraphContainerView: View {
    let chapter: BookChapter
    let paragraph: BookParagraph
    let paragraphIndex: Int
    let fontScale: Double

    @State private var tokens: [ReaderToken] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if paragraph.role == .heading {
                Text(paragraph.text)
                    .font(.system(size: 26 * fontScale, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.bottom, 2)
            } else if paragraph.role == .separator {
                Text(paragraph.text)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white.opacity(0.82))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else {
                ParagraphView(tokens: tokens, fontScale: fontScale)
            }

            HStack {
                Text("\(chapter.title) · \(paragraphIndex + 1)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.35))
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: paragraph.id) {
            guard paragraph.role != .heading, paragraph.role != .separator else { return }
            tokens = ReaderTokenCache.shared.tokens(for: paragraph.text)
        }
    }
}

private struct ParagraphView: View {
    let tokens: [ReaderToken]
    let fontScale: Double

    var body: some View {
        FlowLayout(spacing: 2, rowSpacing: 10) {
            ForEach(tokens) { token in
                TokenView(
                    token: token,
                    fontScale: fontScale
                )
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

    private var surfaceFontSize: CGFloat {
        28 * fontScale
    }

    private var rubyFontSize: CGFloat {
        max(10, 11 * fontScale)
    }

    private var tokenWidth: CGFloat {
        TextWidthMeasurer.width(
            of: token.surface,
            font: PlatformFont.systemFont(ofSize: surfaceFontSize, weight: .bold)
        )
    }

    private var rubyTracking: CGFloat {
        guard let reading = token.reading, reading.count > 1 else { return 0 }

        let rubyWidth = TextWidthMeasurer.width(
            of: reading,
            font: PlatformFont.systemFont(ofSize: rubyFontSize, weight: .medium)
        )
        let availableSpacing = tokenWidth - rubyWidth
        guard availableSpacing > 0 else { return 0 }

        return min(availableSpacing / CGFloat(reading.count - 1), 7)
    }

    var body: some View {
        VStack(alignment: .center, spacing: 2) {
            Text(token.reading ?? " ")
                .font(.system(size: rubyFontSize, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.60))
                .tracking(rubyTracking)
                .lineLimit(1)
                .opacity(token.reading != nil && token.partOfSpeech != .symbol ? 1 : 0)
                .frame(height: rubyLineHeight, alignment: .bottom)

            Text(token.surface)
                .font(.system(size: surfaceFontSize, weight: .bold))
                .foregroundStyle(.white.opacity(0.97))
                .overlay(alignment: .bottom) {
                    if token.partOfSpeech != .symbol {
                        Capsule(style: .continuous)
                            .fill(token.partOfSpeech.accentColor.opacity(0.95))
                            .frame(height: 2.5)
                            .offset(y: 3)
                    }
                }
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

private final class ReaderTokenCache {
    static let shared = ReaderTokenCache()

    private let analyzer = JapaneseTextAnalyzer()
    private var cache: [String: [ReaderToken]] = [:]

    private init() {}

    func tokens(for text: String) -> [ReaderToken] {
        if let cached = cache[text] {
            return cached
        }

        let value = analyzer.tokens(for: text)
        cache[text] = value
        return value
    }
}
