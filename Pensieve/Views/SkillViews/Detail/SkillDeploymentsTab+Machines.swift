import SwiftUI

extension SkillDeploymentsTab {
    func thisMacSection(_ section: DeploymentsPresentation.MacSection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("This Mac")
            groupBox {
                groupTextRow(
                    DeploymentsPresentation.thisMacDescription,
                    font: DesignTokens.groupDescription,
                    color: DesignTokens.groupDescriptionColor,
                    showsSeparator: true
                )
                platformRows(section.rows, emptyText: section.emptyText) { on, row in
                    setLocal(on, platform: row.platform, target: .userWide)
                }
            }
        }
    }

    func remoteMachineSection(_ machine: DeploymentsPresentation.MachineSection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle(machine.name)
            groupBox {
                groupTextRow(
                    machine.description,
                    font: DesignTokens.groupDescription,
                    color: DesignTokens.groupDescriptionColor,
                    showsSeparator: true
                )
                platformRows(machine.rows, emptyText: machine.emptyText) { on, row in
                    setRemote(on, machineID: machine.id, projectKey: nil, platform: row.platform)
                }
            }
        }
    }

    func projectsSection(_ rows: [DeploymentsPresentation.ProjectRow]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("Projects")
            groupBox {
                groupTextRow(
                    DeploymentsPresentation.projectsDescription,
                    font: DesignTokens.groupDescription,
                    color: DesignTokens.groupDescriptionColor,
                    showsSeparator: true
                )
                if rows.isEmpty {
                    emptyGroupRow(DeploymentsPresentation.noProjects)
                } else {
                    ForEach(rows) { row in projectRows(row, allRows: rows) }
                }
                addProjectFooter
            }
        }
    }

    @ViewBuilder func projectRows(
        _ row: DeploymentsPresentation.ProjectRow,
        allRows: [DeploymentsPresentation.ProjectRow]
    ) -> some View {
        let expanded = presentation.expandedProjects.contains(row.id)
        let isLast = row.id == allRows.last?.id
        projectDisclosureRow(
            row,
            expanded: expanded,
            showsSeparator: !isLast || (expanded && !row.platforms.isEmpty)
        )
        if expanded {
            ForEach(row.platforms) { platformRow in
                platformToggle(
                    platformRow,
                    nested: true,
                    showsSeparator: !isLast || platformRow.id != row.platforms.last?.id
                ) { on in
                    set(on, platform: platformRow.platform, projectID: row.id)
                }
            }
        }
    }

    @ViewBuilder func platformRows(
        _ rows: [DeploymentsPresentation.PlatformRow],
        emptyText: String?,
        onChange: @escaping (Bool, DeploymentsPresentation.PlatformRow) -> Void
    ) -> some View {
        if let emptyText {
            emptyGroupRow(emptyText)
        } else {
            ForEach(rows) { row in
                platformToggle(row, showsSeparator: row.id != rows.last?.id) { on in
                    onChange(on, row)
                }
            }
        }
    }

    func emptyGroupRow(_ text: String) -> some View {
        groupTextRow(
            text,
            font: DesignTokens.groupEmpty,
            color: DesignTokens.groupEmptyColor,
            showsSeparator: false
        )
    }

    func set(_ on: Bool, platform: PlatformTarget, projectID: DeploymentProjectID) {
        switch projectID {
        case let .local(id):
            guard let project = projects.first(where: { $0.id == id }) else { return }
            setLocal(on, platform: platform, target: .project(project))
        case let .remote(machineID, projectKey):
            setRemote(on, machineID: machineID, projectKey: projectKey, platform: platform)
        }
    }

    func setLocal(_ on: Bool, platform: PlatformTarget, target: DeployTarget) {
        do {
            _ = try intentModel.set(
                on, skill: skill, platform: platform, target: target, context: context
            )
        } catch {
            // The model retains the actionable error for this tab's alert.
        }
    }

    func setRemote(_ on: Bool, machineID: String, projectKey: String?, platform: PlatformTarget) {
        do {
            try intentModel.setRemote(
                on, machineID: machineID, projectKey: projectKey,
                skill: skill, platform: platform, context: context
            )
        } catch {
            // The model retains the actionable error for this tab's alert.
        }
    }
}
