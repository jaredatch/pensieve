import SwiftUI

/// The empty state from the Sketch `Empty state` masters, after Mail's "No Message Selected": a large light
/// title, an optional description, optional actions, and no icon. A list column's empty and no-results
/// states use the secondary title; a detail column with nothing selected shows the title alone, tertiary.
struct EmptyStateView<Actions: View>: View {
    enum Emphasis {
        /// A list column: the title in the secondary label color.
        case list
        /// A detail column with nothing selected: the title in the tertiary label color.
        case noSelection
    }

    let title: String
    let description: String?
    let emphasis: Emphasis
    @ViewBuilder let actions: () -> Actions

    init(_ title: String, description: String? = nil, emphasis: Emphasis = .list,
         @ViewBuilder actions: @escaping () -> Actions) {
        self.title = title
        self.description = description
        self.emphasis = emphasis
        self.actions = actions
    }

    var body: some View {
        VStack(spacing: DesignTokens.emptyStateGap) {
            Text(title)
                .font(DesignTokens.emptyStateTitle)
                .foregroundStyle(emphasis == .list ? .secondary : .tertiary)
            if let description {
                Text(description)
                    .font(DesignTokens.emptyStateDescription)
                    .foregroundStyle(.tertiary)
            }
            actions()
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, DesignTokens.emptyStateSidePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(_ title: String, description: String? = nil, emphasis: Emphasis = .list) {
        self.init(title, description: description, emphasis: emphasis) { EmptyView() }
    }

    /// A detail column with nothing selected ("No Skill Selected").
    static func noSelection(_ section: SidebarSection) -> Self {
        Self(EmptyStateCopy.noSelectionTitle(section), emphasis: .noSelection)
    }

    /// A search that matched nothing.
    static func search(text: String) -> Self {
        Self(EmptyStateCopy.searchTitle(text), description: EmptyStateCopy.searchDescription)
    }
}
