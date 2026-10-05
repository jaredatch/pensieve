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
    var files: [String] = []
    var onSelectFile: ((String) -> Void)?

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

    func imageProvider(budget: PreviewImageBudgeting, colorScheme: ColorScheme) -> PreviewImageProvider {
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
    @Environment(\.openURL) private var openURL
    let preview: SkillPreviewView
    let colorScheme: ColorScheme
    @State private var budget: PreviewImageBudgeting = PreviewImageDecodeBudget()
    @State private var headings: [SkillPreviewLinkPolicy.HeadingTarget] = []

    var body: some View {
        ScrollViewReader { proxy in
            markdown
                .coordinateSpace(name: SkillPreviewHeadingPreference.coordinateSpace)
                .onPreferenceChange(SkillPreviewHeadingPreference.self) { headings = $0 }
                .environment(\.openURL, OpenURLAction { url in
                    switch SkillPreviewLinkPolicy.decision(for: url, documentRelativePath: preview.documentRelativePath,
                                                          files: preview.files) {
                    case .openWeb:
                        openURL(url)
                        return .handled
                    case .scrollTo(let slug):
                        if let target = SkillPreviewLinkPolicy.firstHeading(for: slug, in: headings) {
                            proxy.scrollTo(target, anchor: .top)
                        }
                        return .handled
                    case .selectFile(let path):
                        preview.onSelectFile?(path)
                        return .handled
                    case .ignore: return .discarded
                    }
                })
        }
    }

    private var markdown: some View {
        let imageProvider = preview.imageProvider(budget: budget, colorScheme: colorScheme)
        return Markdown(preview.markdownBody)
            .markdownBlockStyle(\.heading1) { SkillPreviewHeading(configuration: $0, size: 2) }
            .markdownBlockStyle(\.heading2) { SkillPreviewHeading(configuration: $0, size: 1.5) }
            .markdownBlockStyle(\.heading3) { SkillPreviewHeading(configuration: $0, size: 1.17) }
            .markdownBlockStyle(\.heading4) { SkillPreviewHeading(configuration: $0, size: 1) }
            .markdownBlockStyle(\.heading5) { SkillPreviewHeading(configuration: $0, size: 0.83) }
            .markdownBlockStyle(\.heading6) { SkillPreviewHeading(configuration: $0, size: 0.67) }
            .markdownImageProvider(imageProvider)
            .markdownInlineImageProvider(imageProvider)
            // The block provider's API has no alt-text parameter; the image theme supplies it.
            .markdownBlockStyle(\.image) { configuration in
                configuration.label.environment(\.previewImageAlt, configuration.content.renderPlainText())
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.lg)
            .id(ObjectIdentifier(budget))
            .onAppear {
                if budget.isCancelled { budget = PreviewImageDecodeBudget() }
            }
            .onDisappear { budget.cancel() }
    }
}
