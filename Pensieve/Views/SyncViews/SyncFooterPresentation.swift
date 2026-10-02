import Foundation

/// What the sidebar's sync line shows for a `SyncModel.SyncState`, at rest and under the pointer.
/// Pure so the mapping is tested apart from the view; `SyncStatusView` renders it.
struct SyncFooterPresentation: Equatable {
    enum Action: Equatable {
        case none
        case sync
        case resolve
    }

    /// SF Symbol name. Ignored while `showsSpinner`.
    var symbol: String
    var showsSpinner: Bool
    var label: String
    /// Secondary foreground when true (hovered, or a state that needs attention); tertiary otherwise.
    var emphasized: Bool
    var action: Action
    /// Tooltip text, when there is more to say than the label (an error message).
    var help: String?

    /// `nil` when sync is unconfigured: the footer is absent, not empty.
    static func make(state: SyncModel.SyncState, canResolve: Bool, hovering: Bool, now: Date) -> SyncFooterPresentation? {
        switch state {
        case .unconfigured:
            return nil
        case .syncing:
            return SyncFooterPresentation(symbol: "arrow.triangle.2.circlepath", showsSpinner: true,
                                          label: "Syncing…", emphasized: hovering, action: .none, help: nil)
        case .idle:
            return SyncFooterPresentation(symbol: "arrow.triangle.2.circlepath", showsSpinner: false,
                                          label: "Sync now", emphasized: hovering, action: .sync, help: nil)
        case let .synced(at):
            if hovering {
                return SyncFooterPresentation(symbol: "arrow.triangle.2.circlepath", showsSpinner: false,
                                              label: "Sync now", emphasized: true, action: .sync, help: nil)
            }
            return SyncFooterPresentation(symbol: "checkmark.circle", showsSpinner: false,
                                          label: RelativeTime.compact(for: at, relativeTo: now),
                                          emphasized: false, action: .sync, help: nil)
        case let .error(message):
            if hovering {
                return SyncFooterPresentation(symbol: "arrow.triangle.2.circlepath", showsSpinner: false,
                                              label: "Sync now", emphasized: true, action: .sync, help: message)
            }
            return SyncFooterPresentation(symbol: "exclamationmark.triangle", showsSpinner: false,
                                          label: "Sync failed", emphasized: true, action: .sync, help: message)
        case let .conflicted(paths):
            let label = hovering && canResolve ? "Resolve…" : "\(paths.count) conflict\(paths.count == 1 ? "" : "s")"
            return SyncFooterPresentation(symbol: "exclamationmark.arrow.triangle.2.circlepath", showsSpinner: false,
                                          label: label, emphasized: true, action: canResolve ? .resolve : .none, help: nil)
        }
    }
}
