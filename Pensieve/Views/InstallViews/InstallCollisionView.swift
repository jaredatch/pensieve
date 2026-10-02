import SwiftUI

struct InstallCollisionView: View {
    @Bindable var model: SkillInstallViewModel
    let collision: SkillInstallPendingCollision

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Label("A Skill Named \(collision.existing.slug) Already Exists", systemImage: "doc.on.doc")
                .font(.title2)
            Text("Choose how to handle this skill. Other selected skills will continue afterward.")
                .foregroundStyle(.secondary)

            if collision.canAdopt {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text(adoptHeading)
                        .font(.headline)
                    Text("Keep the local copy and track this repository as its source.")
                        .foregroundStyle(.secondary)
                    Button("Adopt") { model.adoptCollision() }
                        .disabled(model.collisionActionInFlight)
                }

                Divider()
            }

            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Rename")
                    .font(.headline)
                TextField("New skill name", text: $model.collisionRenameSlug)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.collisionActionInFlight)
                if let reason = model.renameValidationReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Button("Rename") { model.renameCollision() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.renameValidationReason != nil || model.collisionActionInFlight)
            }

            Spacer()
            Button("Cancel") { model.skipCollision() }
                .disabled(model.collisionActionInFlight)
        }
        .frame(maxWidth: 520, alignment: .leading)
        .padding(Spacing.xl)
    }

    private var adoptHeading: String {
        if let repository = model.repositoryDisplayName {
            return "Link ‘\(collision.existing.slug)’ to \(repository)?"
        }
        return "Link ‘\(collision.existing.slug)’ to this repository?"
    }
}
