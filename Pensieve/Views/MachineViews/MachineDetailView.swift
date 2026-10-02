import SwiftUI

struct MachineDetailView: View {
    let model: MachineDetailModel
    let skills: [Skill]
    let onReveal: (Skill) -> Void

    init(
        state: MachineState,
        skills: [Skill],
        localProjectIdentityKeys: Set<String>,
        localMachineID: String?,
        now: @escaping () -> Date,
        onReveal: @escaping (Skill) -> Void
    ) {
        self.skills = skills
        self.onReveal = onReveal
        model = MachineDetailModel(
            state: state,
            localProjectIdentityKeys: localProjectIdentityKeys,
            localMachineID: localMachineID,
            now: now
        )
    }

    var body: some View {
        Form {
            Section { header }
            agentSection
            projectSection("Registered Here", projects: model.registeredHereProjects)
            projectSection("Only on \(model.name)", projects: model.onlyOnMachineProjects)
            userDeploySection
            projectDeploySection
        }
        .formStyle(.grouped)
        .navigationTitle(model.name)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                Text(model.name)
                    .font(.title2)
                if model.isLocalMachine {
                    Label("This Mac", systemImage: "display")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            TimelineView(.periodic(from: model.currentDate, by: 60)) { context in
                Text(model.lastUpdatedText(relativeTo: context.date))
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            Text("Pensieve \(model.appVersion)")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(model.machineID)
                .truncationMode(.middle)
                .lineLimit(1)
                .textSelection(.enabled)
                .help("Machine ID")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, Spacing.xs)
    }

    private var agentSection: some View {
        Section("Agents") {
            if model.agents.isEmpty {
                emptyRow("No agents reported")
            } else {
                ForEach(model.agents) { agent in
                    Label(agent.name, systemImage: agent.iconName)
                }
            }
        }
    }

    private func projectSection(
        _ title: String,
        projects: [MachineDetailModel.ProjectSummary]
    ) -> some View {
        Section(title) {
            if projects.isEmpty {
                emptyRow("No projects")
            } else {
                ForEach(projects) { project in
                    Label(project.name, systemImage: "folder")
                }
            }
        }
    }

    private var userDeploySection: some View {
        Section(DeploymentsPresentation.everyProjectTitle) {
            if model.userDeploys.isEmpty {
                emptyRow(DeploymentsPresentation.noSkillsDeployed)
            } else {
                ForEach(model.userDeploys) { deploy in
                    deployRow(deploy)
                }
            }
        }
    }

    private var projectDeploySection: some View {
        Section(DeploymentsPresentation.oneProjectTitle) {
            if model.projectDeploys.isEmpty {
                emptyRow(DeploymentsPresentation.noSkillsDeployed)
            } else {
                ForEach(model.projectDeploys) { deploy in
                    deployRow(deploy)
                }
            }
        }
    }

    @ViewBuilder
    private func deployRow(_ deploy: MachineDetailModel.DeploySummary) -> some View {
        let skill = RelatedSkills.resolve(slug: deploy.skillSlug, in: skills)
        if let skill {
            Button(action: { onReveal(skill) }, label: {
                deployLabel(deploy, skill: skill)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            })
            .buttonStyle(.plain)
        } else {
            deployLabel(deploy, skill: nil)
        }
    }

    private func deployLabel(_ deploy: MachineDetailModel.DeploySummary, skill: Skill?) -> some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: Spacing.xxs) {
                Text(deploy.platformName)
                if let projectName = deploy.projectName {
                    Text(projectName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } label: {
            if let skill {
                Label(skill.name, systemImage: "doc.text")
            } else {
                Text(deploy.displaySkillSlug)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
    }
}
