import SwiftUI
import MarkdownUI

struct SkillPreviewView: View {
    @Environment(\.colorScheme) private var colorScheme
    let markdownBody: String
    var scrolls = true
    var skillDirectory: String?
    var documentRelativePath = "SKILL.md"
    var imageRevision: UInt64 = 0
    var imageLoader: PreviewImageLoading = PreviewImageLoader()

    @ViewBuilder var body: some View {
        if scrolls {
            ScrollView { markdown }
        } else {
            markdown
        }
    }

    private var markdown: some View {
        RenderedSkillMarkdown(preview: self, colorScheme: colorScheme)
            // MarkdownUI keys inline-image tasks only by markdown. Rebuild the document and its
            // budget when text, watched assets, document context or placeholder colors change.
            .id(ImageContext(markdown: markdownBody, directory: skillDirectory, document: documentRelativePath,
                             revision: imageRevision, colorScheme: colorScheme))
    }

    func imageProvider(budget: PreviewImageDecodeBudget, colorScheme: ColorScheme = .light) -> PreviewImageProvider {
        PreviewImageProvider(loader: imageLoader, skillDirectory: skillDirectory,
                             documentRelativePath: documentRelativePath, colorScheme: colorScheme, budget: budget)
    }

    private struct ImageContext: Hashable {
        let markdown: String
        let directory: String?
        let document: String
        let revision: UInt64
        let colorScheme: ColorScheme
    }
}

private struct RenderedSkillMarkdown: View {
    let preview: SkillPreviewView
    let colorScheme: ColorScheme
    @State private var budget = PreviewImageDecodeBudget()

    var body: some View {
        let imageProvider = preview.imageProvider(budget: budget, colorScheme: colorScheme)
        Markdown(preview.markdownBody)
            .markdownImageProvider(imageProvider)
            .markdownInlineImageProvider(imageProvider)
            // The block provider's API has no alt-text parameter; the image theme supplies it.
            .markdownBlockStyle(\.image) { configuration in
                configuration.label.environment(\.previewImageAlt, configuration.content.renderPlainText())
            }
            .textSelection(.enabled)
            .padding(Spacing.lg)
            .onDisappear { budget.cancel() }
    }
}
