import SwiftUI

struct RemoteProjectDetailView: View {
    let model: RemoteProjectModel

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(model.name)
                        .font(.title2)
                    Text(model.identityLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if model.identityLine != model.displayIdentityKey {
                        Text(model.displayIdentityKey)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, Spacing.xs)
            }
            ForEach(model.machines) { machine in
                Section(machine.detail.name) {
                    if let path = machine.publishedPath, !path.isEmpty {
                        Text(path)
                            .truncationMode(.middle)
                    }
                    TimelineView(.periodic(from: machine.detail.currentDate, by: 60)) { context in
                        Text(machine.detail.lastUpdatedText(relativeTo: context.date))
                            .foregroundStyle(.secondary)
                    }
                    if machine.deploys.isEmpty {
                        Text(DeploymentsPresentation.noSkillsDeployed)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(machine.deploys) { deploy in
                            LabeledContent(deploy.displaySkillSlug, value: deploy.platformName)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(model.name)
    }
}
