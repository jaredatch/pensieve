import MarkdownUI
import SwiftUI

/// Primer's Markdown metrics with system colors. A fresh theme avoids Theme.gitHub's hex palette.
enum SkillPreviewTheme {
    static let theme = Theme()
        .text {
            FontSize(DesignTokens.markdownBodySize)
            ForegroundColor(.primary)
        }
        .strong { FontWeight(.semibold) }
        .link { ForegroundColor(.accentColor) }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(DesignTokens.markdownCodeScale))
            // MarkdownUI styles attributed text spans; inline padding and rounding are unavailable.
            BackgroundColor(DesignTokens.markdownCodeFill)
        }
        .heading1 { SkillPreviewHeading(configuration: $0, size: DesignTokens.markdownHeading1Scale, hasRule: true) }
        .heading2 { SkillPreviewHeading(configuration: $0, size: DesignTokens.markdownHeading2Scale, hasRule: true) }
        .heading3 { SkillPreviewHeading(configuration: $0, size: DesignTokens.markdownHeading3Scale) }
        .heading4 { SkillPreviewHeading(configuration: $0, size: DesignTokens.markdownHeading4Scale) }
        .heading5 { SkillPreviewHeading(configuration: $0, size: DesignTokens.markdownHeading5Scale) }
        .heading6 { SkillPreviewHeading(configuration: $0, size: DesignTokens.markdownHeading6Scale, isSecondary: true) }
        .paragraph { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .lineHeight(.multiple(factor: DesignTokens.markdownBodyLineHeight))
                .markdownMargin(top: 0, bottom: DesignTokens.markdownBlockGap)
        }
        .list { SkillPreviewList(configuration: $0) }
        .listItem { configuration in
            configuration.label
                .labelStyle(SkillPreviewListItemStyle())
                .markdownMargin(top: DesignTokens.markdownListItemGap)
        }
        .blockquote { configuration in
            HStack(spacing: 0) {
                DesignTokens.markdownSeparator.frame(width: DesignTokens.markdownQuoteRule)
                configuration.label
                    .markdownTextStyle { ForegroundColor(.secondary) }
                    .padding(.horizontal, DesignTokens.markdownQuoteInset)
            }
            .fixedSize(horizontal: false, vertical: true)
            .markdownMargin(top: 0, bottom: DesignTokens.markdownBlockGap)
        }
        .codeBlock { configuration in
            ScrollView(.horizontal) {
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(DesignTokens.markdownCodeScale))
                    }
                    .lineHeight(.multiple(factor: DesignTokens.markdownCodeLineHeight))
                    .padding(DesignTokens.markdownCodePadding)
            }
            .background(DesignTokens.markdownCodeFill)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.markdownCodeRadius))
            .markdownMargin(top: 0, bottom: DesignTokens.markdownBlockGap)
        }
        .table { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .markdownTableBorderStyle(.init(color: DesignTokens.markdownSeparator,
                                                width: DesignTokens.markdownRuleThickness))
                .markdownTableBackgroundStyle(.alternatingRows(.clear, DesignTokens.markdownCodeFill))
                .markdownMargin(top: 0, bottom: DesignTokens.markdownBlockGap)
        }
        .tableCell { configuration in
            configuration.label
                .markdownTextStyle {
                    if configuration.row == 0 { FontWeight(.semibold) }
                }
                .fixedSize(horizontal: false, vertical: true)
                .lineHeight(.multiple(factor: DesignTokens.markdownBodyLineHeight))
                .padding(.vertical, DesignTokens.markdownTableCellVertical)
                .padding(.horizontal, DesignTokens.markdownTableCellHorizontal)
        }
        .thematicBreak {
            DesignTokens.markdownSeparator
                .frame(height: DesignTokens.markdownRuleThickness)
                .markdownMargin(top: DesignTokens.markdownThematicBreakMargin,
                                bottom: DesignTokens.markdownThematicBreakMargin)
        }
}

private struct SkillPreviewListItemStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: VerticalAlignment(SkillPreviewListFirstLine.self), spacing: 0) {
            configuration.icon
                .padding(.trailing, Spacing.xs)
                .frame(width: DesignTokens.markdownListIndent, alignment: .trailing)
            configuration.title
        }
    }
}

private enum SkillPreviewListFirstLine: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat {
        // Center the marker beside the first line, including when the item wraps or contains nested blocks.
        let laterLines = context[.lastTextBaseline] - context[.firstTextBaseline]
        return (context.height - laterLines) / 2
    }
}

private struct SkillPreviewList: View {
    @Environment(\.previewListDepth) private var depth
    let configuration: BlockConfiguration

    var body: some View {
        configuration.label
            .environment(\.previewListDepth, depth + 1)
            .markdownMargin(top: 0, bottom: depth == 0 ? DesignTokens.markdownBlockGap : 0)
    }
}

private struct PreviewListDepthKey: EnvironmentKey {
    static let defaultValue = 0
}

private extension EnvironmentValues {
    var previewListDepth: Int {
        get { self[PreviewListDepthKey.self] }
        set { self[PreviewListDepthKey.self] = newValue }
    }
}
