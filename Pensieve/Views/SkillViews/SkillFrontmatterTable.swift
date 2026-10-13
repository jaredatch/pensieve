import MarkdownUI
import SwiftUI

struct SkillFrontmatterTable: View {
    let rows: [SkillFrontmatterRow]

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                GridRow {
                    cell(row.key, isKey: true)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(maxHeight: .infinity, alignment: .topLeading)
                        .overlay(alignment: .trailing) {
                            DesignTokens.markdownSeparator.frame(width: DesignTokens.frontmatterTableRuleThickness)
                        }
                    cell(row.value, isCollection: row.isCollection)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(index.isMultiple(of: 2) ? Color.clear : DesignTokens.markdownCodeFill)
                .overlay(alignment: .bottom) {
                    if index < rows.count - 1 {
                        DesignTokens.markdownSeparator.frame(height: DesignTokens.frontmatterTableRuleThickness)
                    }
                }
            }
        }
        .overlay {
            Rectangle().strokeBorder(DesignTokens.markdownSeparator, lineWidth: DesignTokens.frontmatterTableRuleThickness)
        }
        .foregroundStyle(.primary)
        .textSelection(.enabled)
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
