import SwiftUI

/// The sidebar's sync line (Route B, 2026-09-11): one plain button — a glyph and a short label,
/// tertiary at rest, secondary under the pointer, where the label turns into the action ("Sync
/// now" / "Resolve…" / "Repair…"). Failed syncs keep their label and open the current reason.
/// `SyncModel.showsFooter` keeps it absent without sync unless
/// a save waits or the library is damaged. The state → line mapping is `SyncFooterPresentation`.
struct SyncStatusView: View {
    @Environment(\.modelContext) private var modelContext
    let model: SyncModel
    var saves: ManifestSaveModel?
    let onResolve: () -> Void
    var onOpenSyncSettings: () -> Void = {}
    @State private var isHovering = false
    @State private var showsFailure = false

    var body: some View {
        // Re-evaluated each minute so "12m ago" keeps counting without a state change.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 0) {
                if let message = saves?.statusMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, Spacing.xl).padding(.vertical, Spacing.sm)
                }
                if let line = SyncFooterPresentation.make(state: model.state, canResolve: model.canResolve,
                    hovering: isHovering, now: context.date, libraryDamaged: saves?.libraryDamaged == true) {
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
                    .accessibilityLabel(line.voiceOverText)
                    .padding(.horizontal, Spacing.xl)
                    .padding(.vertical, Spacing.sm)
                }
            }
        }
        .popover(isPresented: $showsFailure, arrowEdge: .top) {
            if let reason = failedReason {
                SyncFailurePopover(reason: reason, canSyncNow: model.canSyncNow,
                    onSync: {
                        showsFailure = false
                        model.syncNow(context: modelContext)
                    }, onOpenSyncSettings: {
                        showsFailure = false
                        onOpenSyncSettings()
                    })
            }
        }
        .onChange(of: failedReason != nil) { _, isFailure in
            if !isFailure { showsFailure = false }
        }
        .task(id: model.state) { await saves?.refreshAndRetry() }
    }

    private var failedReason: String? {
        guard saves?.libraryDamaged != true, case let .error(reason) = model.state else { return nil }
        return reason
    }

    private func perform(_ action: SyncFooterPresentation.Action) {
        switch action {
        case .showFailure: showsFailure = true
        case .none: break
        case .sync: model.syncNow(context: modelContext)
        case .resolve: onResolve()
        case .repair: saves?.requestRepair()
        }
    }
}
