import SwiftUI
import MarkdownUI

struct SkillPreviewView: View {
    @Environment(\.colorScheme) private var colorScheme
    let markdownBody: String
    var scrolls = true
    var skillDirectory: String?
    var imageLoader: PreviewImageLoading = PreviewImageLoader()

    @ViewBuilder var body: some View {
        if scrolls {
            ScrollView { markdown }
        } else {
            markdown
        }
    }

    private var markdown: some View {
        Markdown(markdownBody)
            .markdownImageProvider(imageProvider)
            .markdownInlineImageProvider(imageProvider)
            // The block provider's API has no alt-text parameter; the image theme supplies it.
            .markdownBlockStyle(\.image) { configuration in
                configuration.label.environment(\.previewImageAlt, configuration.content.renderPlainText())
            }
            .textSelection(.enabled)
            .padding(Spacing.lg)
            // MarkdownUI keys inline-image tasks only by markdown. Rebuild them when their
            // folder or rasterized placeholder colors change, even if the text is identical.
            .id(ImageContext(directory: skillDirectory, colorScheme: colorScheme))
    }

    private var imageProvider: PreviewImageProvider {
        PreviewImageProvider(loader: imageLoader, skillDirectory: skillDirectory, colorScheme: colorScheme)
    }

    private struct ImageContext: Hashable {
        let directory: String?
        let colorScheme: ColorScheme
    }
}
