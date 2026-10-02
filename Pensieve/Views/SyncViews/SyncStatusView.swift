import SwiftUI

/// The sidebar's sync line (Route B, 2026-09-11): one plain button — a glyph and a short label,
/// tertiary at rest, secondary under the pointer, where the label turns into the action ("Sync
/// now" / "Resolve…"). Absent entirely when sync is unconfigured (`ContentView` mounts it only
/// when `SyncModel.isConfigured`). The state → line mapping is `SyncFooterPresentation`.
struct SyncStatusView: View {
    @Environment(\.modelContext) private var modelContext
    let model: SyncModel
    let onResolve: () -> Void
    @State private var isHovering = false

    var body: some View {
        // Re-evaluated each minute so "12m ago" keeps counting without a state change.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let line = SyncFooterPresentation.make(state: model.state, canResolve: model.canResolve,
                hovering: isHovering, now: context.date) {
                Button(action: { perform(line.action) }, label: {
                    HStack(spacing: Spacing.xs) {
                        if line.showsSpinner {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: line.symbol)
                                .font(.body)
                                .frame(width: 16)
                                .accessibilityHidden(true)
                        }
                        Text(line.label).font(.caption).lineLimit(1)
                    }
                    .foregroundStyle(line.emphasized ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                })
                .buttonStyle(.plain)
                .disabled(line.action == .none)
                .onHover { isHovering = $0 }
                .help(line.help ?? "")
                .accessibilityLabel(line.label)
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, Spacing.sm)
            }
        }
    }

    private func perform(_ action: SyncFooterPresentation.Action) {
        switch action {
        case .none: break
        case .sync: model.syncNow(context: modelContext)
        case .resolve: onResolve()
        }
    }
}
