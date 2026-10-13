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
        Text(ViewChangesPresentation.styledText(value))
            .font(.system(size: isCollection ? (DesignTokens.markdownBodySize * DesignTokens.markdownCodeScale).rounded()
                          : DesignTokens.markdownBodySize,
                          weight: isKey ? .semibold : .regular, design: isCollection ? .monospaced : .default))
            .lineHeight(.multiple(factor: DesignTokens.markdownBodyLineHeight))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, DesignTokens.markdownTableCellVertical)
            .padding(.horizontal, DesignTokens.markdownTableCellHorizontal)
    }
}

/// Share a bounded key column and full row heights so dividers and fills remain continuous.
struct FrontmatterTableLayout: Layout {
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
            if row * 2 + 1 < subviews.count {
                subviews[row * 2 + 1].place(at: CGPoint(x: bounds.minX + metrics.keyWidth, y: top), anchor: .topLeading,
                                          proposal: ProposedViewSize(width: metrics.width - metrics.keyWidth, height: height))
            }
            top += height
        }
    }

    private func measurements(width: CGFloat?, subviews: Subviews) -> Metrics {
        guard !subviews.isEmpty else { return Metrics(width: 0, keyWidth: 0, heights: []) }
        let keys = stride(from: 0, to: subviews.count, by: 2)
        let idealKeyWidth = keys.map { subviews[$0].sizeThatFits(.unspecified).width }.max() ?? 0
        let idealValueWidth = keys.map { index in
            index + 1 < subviews.count ? subviews[index + 1].sizeThatFits(.unspecified).width : 0
        }.max() ?? 0
        let width = width.flatMap { $0.isFinite ? max(0, $0) : nil }
            ?? min(idealKeyWidth, DesignTokens.frontmatterKeyMaximumWidth) + idealValueWidth
        let keyWidth = min(idealKeyWidth, DesignTokens.frontmatterKeyMaximumWidth,
                           width * DesignTokens.frontmatterKeyMaximumShare)
        // Reserve padding and a few glyphs before wrapping; smaller probes otherwise measure a glyph per line.
        let minimumCellWidth = DesignTokens.markdownTableCellHorizontal * 2 + DesignTokens.markdownBodySize * 3
        guard keyWidth >= min(idealKeyWidth, minimumCellWidth),
              width - keyWidth >= min(idealValueWidth, minimumCellWidth) else {
            return Metrics(width: width, keyWidth: keyWidth, heights: [])
        }
        let heights = keys.map { index in
            let keyHeight = subviews[index].sizeThatFits(ProposedViewSize(width: keyWidth, height: nil)).height
            guard index + 1 < subviews.count else { return keyHeight }
            return max(keyHeight,
                       subviews[index + 1].sizeThatFits(ProposedViewSize(width: width - keyWidth, height: nil)).height)
        }
        return Metrics(width: width, keyWidth: keyWidth, heights: heights)
    }
}
