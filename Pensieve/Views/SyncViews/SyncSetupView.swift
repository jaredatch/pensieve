import SwiftUI

/// Connect-a-remote setup sheet (PLAN-08 / 08.3). One field for the remote URL; when it parses as
/// https a username + access-token pair appears (ssh authenticates via the agent — no token needed).
/// State comes from `SyncSetupModel`. Completion dismisses the sheet unless a fallback notice
/// needs acknowledgement; that completed sheet keeps its fields disabled and closes with Done or Escape.
struct SyncSetupView: View {
    @Environment(\.dismiss) private var dismiss
    let model: SyncSetupModel

    @State private var url: String = ""
    @State private var username: String = ""
    @State private var token: String = ""

    private var isHTTPS: Bool {
        SyncSetupModel.parseRemote(url)?.transport == .https
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("Connect a sync remote")
                .font(.headline)
            Text("Point Pensieve at a private git repository to sync your skills across machines.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: Spacing.sm) {
                TextField("Remote URL", text: $url,
                          prompt: Text(verbatim: "git@github.com:you/pensieve-skills.git"))
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)

                if isHTTPS {
                    TextField("Username", text: $username, prompt: Text(verbatim: "x-access-token"))
                        .textFieldStyle(.roundedBorder)
                    SecureField("Access token", text: $token)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .disabled(model.state == .working || model.state == .done)

            if case let .failed(message) = model.state {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.state == .cancelled {
                Text("Connect was cancelled.").font(.callout).foregroundStyle(.secondary)
            }

            if let notice = model.connectionNotice {
                Text(notice)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Spacing.sm)

            HStack(spacing: Spacing.sm) {
                if model.state != .done {
                    Button("Cancel") {
                        if model.state == .working { model.cancel() } else { dismiss() }
                    }
                        .keyboardShortcut(.cancelAction)
                        .disabled(!model.canCancel)
                }
                Spacer()
                if model.state == .done {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        model.connect(url: url, username: username, token: token)
                    } label: {
                        HStack {
                            if model.state == .working { ProgressView().controlSize(.small) }
                            Text("Connect")
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(url.isEmpty || model.state == .working)
                }
            }
        }
        .padding(Spacing.xl)
        .frame(width: 460)
        .interactiveDismissDisabled(model.state == .working)
        .onAppear { model.prepareForPresentation() }
        .onDisappear { model.cancel() }
        .onChange(of: model.state) { _, newState in
            if newState == .done, model.connectionNotice == nil { dismiss() }
        }
    }
}
