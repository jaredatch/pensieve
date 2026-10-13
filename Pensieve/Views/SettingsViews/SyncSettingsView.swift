import SwiftUI

/// Settings › Sync (Route B, 2026-09-11): where a remote is connected now that the sidebar footer
/// is status only. Shows the remote, a Connect… button when there is none, and the background-sync
/// toggle that lived under General; Disconnect removes the remote and its sync token, not local data or the install token.
struct SyncSettingsView: View {
    @Environment(AppRuntime.self) private var runtime
    @AppStorage("backgroundSyncEnabled") private var backgroundSyncEnabled = true
    @State private var showSetup = false
    @State private var showToken = false
    @State private var confirmDisconnect = false
    @State private var disconnectError: String?
    private var model: SyncSetupModel { runtime.syncSetup }
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
                if model.syncToken.remote != nil {
                    tokenRow
                }
                if remoteError != nil && model.state != .working && !model.isDisconnecting {
                    EmptyView()
                } else if model.state == .working || (runtime.syncModel.canConnect && !model.isDisconnecting) {
                    Button { showSetup = true } label: {
                        HStack {
                            if model.state == .working { ProgressView().controlSize(.small) }
                            Text("Connect…")
                        }
                    }
                        .controlSize(.small)
                        .disabled(model.state == .working || model.isDisconnecting)
                } else if remoteURL != nil || model.isDisconnecting {
                    Button { confirmDisconnect = true } label: {
                        HStack {
                            if model.isDisconnecting { ProgressView().controlSize(.small) }
                            Text("Disconnect…")
                        }
                    }
                        .controlSize(.small)
                        .disabled(disconnectUnavailable)
                    if disconnectUnavailable && !model.isDisconnecting {
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
        .task(id: remoteURL) { model.syncToken.refresh(remoteURL: remoteURL) }
        .onChange(of: backgroundSyncEnabled) { _, _ in
            runtime.scheduler.drainPendingRequests()
        }
        .sheet(
            isPresented: $showSetup,
            onDismiss: {
                refresh()
            },
            content: { SyncSetupView(model: model) }
        )
        .sheet(isPresented: $showToken) { SyncTokenView(model: model.syncToken) }
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

    private var tokenRow: some View {
        Group {
            HStack(spacing: Spacing.sm) {
                if model.syncToken.hasSavedToken {
                    Label { Text("Token saved") } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                } else {
                    Label("No token saved", systemImage: "circle").foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.syncToken.hasSavedToken ? "Replace…" : "Add…") { showToken = true }
                    .controlSize(.small)
            }
            if !model.syncToken.hasSavedToken {
                Text("Sync over HTTPS needs an access token. Add one to keep syncing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Reads observable state only (no subprocess): the lock check itself is inside `performDisconnect`.
    private var disconnectUnavailable: Bool {
        runtime.syncModel.state == .syncing || runtime.syncModel.isConflicted
            || model.isDisconnecting || model.state == .working
    }

    private func refresh() {
        Task { await runtime.refreshGitUsability() }
    }

    private func disconnect() {
        guard !disconnectUnavailable else {
            disconnectError = runtime.syncModel.isConflicted
                ? "Resolve the conflicts before disconnecting."
                : "Wait for the current sync to finish."
            return
        }
        Task {
            defer { refresh() }
            do {
                try await model.performDisconnect()
            } catch {
                disconnectError = error.localizedDescription
            }
        }
    }
}
