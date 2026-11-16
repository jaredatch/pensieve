import MarkdownUI
import SwiftUI

struct SkillPreviewCodeBlock: View {
    let configuration: CodeBlockConfiguration
    @State private var fadeWidth: CGFloat = 0

    var body: some View {
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
        .scrollIndicators(.never, axes: .horizontal)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            // Padding scrolls too, but only characters beyond the viewport call for a cue.
            let hiddenText = geometry.contentSize.width - DesignTokens.markdownCodePadding - geometry.visibleRect.maxX
            return min(DesignTokens.markdownCodeFadeWidth, max(0, hiddenText))
        } action: { _, width in
            fadeWidth = width
        }
        .mask {
            HStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: fadeWidth)
            }
            .allowsHitTesting(false)
        }
        // Mask the text before adding the translucent fill, keeping the background uniform.
        .background(DesignTokens.markdownCodeFill)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.markdownCodeRadius))
        .markdownMargin(top: 0, bottom: DesignTokens.markdownBlockGap)
    }
}
