import SwiftUI
import MarkdownUI

struct SkillPreviewView: View {
    let markdownBody: String
    var scrolls = true

    @ViewBuilder var body: some View {
        if scrolls {
            ScrollView { markdown }
        } else {
            markdown
        }
    }

    private var markdown: some View {
        Markdown(markdownBody)
            .textSelection(.enabled)
            .padding(Spacing.lg)
    }
}
