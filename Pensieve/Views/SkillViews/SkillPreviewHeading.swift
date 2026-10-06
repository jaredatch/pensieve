import MarkdownUI
import SwiftUI

struct SkillPreviewHeading: View {
    let configuration: BlockConfiguration
    let size: Double
    @State private var targetID = UUID()

    var body: some View {
        // MarkdownUI 2.4.1's default Theme.basic uses these exact margins, weight and em sizes.
        configuration.label
            .markdownMargin(top: .rem(1.5), bottom: .rem(1))
            .markdownTextStyle {
                FontWeight(.semibold)
                FontSize(.em(size))
            }
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
