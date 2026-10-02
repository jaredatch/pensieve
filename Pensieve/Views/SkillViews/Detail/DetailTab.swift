import SwiftUI

/// The detail column's sections: text tabs under the header. This custom control exists
/// because no stock Mac control provides sections inside a pane. Declaration order is
/// the strip's order.
enum DetailTab: String, CaseIterable, Identifiable {
    case overview
    case deployments
    case content
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .deployments: "Deployments"
        case .content: "Content"
        case .history: "History"
        }
    }
}

/// The strip (the master `Skills / Tab Navigation`, 612 × 31): a 1 pt hairline along its bottom; each tab a
/// label padded 8 vertical and 10 horizontal, on a 6 pt gap; the selected tab medium in the accent color
/// inside a box filled with the pane's background and outlined on three sides, its bottom open over the
/// hairline so it joins the content. Every label reserves its medium width, so nothing moves on click.
/// The caller decides the switch (a gate may refuse it), so the strip reports a click and shows a value.
struct DetailTabBar: View {
    let selection: DetailTab
    let onSelect: (DetailTab) -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(DetailTab.allCases) { tab in
                tabItem(tab)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 31)
        .background(alignment: .bottom) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sections")
    }

    private func tabItem(_ tab: DetailTab) -> some View {
        let selected = tab == selection
        return Button {
            onSelect(tab)
        } label: {
            ZStack {
                Text(tab.title).font(DesignTokens.tabLabelActive).hidden()
                Text(tab.title).font(selected ? DesignTokens.tabLabelActive : DesignTokens.tabLabel)
            }
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .padding(.vertical, Spacing.sm)
            .padding(.horizontal, 10)
            .frame(height: 31)
            .background {
                if selected { SelectedTabBox() }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// The selected tab's box: the pane's background over the strip's hairline and a 1 pt outline along the
/// top, left, and right edges.
private struct SelectedTabBox: View {
    var body: some View {
        ZStack {
            Rectangle().fill(Color(nsColor: .textBackgroundColor))
            GeometryReader { proxy in
                Path { path in
                    let width = proxy.size.width, height = proxy.size.height
                    path.move(to: CGPoint(x: 0.5, y: height))
                    path.addLine(to: CGPoint(x: 0.5, y: 0.5))
                    path.addLine(to: CGPoint(x: width - 0.5, y: 0.5))
                    path.addLine(to: CGPoint(x: width - 0.5, y: height))
                }
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }
        }
    }
}
