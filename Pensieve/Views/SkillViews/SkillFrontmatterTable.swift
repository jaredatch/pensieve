import MarkdownUI
import SwiftUI

struct SkillFrontmatterTable: View {
    let rows: [SkillFrontmatterRow]

    var body: some View {
        FrontmatterTableLayout {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                decoratedCell(row.key, row: index, isKey: true)
                    .overlay(alignment: .trailing) {
                        DesignTokens.markdownSeparator.frame(width: DesignTokens.frontmatterTableRuleThickness)
                    }
                decoratedCell(row.value, row: index, isCollection: row.isCollection)
            }
        }
        .overlay {
            Rectangle().strokeBorder(DesignTokens.markdownSeparator, lineWidth: DesignTokens.frontmatterTableRuleThickness)
        }
        .foregroundStyle(.primary)
        .textSelection(.enabled)
    }

    private func decoratedCell(_ value: String, row: Int, isKey: Bool = false, isCollection: Bool = false) -> some View {
        cell(value, isKey: isKey, isCollection: isCollection)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(row.isMultiple(of: 2) ? Color.clear : DesignTokens.markdownCodeFill)
            .overlay(alignment: .bottom) {
                if row < rows.count - 1 {
                    DesignTokens.markdownSeparator.frame(height: DesignTokens.frontmatterTableRuleThickness)
                }
            }
    }

    private func cell(_ value: String, isKey: Bool = false, isCollection: Bool = false) -> some View {
        var shown = value.unicodeScalars
        while shown.last == "\n" { shown.removeLast() }
        return Text(ViewChangesPresentation.styledText(String(shown)))
            .font(.system(size: isCollection ? (DesignTokens.markdownBodySize * DesignTokens.markdownCodeScale).rounded()
                          : DesignTokens.markdownBodySize,
                          weight: isKey ? .semibold : .regular, design: isCollection ? .monospaced : .default))
            .lineHeight(.multiple(factor: DesignTokens.markdownBodyLineHeight))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, DesignTokens.markdownTableCellVertical)
            .padding(.horizontal, DesignTokens.markdownTableCellHorizontal)
    }
}

/// Measure keys intrinsically, then place both cells in each row at its full height. GridRow
/// decorations otherwise follow each cell's intrinsic bounds, leaving gaps beside short keys.
private struct FrontmatterTableLayout: Layout {
    private struct Metrics {
        let width: CGFloat
        let keyWidth: CGFloat
        let heights: [CGFloat]
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let metrics = measurements(width: proposal.width, subviews: subviews)
        return CGSize(width: metrics.width, height: metrics.heights.reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let metrics = measurements(width: bounds.width, subviews: subviews)
        var top = bounds.minY
        for (row, height) in metrics.heights.enumerated() {
            subviews[row * 2].place(at: CGPoint(x: bounds.minX, y: top), anchor: .topLeading,
                                    proposal: ProposedViewSize(width: metrics.keyWidth, height: height))
            subviews[row * 2 + 1].place(at: CGPoint(x: bounds.minX + metrics.keyWidth, y: top), anchor: .topLeading,
                                        proposal: ProposedViewSize(width: metrics.width - metrics.keyWidth, height: height))
            top += height
        }
    }

    private func measurements(width: CGFloat?, subviews: Subviews) -> Metrics {
        let keys = stride(from: 0, to: subviews.count, by: 2)
        let keyWidth = keys.map { subviews[$0].sizeThatFits(.unspecified).width }.max() ?? 0
        let idealValueWidth = keys.map { subviews[$0 + 1].sizeThatFits(.unspecified).width }.max() ?? 0
        let width = max(keyWidth, width.flatMap { $0.isFinite ? $0 : nil } ?? keyWidth + idealValueWidth)
        let heights = keys.map { index in
            max(subviews[index].sizeThatFits(ProposedViewSize(width: keyWidth, height: nil)).height,
                subviews[index + 1].sizeThatFits(ProposedViewSize(width: width - keyWidth, height: nil)).height)
        }
        return Metrics(width: width, keyWidth: keyWidth, heights: heights)
    }
}
