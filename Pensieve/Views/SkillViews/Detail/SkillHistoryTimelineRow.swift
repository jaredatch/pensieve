import SwiftUI

struct SkillHistoryTimelineRow<Content: View>: View {
    let dotColor: Color
    let connectsUp: Bool
    let connectsDown: Bool
    let content: Content

    init(
        dotColor: Color,
        connectsUp: Bool,
        connectsDown: Bool,
        @ViewBuilder content: () -> Content
    ) {
        self.dotColor = dotColor
        self.connectsUp = connectsUp
        self.connectsDown = connectsDown
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.lg) {
            VStack(spacing: 0) {
                Rectangle().fill(DesignTokens.timelineRule).frame(width: 1, height: 4)
                    .opacity(connectsUp ? 1 : 0)
                Circle().fill(dotColor).frame(width: 10, height: 10)
                Rectangle().fill(DesignTokens.timelineRule).frame(width: 1).frame(maxHeight: .infinity)
                    .opacity(connectsDown ? 1 : 0)
            }
            .frame(width: 12)
            content
                .padding(.bottom, Spacing.xxl)
        }
        // The flexible connector fills the content height without absorbing spare viewport height.
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
    }
}
