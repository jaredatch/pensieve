import SwiftUI

/// Connect-a-remote setup sheet (PLAN-08 / 08.3). One field for the remote URL; when it parses as
/// https a username + access-token pair appears (ssh authenticates via the agent — no token needed).
/// State (idle/working/done/failed) comes from `SyncSetupModel`; a `.done` dismisses the sheet.
struct SyncSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: SyncSetupModel

    @State private var url: String = ""
    @State private var username: String = ""
    @State private var token: String = ""

    init(model: SyncSetupModel) {
        _model = State(initialValue: model)
    }

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

            if case let .failed(message) = model.state {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Spacing.sm)

            HStack(spacing: Spacing.sm) {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if model.state == .working {
                    ProgressView().controlSize(.small)
                }
                Button("Connect") {
                    model.connect(url: url, username: username, token: token)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(url.isEmpty || model.state == .working)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 460)
        .onChange(of: model.state) { _, newState in
            if newState == .done { dismiss() }
        }
    }
}
