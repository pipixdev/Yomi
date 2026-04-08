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
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var store: LibraryStore
    @AppStorage("reader.fontScale") private var fontScale = 1.0
    @AppStorage("reader.syntaxAnnotationsEnabled") private var isSyntaxAnnotationsEnabled = true
    @AppStorage("reader.rubyAnnotationsEnabled") private var isRubyAnnotationsEnabled = true

    @State private var isFontPanelVisible = false
    @State private var isNavigatorVisible = false
    @State private var hasPerformedInitialScroll = false
    @State private var currentLocation: ReaderLocation?
    @State private var pendingJumpLocation: ReaderLocation?
    @State private var currentPageIndex = 0

    private var book: BookRecord? {
        store.book(id: bookID)
    }

    private var pageBackgroundColor: Color {
        colorScheme == .dark ? .black : Color(red: 0.96, green: 0.97, blue: 0.99)
    }

    private var chromeBackgroundColor: Color {
        colorScheme == .dark ? .black.opacity(0.92) : Color.white.opacity(0.94)
    }

    private var controlCardBackgroundColor: Color {
        colorScheme == .dark ? Color(red: 0.15, green: 0.15, blue: 0.16) : Color.white
    }

    private var floatingPanelBackgroundColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06)
    }

    private var primaryTextColor: Color {
        colorScheme == .dark ? .white.opacity(0.97) : .black.opacity(0.88)
    }

    private var secondaryTextColor: Color {
        colorScheme == .dark ? .white.opacity(0.72) : .black.opacity(0.64)
    }

    private var tertiaryTextColor: Color {
        colorScheme == .dark ? .white.opacity(0.55) : .black.opacity(0.50)
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
        GeometryReader { geometry in
            let pages = ReaderPagination.pages(
                for: book,
                viewportSize: geometry.size,
                fontScale: fontScale,
                showsRubyAnnotations: isRubyAnnotationsEnabled
            )
            let effectivePageIndex = min(max(currentPageIndex, 0), max(pages.count - 1, 0))
            let currentPage = pages[safe: effectivePageIndex]

            NavigationStack {
                Group {
                    if let currentPage {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 18) {
                                if currentPage.showsChapterHeader,
                                   let chapter = book.chapters[safe: currentPage.chapterIndex] {
                                    chapterHeader(chapter: chapter, chapterIndex: currentPage.chapterIndex, totalChapters: book.chapters.count)
                                }

                                ForEach(currentPage.paragraphs) { paragraph in
                                    ParagraphContainerView(
                                        paragraph: paragraph,
                                        fontScale: fontScale,
                                        showsSyntaxAnnotations: isSyntaxAnnotationsEnabled,
                                        showsRubyAnnotations: isRubyAnnotationsEnabled
                                    )
                                    .padding(.horizontal, 20)
                                    .onAppear {
                                        syncVisibleLocation(
                                            ReaderLocation(
                                                chapterID: currentPage.chapterID,
                                                paragraphID: paragraph.id,
                                                updatedAt: .now
                                            ),
                                            for: book
                                        )
                                    }
                                }
                            }
                            .padding(.vertical, 22)
                        }
                        .id(currentPage.id)
                    } else {
                        ContentUnavailableView(
                            "Book unavailable",
                            systemImage: "book.closed",
                            description: Text("This book may have been removed from your library.")
                        )
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 24)
                        .onEnded { value in
                            guard abs(value.translation.width) > abs(value.translation.height),
                                  abs(value.translation.width) > 80 else { return }
                            if value.translation.width < 0 {
                                goToAdjacentPage(in: pages, direction: 1)
                            } else {
                                goToAdjacentPage(in: pages, direction: -1)
                            }
                        }
                )
                .background(pageBackgroundColor)
                .safeAreaInset(edge: .bottom) {
                    bottomControlBar(book: book, pages: pages)
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
                    if let target, let pageIndex = pageIndex(containing: target, pages: pages) {
                        currentPageIndex = pageIndex
                    }
                    hasPerformedInitialScroll = true
                }
                .onChange(of: fontScale) { _, _ in
                    clampCurrentPageIndex(to: pages)
                }
                .onChange(of: isRubyAnnotationsEnabled) { _, _ in
                    clampCurrentPageIndex(to: pages)
                }
                .onChange(of: currentLocation) { _, newValue in
                    guard let newValue else { return }
                    store.updateProgress(for: book.id, location: newValue)
                }
                .onChange(of: pendingJumpLocation) { _, newValue in
                    guard let newValue else { return }
                    if let pageIndex = pageIndex(containing: newValue, pages: pages) {
                        currentPageIndex = pageIndex
                        currentLocation = newValue
                    }
                    pendingJumpLocation = nil
                }
                .onChange(of: effectivePageIndex) { _, newValue in
                    guard let page = pages[safe: newValue] else { return }
                    currentLocation = ReaderLocation(
                        chapterID: page.chapterID,
                        paragraphID: page.startParagraphID,
                        updatedAt: .now
                    )
                }
            }
        }
    }

    private func chapterHeader(chapter: BookChapter, chapterIndex: Int, totalChapters: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(format: String(localized: "Chapter %lld / %lld"), chapterIndex + 1, totalChapters))
                .font(.caption.weight(.semibold))
                .foregroundStyle(tertiaryTextColor)

            Text(chapter.title)
                .font(.title3.weight(.bold))
                .foregroundStyle(primaryTextColor)
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
        .background(chromeBackgroundColor)
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

    private func bottomControlBar(book: BookRecord, pages: [ReaderPage]) -> some View {
        VStack(spacing: 10) {
            if isFontPanelVisible {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Font Size")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(primaryTextColor)
                        Spacer()
                        Text("\(Int(fontScale * 100))%")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(secondaryTextColor)
                    }

                    Slider(value: $fontScale, in: 0.5 ... 1.4, step: 0.05)
                        .tint(Color(red: 0.39, green: 0.80, blue: 0.98))
                }
                .padding(14)
                .background(floatingPanelBackgroundColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            VStack(spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(book.title)
                            .font(.headline)
                            .foregroundStyle(primaryTextColor)
                            .lineLimit(1)

                        Text(readingSummary(book: book))
                            .font(.caption)
                            .foregroundStyle(secondaryTextColor)
                    }

                    Spacer()

                    Button {
                        goToAdjacentPage(in: pages, direction: -1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(currentPageIndex <= 0)

                    Button {
                        goToAdjacentPage(in: pages, direction: 1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(currentPageIndex >= pages.count - 1)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(primaryTextColor)

                if !pages.isEmpty {
                    VStack(spacing: 6) {
                        HStack {
                            Text(currentPageTitle(in: book, pages: pages))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(secondaryTextColor)
                                .lineLimit(1)
                            Spacer()
                            Text(pageProgressText(pages: pages))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(tertiaryTextColor)
                        }

                        Slider(
                            value: Binding(
                                get: { Double(min(max(currentPageIndex, 0), max(pages.count - 1, 0))) },
                                set: { newValue in
                                    let targetIndex = Int(newValue.rounded())
                                    guard pages.indices.contains(targetIndex) else { return }
                                    currentPageIndex = targetIndex
                                }
                            ),
                            in: 0 ... Double(max(pages.count - 1, 0)),
                            step: 1
                        )
                        .tint(Color(red: 0.39, green: 0.80, blue: 0.98))
                    }
                }

                HStack(spacing: 8) {
                    controlIconButton(
                        icon: isRubyAnnotationsEnabled ? "textformat.superscript" : "textformat",
                        isActive: isRubyAnnotationsEnabled,
                        accessibilityLabel: "Ruby"
                    ) {
                        isRubyAnnotationsEnabled.toggle()
                    }

                    controlIconButton(
                        icon: isSyntaxAnnotationsEnabled ? "checkmark.seal.fill" : "checkmark.seal",
                        isActive: isSyntaxAnnotationsEnabled,
                        accessibilityLabel: String(localized: "Part-of-speech")
                    ) {
                        isSyntaxAnnotationsEnabled.toggle()
                    }

                    controlIconButton(
                        icon: "list.bullet",
                        isActive: isNavigatorVisible,
                        accessibilityLabel: String(localized: "Table of Contents")
                    ) {
                        isNavigatorVisible = true
                    }

                    controlIconButton(
                        icon: "textformat",
                        isActive: isFontPanelVisible,
                        accessibilityLabel: String(localized: "Font Size")
                    ) {
                        isFontPanelVisible.toggle()
                    }
                }
            }
            .padding(12)
            .background(controlCardBackgroundColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(chromeBackgroundColor)
    }

    private func controlIconButton(
        icon: String,
        isActive: Bool,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 38, height: 38)
                .background(isActive ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .foregroundStyle(isActive ? Color.accentColor : secondaryTextColor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
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

    private func readingSummary(book: BookRecord) -> String {
        guard
            let location = currentLocation ?? book.effectiveProgress,
            let chapterIndex = book.chapterIndex(for: location.chapterID),
            let chapter = book.chapter(for: location)
        else {
            return String(localized: "Not started")
        }

        let paragraphIndex = chapter.paragraphs.firstIndex { $0.id == location.paragraphID } ?? 0
        return String(
            format: String(localized: "Chapter %lld · Paragraph %lld"),
            chapterIndex + 1,
            paragraphIndex + 1
        )
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

    private func currentPageTitle(in book: BookRecord, pages: [ReaderPage]) -> String {
        guard let page = pages[safe: currentPageIndex],
              let chapter = book.chapters[safe: page.chapterIndex] else {
            return book.title
        }
        return chapter.title
    }

    private func pageProgressText(pages: [ReaderPage]) -> String {
        guard !pages.isEmpty else { return "0 / 0" }
        return "\(currentPageIndex + 1) / \(pages.count)"
    }

    private func goToAdjacentPage(in pages: [ReaderPage], direction: Int) {
        guard !pages.isEmpty else { return }
        currentPageIndex = min(max(currentPageIndex + direction, 0), pages.count - 1)
    }

    private func clampCurrentPageIndex(to pages: [ReaderPage]) {
        guard !pages.isEmpty else {
            currentPageIndex = 0
            return
        }
        currentPageIndex = min(max(currentPageIndex, 0), pages.count - 1)
    }

    private func pageIndex(containing location: ReaderLocation, pages: [ReaderPage]) -> Int? {
        pages.firstIndex { page in
            page.chapterID == location.chapterID && page.paragraphIDs.contains(location.paragraphID)
        }
    }
}

private struct ReaderPage: Identifiable, Hashable {
    let id: String
    let chapterIndex: Int
    let chapterID: String
    let paragraphs: [BookParagraph]
    let paragraphIDs: Set<String>
    let startParagraphID: String
    let showsChapterHeader: Bool
}

private enum ReaderPagination {
    static func pages(
        for book: BookRecord,
        viewportSize: CGSize,
        fontScale: Double,
        showsRubyAnnotations: Bool
    ) -> [ReaderPage] {
        let contentWidth = max(220, viewportSize.width - 40)
        let availableHeight = max(260, viewportSize.height - 250)
        var pages: [ReaderPage] = []

        for (chapterIndex, chapter) in book.chapters.enumerated() where !chapter.paragraphs.isEmpty {
            var currentParagraphs: [BookParagraph] = []
            var currentHeight: CGFloat = chapterIndex == 0 ? 92 : 108
            var pageNumberInChapter = 0

            for paragraph in chapter.paragraphs {
                let paragraphHeight = estimatedHeight(
                    for: paragraph,
                    contentWidth: contentWidth,
                    fontScale: fontScale,
                    showsRubyAnnotations: showsRubyAnnotations
                )
                let shouldStartNewPage = !currentParagraphs.isEmpty && currentHeight + paragraphHeight > availableHeight

                if shouldStartNewPage {
                    pages.append(
                        makePage(
                            chapterIndex: chapterIndex,
                            chapterID: chapter.id,
                            pageNumberInChapter: pageNumberInChapter,
                            paragraphs: currentParagraphs,
                            showsChapterHeader: pageNumberInChapter == 0
                        )
                    )
                    currentParagraphs = []
                    currentHeight = 24
                    pageNumberInChapter += 1
                }

                currentParagraphs.append(paragraph)
                currentHeight += paragraphHeight
            }

            if !currentParagraphs.isEmpty {
                pages.append(
                    makePage(
                        chapterIndex: chapterIndex,
                        chapterID: chapter.id,
                        pageNumberInChapter: pageNumberInChapter,
                        paragraphs: currentParagraphs,
                        showsChapterHeader: pageNumberInChapter == 0
                    )
                )
            }
        }

        return pages
    }

    private static func makePage(
        chapterIndex: Int,
        chapterID: String,
        pageNumberInChapter: Int,
        paragraphs: [BookParagraph],
        showsChapterHeader: Bool
    ) -> ReaderPage {
        ReaderPage(
            id: "\(chapterID)-page-\(pageNumberInChapter)-\(paragraphs.first?.id ?? "empty")",
            chapterIndex: chapterIndex,
            chapterID: chapterID,
            paragraphs: paragraphs,
            paragraphIDs: Set(paragraphs.map(\.id)),
            startParagraphID: paragraphs.first?.id ?? "",
            showsChapterHeader: showsChapterHeader
        )
    }

    private static func estimatedHeight(
        for paragraph: BookParagraph,
        contentWidth: CGFloat,
        fontScale: Double,
        showsRubyAnnotations: Bool
    ) -> CGFloat {
        switch paragraph.role {
        case .heading:
            let charsPerLine = max(6, Int(contentWidth / max(20, 18 * fontScale)))
            let lines = max(1, Int(ceil(Double(max(paragraph.text.count, 1)) / Double(charsPerLine))))
            return CGFloat(lines) * CGFloat(34 * fontScale) + 24
        case .separator:
            return 44
        case .quote, .body, .listItem:
            let charsPerLine = max(8, Int(contentWidth / max(14, 17 * fontScale)))
            let lines = max(1, Int(ceil(Double(max(paragraph.text.count, 1)) / Double(charsPerLine))))
            let lineHeight = CGFloat(30 * fontScale) + (showsRubyAnnotations ? CGFloat(14 * fontScale) : 0)
            return CGFloat(lines) * lineHeight + 18
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
                Section("Table of Contents") {
                    if flattenedContents.isEmpty {
                        Text("No table of contents")
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
                    Section("Current chapter paragraphs") {
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
                                    Text(String(format: String(localized: "Paragraph %lld"), index + 1))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text(paragraph.text)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                }

                Section("Bookmarks") {
                    if book.bookmarks.isEmpty {
                        Text("No bookmarks yet")
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
            .navigationTitle("Navigator")
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
    @Environment(\.colorScheme) private var colorScheme

    let paragraph: BookParagraph
    let fontScale: Double
    let showsSyntaxAnnotations: Bool
    let showsRubyAnnotations: Bool

    @State private var tokens: [ReaderToken] = []

    private var usesTokenLayout: Bool {
        paragraph.role != .heading && paragraph.role != .separator
    }

    private var primaryTextColor: Color {
        colorScheme == .dark ? .white.opacity(0.97) : .black.opacity(0.88)
    }

    private var secondaryTextColor: Color {
        colorScheme == .dark ? .white.opacity(0.82) : .black.opacity(0.70)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if paragraph.role == .heading {
                Text(paragraph.text)
                    .font(.system(size: 26 * fontScale, weight: .bold))
                    .foregroundStyle(primaryTextColor)
                    .padding(.bottom, 2)
            } else if paragraph.role == .separator {
                Text(paragraph.text)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(secondaryTextColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else {
                ParagraphView(
                    tokens: tokens,
                    fontScale: fontScale,
                    showsSyntaxAnnotations: showsSyntaxAnnotations,
                    showsRubyAnnotations: showsRubyAnnotations
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: paragraph.id) {
            guard usesTokenLayout else {
                tokens = []
                return
            }
            tokens = ReaderTokenCache.shared.tokens(for: paragraph.text)
        }
        .onDisappear {
            tokens = []
        }
        .accessibilityElement(children: usesTokenLayout ? .ignore : .combine)
        .accessibilityLabel(paragraph.text)
    }
}

private struct ParagraphView: View {
    let tokens: [ReaderToken]
    let fontScale: Double
    let showsSyntaxAnnotations: Bool
    let showsRubyAnnotations: Bool

    var body: some View {
        FlowLayout(spacing: showsSyntaxAnnotations ? 2 : 0, rowSpacing: 10) {
            ForEach(tokens) { token in
                TokenView(
                    token: token,
                    fontScale: fontScale,
                    showsSyntaxAnnotations: showsSyntaxAnnotations,
                    showsRubyAnnotations: showsRubyAnnotations
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TokenView: View {
    @Environment(\.colorScheme) private var colorScheme

    let token: ReaderToken
    let fontScale: Double
    let showsSyntaxAnnotations: Bool
    let showsRubyAnnotations: Bool

    private var rubyLineHeight: CGFloat {
        max(11, 12 * fontScale)
    }

    private var surfaceFontSize: CGFloat {
        28 * fontScale
    }

    private var rubyFontSize: CGFloat {
        max(10, 11 * fontScale)
    }

    private var rubyTextColor: Color {
        colorScheme == .dark ? .white.opacity(0.60) : .black.opacity(0.52)
    }

    private var surfaceTextColor: Color {
        colorScheme == .dark ? .white.opacity(0.97) : .black.opacity(0.88)
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
            if showsRubyAnnotations {
                Text(token.reading ?? " ")
                    .font(.system(size: rubyFontSize, weight: .medium))
                    .foregroundStyle(rubyTextColor)
                    .tracking(rubyTracking)
                    .lineLimit(1)
                    .opacity(token.reading != nil && token.partOfSpeech != .symbol ? 1 : 0)
                    .frame(height: rubyLineHeight, alignment: .bottom)
            }

            Text(token.surface)
                .font(.system(size: surfaceFontSize, weight: showsSyntaxAnnotations ? .bold : .semibold))
                .foregroundStyle(surfaceTextColor)
                .overlay(alignment: .bottom) {
                    if showsSyntaxAnnotations, token.partOfSpeech != .symbol {
                        Capsule(style: .continuous)
                            .fill(token.partOfSpeech.accentColor.opacity(0.95))
                            .frame(height: 2.5)
                            .offset(y: 3)
                    }
                }
        }
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
            return Color.gray.opacity(0.45)
        case .other:
            return Color.gray.opacity(0.62)
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

@MainActor
private final class ReaderTokenCache {
    static let shared = ReaderTokenCache()

    private let analyzer = JapaneseTextAnalyzer()
    private var cache: [String: CacheEntry] = [:]
    private var accessTick: UInt64 = 0

    // Keep only a window of recently viewed paragraphs instead of retaining
    // tokenized output for an entire novel.
    private let maxEntries = 180
    private let maxTokenCost = 18_000

    private var totalTokenCost = 0

    private init() {}

    func tokens(for text: String) -> [ReaderToken] {
        accessTick &+= 1

        if var cached = cache[text] {
            cached.lastAccess = accessTick
            cache[text] = cached
            return cached.tokens
        }

        let value = analyzer.tokens(for: text)
        let cost = max(1, value.count)
        cache[text] = CacheEntry(tokens: value, cost: cost, lastAccess: accessTick)
        totalTokenCost += cost
        trimIfNeeded()
        return value
    }

    private func trimIfNeeded() {
        guard cache.count > maxEntries || totalTokenCost > maxTokenCost else { return }

        let evictionOrder = cache
            .map { (key: $0.key, lastAccess: $0.value.lastAccess, cost: $0.value.cost) }
            .sorted { lhs, rhs in
                if lhs.lastAccess == rhs.lastAccess {
                    return lhs.cost > rhs.cost
                }
                return lhs.lastAccess < rhs.lastAccess
            }

        for candidate in evictionOrder {
            guard cache.count > maxEntries || totalTokenCost > maxTokenCost else { break }
            guard let removed = cache.removeValue(forKey: candidate.key) else { continue }
            totalTokenCost -= removed.cost
        }
    }
}

private struct CacheEntry {
    let tokens: [ReaderToken]
    let cost: Int
    var lastAccess: UInt64
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
