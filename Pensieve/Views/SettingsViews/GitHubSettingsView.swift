import SwiftUI

struct GitHubSettingsView: View {
    @State private var model: GitHubCredentialSettingsModel

    init(credentialStore: CredentialStoreProtocol) {
        _model = State(initialValue: GitHubCredentialSettingsModel(credentialStore: credentialStore))
    }

    private let tokenPage = URL(string: "https://github.com/settings/personal-access-tokens/new")

    var body: some View {
        Form {
            Section("Private repositories") {
                if model.showsTokenEntry {
                    tokenEntry
                } else {
                    savedTokenRow
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { model.refresh() }
        .alert("GitHub token", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var savedTokenRow: some View {
        HStack(spacing: Spacing.sm) {
            savedTokenLabel
            Spacer()
            Button("Replace…") {
                model.beginReplacing()
            }
            Button("Remove", role: .destructive) {
                model.remove()
            }
        }
    }

    private var savedTokenLabel: some View {
        Label {
            Text("Token saved")
                .foregroundStyle(.primary)
        } icon: {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }

    private var tokenEntry: some View {
        Group {
            SecureField("Fine-grained personal access token", text: $model.token)
                .textFieldStyle(.roundedBorder)

            Text("The token needs Contents read-only access to each repository you install from.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let tokenPage {
                Link("Create a fine-grained token on GitHub", destination: tokenPage)
                    .font(.caption)
            }

            HStack(spacing: Spacing.sm) {
                if model.hasSavedToken {
                    savedTokenLabel
                } else {
                    Label("No token saved", systemImage: "circle")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if model.isReplacingToken {
                    Button("Cancel", role: .cancel) {
                        model.cancelReplacing()
                    }
                }

                Button("Save") {
                    model.save()
                }
                .disabled(!model.canSave)
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}
