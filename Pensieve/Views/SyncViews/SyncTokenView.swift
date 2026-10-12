import SwiftUI

struct SyncTokenView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: SyncTokenModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text(model.hasSavedToken ? "Replace the access token" : "Add an access token")
                .font(.headline)
            Text("Pensieve checks the new token with \(model.remote?.host ?? "the remote") before saving it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            SecureField("Access token", text: $model.token)
                .textFieldStyle(.roundedBorder)
                .disabled(model.state == .checking)
            if case let .failed(message) = model.state {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Spacing.sm)
            HStack(spacing: Spacing.sm) {
                Button("Cancel") { model.cancel(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(!model.canCancel)
                Spacer()
                Button { model.save() } label: {
                    HStack {
                        if model.state == .checking { ProgressView().controlSize(.small) }
                        Text(model.hasSavedToken ? "Replace" : "Add")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSave)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 460)
        .interactiveDismissDisabled(!model.canCancel)
        .onAppear { model.prepareForPresentation() }
        .onDisappear { model.cancel() }
        .onChange(of: model.state) { _, state in if state == .saved { dismiss() } }
    }
}
