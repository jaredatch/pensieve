import SwiftUI

/// The system popover supplies its chrome; the full selectable diagnosis remains independent of the audit's byte limit.
struct SyncFailurePopover: View {
    let reason: String
    let canSyncNow: Bool
    let onSync: () -> Void
    let onOpenSyncSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Sync failed").font(.headline)
            ViewThatFits(in: .vertical) {
                reasonText
                ScrollView { reasonText }
            }
            .frame(maxHeight: 240)
            HStack(spacing: Spacing.sm) {
                Button("Sync Now", action: onSync)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSyncNow)
                if reason.contains("Settings › Sync") {
                    Button("Open Sync Settings…", action: onOpenSyncSettings)
                }
            }
        }
        .frame(width: 320, alignment: .leading)
        .padding(Spacing.lg)
    }

    private var reasonText: some View {
        Text(reason)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
