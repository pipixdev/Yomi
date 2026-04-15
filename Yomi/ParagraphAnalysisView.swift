//
//  ParagraphAnalysisView.swift
//  Yomi
//

import SwiftUI

struct ParagraphAnalysisView: View {
    let tokens: [ReaderToken]

    @State private var selectedToken: ReaderToken?

    var body: some View {
        ScrollView {
            if tokens.isEmpty {
                ContentUnavailableView(
                    String(localized: "No tokens found"),
                    systemImage: "text.word.spacing"
                )
                .padding(20)
            } else {
                TokenFlowLayout(spacing: 6, lineSpacing: 14) {
                    ForEach(tokens) { token in
                        Button {
                            selectedToken = token
                        } label: {
                            ReaderTokenChip(token: token)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
        }
        .navigationTitle(String(localized: "Parse"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedToken) { token in
            TokenDetailSheet(token: token)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

private struct ReaderTokenChip: View {
    let token: ReaderToken

    private let readingLineHeight: CGFloat = 14
    private let surfaceLineHeight: CGFloat = 28

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(displaySegments.enumerated()), id: \.offset) { _, segment in
                VStack(alignment: .leading, spacing: 3) {
                    if let reading = segment.reading, !reading.isEmpty {
                        Text(reading)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(height: readingLineHeight, alignment: .bottomLeading)
                    } else {
                        Color.clear
                            .frame(height: readingLineHeight)
                    }

                    Text(segment.surface)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(height: surfaceLineHeight, alignment: .topLeading)

                    DashedUnderline(color: color)
                        .frame(height: 3)
                }
            }
        }
        .padding(.horizontal, 1)
    }

    private var displaySegments: [TokenDisplaySegment] {
        token.displaySegments
    }

    private var color: Color {
        switch token.partOfSpeech {
        case .noun:
            return Color.yellow
        case .verb:
            return Color.green
        case .particle:
            return Color.cyan
        case .adjective:
            return Color.pink
        case .adverb:
            return Color.purple
        case .prefix:
            return Color.orange
        case .symbol:
            return Color.gray
        case .other:
            return Color.blue
        }
    }
}

private struct DashedUnderline: View {
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                path.move(to: CGPoint(x: 0, y: 1))
                path.addLine(to: CGPoint(x: proxy.size.width, y: 1))
            }
            .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .butt, dash: [5, 4]))
            .foregroundStyle(color.opacity(0.95))
        }
        .frame(height: 3)
    }
}

private struct TokenDisplaySegment: Hashable {
    let surface: String
    let reading: String?
}

private struct TokenDetailSheet: View {
    let token: ReaderToken

    var body: some View {
        NavigationStack {
            Group {
                if token.partOfSpeech == .verb {
                    VerbTokenDetailView(token: token)
                } else {
                    UnsupportedTokenDetailView(token: token)
                }
            }
            .navigationTitle(token.surface)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct VerbTokenDetailView: View {
    let token: ReaderToken

    var body: some View {
        List {
            Section {
                detailRow(
                    title: String(localized: "Verb group"),
                    value: token.verbGroup?.label ?? String(localized: "Unknown")
                )

                detailRow(
                    title: String(localized: "Dictionary form"),
                    value: token.dictionaryForm ?? token.surface
                )
            } header: {
                Text(String(localized: "Verb Details"))
            }
        }
    }

    @ViewBuilder
    private func detailRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)

            Spacer(minLength: 16)

            Text(value)
                .fontWeight(.semibold)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct UnsupportedTokenDetailView: View {
    let token: ReaderToken

    var body: some View {
        ContentUnavailableView(
            String(localized: "Coming Soon"),
            systemImage: "square.grid.2x2",
            description: Text(
                String(
                    format: String(localized: "Details for %@ are not available yet."),
                    token.partOfSpeech.label
                )
            )
        )
    }
}

private struct TokenFlowLayout<Content: View>: View {
    let spacing: CGFloat
    let lineSpacing: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        FlowLayout(spacing: spacing, lineSpacing: lineSpacing) {
            content
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let containerWidth = proposal.width ?? 320
        let rows = arrangeRows(in: containerWidth, subviews: subviews)
        let height = rows.last.map { $0.maxY } ?? 0
        return CGSize(width: containerWidth, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let rows = arrangeRows(in: bounds.width, subviews: subviews)
        for row in rows {
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: bounds.minX + item.frame.minX, y: bounds.minY + item.frame.minY),
                    proposal: ProposedViewSize(item.frame.size)
                )
            }
        }
    }

    private func arrangeRows(in width: CGFloat, subviews: Subviews) -> [FlowRow] {
        guard !subviews.isEmpty else { return [] }

        let measured = subviews.enumerated().map { index, subview in
            FlowItem(index: index, size: subview.sizeThatFits(.unspecified))
        }

        var rows: [FlowRow] = []
        var currentItems: [PlacedFlowItem] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var currentRowHeight: CGFloat = 0

        for item in measured {
            let itemWidth = min(item.size.width, width)
            let nextX = currentItems.isEmpty ? 0 : currentX + spacing

            if !currentItems.isEmpty, nextX + itemWidth > width {
                rows.append(FlowRow(items: currentItems, maxY: currentY + currentRowHeight))
                currentY += currentRowHeight + lineSpacing
                currentItems = []
                currentX = 0
                currentRowHeight = 0
            }

            let originX = currentItems.isEmpty ? 0 : currentX + spacing
            let frame = CGRect(origin: CGPoint(x: originX, y: currentY), size: CGSize(width: itemWidth, height: item.size.height))
            currentItems.append(PlacedFlowItem(index: item.index, frame: frame))
            currentX = frame.maxX
            currentRowHeight = max(currentRowHeight, item.size.height)
        }

        if !currentItems.isEmpty {
            rows.append(FlowRow(items: currentItems, maxY: currentY + currentRowHeight))
        }

        return rows
    }
}

private struct FlowItem {
    let index: Int
    let size: CGSize
}

private struct PlacedFlowItem {
    let index: Int
    let frame: CGRect
}

private struct FlowRow {
    let items: [PlacedFlowItem]
    let maxY: CGFloat
}

private extension ReaderToken {
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
        for index in surface.indices {
            if surface[index].isKanaLike {
                anchorStart = index
                break
            }
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

private extension String {
    var containsKanji: Bool {
        unicodeScalars.contains(where: \.isKanji)
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
