//
//  FlowLayout.swift
//  Yomi
//

import SwiftUI

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        let lines = arrange(in: width, subviews: subviews)
        let height = lines.last.map { $0.maxY } ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let lines = arrange(in: bounds.width, subviews: subviews)
        for line in lines {
            for item in line.items {
                subviews[item.index].place(
                    at: CGPoint(x: bounds.minX + item.frame.minX, y: bounds.minY + item.frame.minY),
                    proposal: ProposedViewSize(item.frame.size)
                )
            }
        }
    }

    private func arrange(in width: CGFloat, subviews: Subviews) -> [Line] {
        let availableWidth = max(width, 1)
        var lines: [Line] = []
        var currentLine = Line(items: [], maxY: 0)
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let exceedsLine = currentX > 0 && currentX + size.width > availableWidth

            if exceedsLine {
                currentLine.maxY = currentY + lineHeight
                lines.append(currentLine)
                currentX = 0
                currentY += lineHeight + rowSpacing
                lineHeight = 0
                currentLine = Line(items: [], maxY: 0)
            }

            let frame = CGRect(x: currentX, y: currentY, width: size.width, height: size.height)
            currentLine.items.append(LineItem(index: index, frame: frame))
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }

        if !currentLine.items.isEmpty {
            currentLine.maxY = currentY + lineHeight
            lines.append(currentLine)
        }

        return lines
    }

    private struct Line {
        var items: [LineItem]
        var maxY: CGFloat
    }

    private struct LineItem {
        let index: Int
        let frame: CGRect
    }
}
