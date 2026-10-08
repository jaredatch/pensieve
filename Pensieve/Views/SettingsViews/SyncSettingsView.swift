import SwiftUI

/// Settings › Sync (Route B, 2026-09-11): where a remote is connected now that the sidebar footer
/// is status only. Shows the remote, a Connect… button when there is none, and the background-sync
/// toggle that lived under General; Disconnect removes the remote and its sync token, not local data or the install token.
struct SyncSettingsView: View {
    @Environment(AppRuntime.self) private var runtime
    @Environment(\.modelContext) private var modelContext
    @AppStorage("backgroundSyncEnabled") private var backgroundSyncEnabled = true
    @State private var showSetup = false
    @State private var confirmDisconnect = false
    @State private var disconnectError: String?
    private var remoteURL: String? { runtime.syncModel.remoteURL }
    private var remoteError: String? { runtime.syncModel.configurationError }

    var body: some View {
        Form {
            Section("Remote") {
                LabeledContent("Repository") {
                    Text(runtime.syncModel.configurationDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(remoteError == nil ? 1 : nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .truncationMode(.middle)
                }
                if remoteError != nil {
                    EmptyView()
                } else if runtime.syncModel.canConnect {
                    Button("Connect…") { showSetup = true }
                        .controlSize(.small)
                } else if remoteURL != nil {
                    Button("Disconnect…") { confirmDisconnect = true }
                        .controlSize(.small)
                        .disabled(disconnectUnavailable)
                    if disconnectUnavailable {
                        Text(runtime.syncModel.isConflicted
                             ? "Resolve the conflicts before disconnecting."
                             : "Wait for the current sync to finish.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section("Behavior") {
                Toggle("Background sync", isOn: $backgroundSyncEnabled)
            }
        }
        .formStyle(.grouped)
        .padding()
        .task { await runtime.refreshGitUsability() }
        .onChange(of: backgroundSyncEnabled) { _, _ in
            runtime.scheduler.drainPendingRequests()
        }
        .sheet(
            isPresented: $showSetup,
            onDismiss: {
                refresh()
            },
            content: { SyncSetupView(model: SyncSetupModel(context: modelContext)) }
        )
        .confirmationDialog(
            "Disconnect from \(remoteURL ?? "this repository")?",
            isPresented: $confirmDisconnect,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) { disconnect() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Pensieve stops syncing with this repository and forgets the token it saved for it. "
                 + "Your skills, their history, and your GitHub token for installs stay as they are. "
                 + "You can connect again any time.")
        }
        .alert("Couldn't disconnect", isPresented: Binding(
            get: { disconnectError != nil },
            set: { if !$0 { disconnectError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(disconnectError ?? "")
        }
    }

    /// Reads observable state only (no subprocess): the lock check itself is inside `performDisconnect`.
    private var disconnectUnavailable: Bool {
        runtime.syncModel.state == .syncing || runtime.syncModel.isConflicted
    }

    private func refresh() {
        Task { await runtime.refreshGitUsability() }
    }

    private func disconnect() {
        defer {
            refresh()
        }
        guard !disconnectUnavailable else {
            disconnectError = runtime.syncModel.isConflicted
                ? "Resolve the conflicts before disconnecting."
                : "Wait for the current sync to finish."
            return
        }
        do {
            try SyncSetupModel(context: modelContext).performDisconnect()
        } catch {
            disconnectError = error.localizedDescription
        }
    }
}
