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
                decoratedValue(row, index: index)
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
            .overlay(alignment: .bottom) {
                if row < rows.count - 1 {
                    DesignTokens.markdownSeparator.frame(height: DesignTokens.frontmatterTableRuleThickness)
                }
            }
    }

    private func decoratedValue(_ row: SkillFrontmatterRow, index: Int) -> some View {
        Group {
            if let nested = row.nestedValue {
                ViewThatFits(in: .horizontal) {
                    FrontmatterEntryFit(minimumWidth: nested.columnMinimums.reduce(0, +)) {
                        NestedFrontmatterTable(table: nested)
                    }
                    FrontmatterText(value: row.value, isCollection: true)
                }
                .padding(.vertical, DesignTokens.markdownTableCellVertical)
                .padding(.horizontal, DesignTokens.markdownTableCellHorizontal)
            } else {
                cell(row.value, isCollection: row.isCollection)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .bottom) {
            if index < rows.count - 1 {
                DesignTokens.markdownSeparator.frame(height: DesignTokens.frontmatterTableRuleThickness)
            }
        }
    }

    private func cell(_ value: String, isKey: Bool = false, isCollection: Bool = false) -> some View {
        FrontmatterText(value: value, isKey: isKey, isCollection: isCollection)
            .padding(.vertical, DesignTokens.markdownTableCellVertical)
            .padding(.horizontal, DesignTokens.markdownTableCellHorizontal)
    }
}

/// Share a bounded key column and full row heights so dividers and fills remain continuous.
struct FrontmatterTableLayout: Layout {
    static let minimumCellWidth = DesignTokens.markdownTableCellHorizontal * 2 + DesignTokens.markdownBodySize * 3

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
        let minimumCellWidth = Self.minimumCellWidth
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

/// The fitting probe advertises the column floor, while actual layout can use the
/// available width to wrap text. ViewThatFits switches the entire entry to YAML
/// only when that floor cannot fit, rather than when the unwrapped text cannot fit.
private struct FrontmatterEntryFit: Layout {
    let minimumWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let table = subviews.first else { return .zero }
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? minimumWidth
        return table.sizeThatFits(ProposedViewSize(width: max(minimumWidth, width), height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                             proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

private struct NestedFrontmatterTable: View {
    let table: SkillFrontmatterValue

    var body: some View {
        NestedFrontmatterLayout(minimums: table.columnMinimums, hasHeader: table.headers != nil) {
            if let headers = table.headers {
                ForEach(Array(headers.enumerated()), id: \.offset) { column, key in
                    nestedCell(.scalar(key), column: column, isHeader: true)
                }
            }
            ForEach(Array(table.values.enumerated()), id: \.offset) { column, value in
                nestedCell(value, column: column)
            }
        }
        .overlay {
            Rectangle().strokeBorder(DesignTokens.markdownSeparator, lineWidth: DesignTokens.frontmatterTableRuleThickness)
        }
    }

    private func nestedCell(_ value: SkillFrontmatterValue, column: Int, isHeader: Bool = false) -> some View {
        Group {
            switch value {
            case let .scalar(text):
                FrontmatterText(value: text, isKey: isHeader)
            case .table:
                // AnyView bounds the recursive SwiftUI type; the tree itself is capped at three tables.
                AnyView(NestedFrontmatterTable(table: value))
            }
        }
        .padding(.vertical, DesignTokens.markdownTableCellVertical)
        .padding(.horizontal, DesignTokens.markdownTableCellHorizontal)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .trailing) {
            if column < table.values.count - 1 {
                DesignTokens.markdownSeparator.frame(width: DesignTokens.frontmatterTableRuleThickness)
            }
        }
        .overlay(alignment: .bottom) {
            if isHeader {
                DesignTokens.markdownSeparator.frame(height: DesignTokens.frontmatterTableRuleThickness)
            }
        }
    }
}

private struct FrontmatterText: View {
    let value: String
    var isKey = false
    var isCollection = false

    var body: some View {
        Text(ViewChangesPresentation.styledText(value))
            .font(.system(size: isCollection ? (DesignTokens.markdownBodySize * DesignTokens.markdownCodeScale).rounded()
                          : DesignTokens.markdownBodySize,
                          weight: isKey ? .semibold : .regular, design: isCollection ? .monospaced : .default))
            .lineHeight(.multiple(factor: DesignTokens.markdownBodyLineHeight))
            .fixedSize(horizontal: false, vertical: true)
    }
}

private extension SkillFrontmatterValue {
    var headers: [String]? {
        if case let .table(headers, _) = self { return headers }
        return nil
    }

    var values: [SkillFrontmatterValue] {
        if case let .table(_, values) = self { return values }
        return []
    }

    var minimumWidth: CGFloat {
        switch self {
        case .scalar: return FrontmatterTableLayout.minimumCellWidth
        case .table: return columnMinimums.reduce(0, +) + DesignTokens.markdownTableCellHorizontal * 2
        }
    }

    var columnMinimums: [CGFloat] { values.map(\.minimumWidth) }
}

/// Both rows share column widths. Squeeze the widest columns first, preserving
/// short text until wider columns reach its width, and respecting recursive floors.
private struct NestedFrontmatterLayout: Layout {
    let minimums: [CGFloat]
    let hasHeader: Bool

    private struct Metrics {
        let widths: [CGFloat]
        let heights: [CGFloat]
        var size: CGSize { CGSize(width: widths.reduce(0, +), height: heights.reduce(0, +)) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        measurements(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let metrics = measurements(width: bounds.width, subviews: subviews)
        var top = bounds.minY
        for (row, height) in metrics.heights.enumerated() {
            var left = bounds.minX
            for (column, width) in metrics.widths.enumerated() {
                subviews[row * minimums.count + column].place(
                    at: CGPoint(x: left, y: top), anchor: .topLeading,
                    proposal: ProposedViewSize(width: width, height: height))
                left += width
            }
            top += height
        }
    }

    private func measurements(width: CGFloat?, subviews: Subviews) -> Metrics {
        guard !minimums.isEmpty else { return Metrics(widths: [], heights: []) }
        let rows = hasHeader ? 2 : 1
        let ideal = minimums.indices.map { column in
            (0..<rows).reduce(minimums[column]) { result, row in
                max(result, subviews[row * minimums.count + column].sizeThatFits(.unspecified).width)
            }
        }
        let floor = minimums.reduce(0, +), natural = ideal.reduce(0, +)
        let available = width.flatMap { $0.isFinite ? max(floor, $0) : nil } ?? natural
        var widths = ideal
        var shortfall = max(0, natural - available)
        // Each ideal width or minimum is a point where another column joins or
        // leaves the group being squeezed. Between those points, reduce it evenly.
        for cap in Set(ideal + minimums).sorted(by: >).dropFirst() where shortfall > 0 {
            let capped = minimums.indices.map { max(minimums[$0], min(ideal[$0], cap)) }
            let saving = zip(widths, capped).reduce(CGFloat.zero) { $0 + $1.0 - $1.1 }
            if saving <= shortfall {
                widths = capped
                shortfall -= saving
            } else {
                let shrinking = widths.indices.filter { widths[$0] > capped[$0] }
                let reduction = shortfall / CGFloat(shrinking.count)
                for column in shrinking { widths[column] -= reduction }
                break
            }
        }
        let heights = (0..<rows).map { row in
            widths.indices.map { column in
                subviews[row * minimums.count + column]
                    .sizeThatFits(ProposedViewSize(width: widths[column], height: nil)).height
            }.max() ?? 0
        }
        return Metrics(widths: widths, heights: heights)
    }
}
