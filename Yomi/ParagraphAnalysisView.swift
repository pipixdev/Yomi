//
//  ParagraphAnalysisView.swift
//  Yomi
//

import SwiftUI

struct ParagraphAnalysisView: View {
    let paragraphText: String
    let tokens: [ReaderToken]

    @State private var selectedToken: ReaderToken?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "Morphology Analysis"))
                        .font(.title2.weight(.bold))

                    Text(paragraphText)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if tokens.isEmpty {
                    ContentUnavailableView(
                        String(localized: "No tokens found"),
                        systemImage: "text.word.spacing"
                    )
                } else {
                    TokenFlowLayout(spacing: 12) {
                        ForEach(tokens) { token in
                            Button {
                                selectedToken = token
                            } label: {
                                ReaderTokenCard(token: token)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(String(localized: "Parse"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedToken) { token in
            TokenDetailSheet(token: token)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

private struct ReaderTokenCard: View {
    let token: ReaderToken

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(token.reading ?? " ")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(token.surface)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle()
                .fill(color.opacity(0.85))
                .frame(height: 8)
                .clipShape(Capsule())

            Text(token.partOfSpeech.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minWidth: 92)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(color.opacity(0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(color.opacity(0.22), lineWidth: 1)
        )
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
    @ViewBuilder let content: Content

    var body: some View {
        FlowLayout(spacing: spacing) {
            content
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

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
                currentY += currentRowHeight + spacing
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
