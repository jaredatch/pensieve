import MarkdownUI
import SwiftUI

struct SkillPreviewHeading: View {
    let configuration: BlockConfiguration
    let size: CGFloat
    var hasRule = false
    var isSecondary = false
    @State private var targetID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .lineHeight(.multiple(factor: DesignTokens.markdownHeadingLineHeight))
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(size))
                    ForegroundColor(isSecondary ? .secondary : .primary)
                }
                // Primer keeps inline code in headings at the heading's own size.
                .markdownTextStyle(\.code) {
                    FontFamilyVariant(.monospaced)
                    FontSize(.em(1))
                    BackgroundColor(DesignTokens.markdownCodeFill)
                }
                .padding(.bottom, hasRule ? DesignTokens.markdownHeadingRulePadding *
                         DesignTokens.markdownBodySize * size : 0)
            if hasRule {
                DesignTokens.markdownSeparator
                    .frame(height: DesignTokens.markdownRuleThickness)
            }
        }
            .markdownMargin(top: DesignTokens.markdownHeadingTop, bottom: DesignTokens.markdownBlockGap)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: SkillPreviewHeadingPreference.self, value: [
                        .init(id: targetID, slug: SkillPreviewLinkPolicy.slug(configuration.content.renderPlainText()),
                              position: geometry.frame(in: .named(SkillPreviewHeadingPreference.coordinateSpace)).minY)
                    ])
                }
            }
            .id(targetID)
    }
}

struct SkillPreviewHeadingPreference: PreferenceKey {
    static let coordinateSpace = "skill-preview-headings"
    static let defaultValue: [SkillPreviewLinkPolicy.HeadingTarget] = []

    static func reduce(value: inout [SkillPreviewLinkPolicy.HeadingTarget],
                       nextValue: () -> [SkillPreviewLinkPolicy.HeadingTarget]) {
        value.append(contentsOf: nextValue())
    }
}
