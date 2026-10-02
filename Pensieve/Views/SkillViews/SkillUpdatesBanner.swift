import SwiftUI

/// The pinned notice above the Skills list (Route B, 2026-09-11): one plain button that opens the
/// updates sheet. `SkillListView` mounts it as a top safe-area inset so the rows scroll under it.
struct SkillUpdatesBanner: View {
    let count: Int
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text(UpdatesViewModel.noticeText(count: count))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Spacing.xl)
        // 8 above, 12 below: the design's text sits 16.75 pt above its divider (measured); 12 + half the
        // 13 pt caption line lands at 18.5, within the 2 pt gate, where 8 landed at 14.5.
        .padding(.top, Spacing.sm)
        .padding(.bottom, Spacing.md)
    }
}
