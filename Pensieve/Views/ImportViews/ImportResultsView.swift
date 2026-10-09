import SwiftUI

struct ImportResultsView: View {
    @Bindable var importVM: ImportViewModel
    let onImport: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text("Found \(importVM.discoveredSkills.count) Skills")
                        .font(.title2.bold())
                    Text("Select which skills to import into Pensieve.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                // Select all / none
                Button("All") {
                    importVM.selectedSkills = Set(importVM.discoveredSkills.map(\.sourcePath))
                }
                Button("None") {
                    importVM.selectedSkills.removeAll()
                }
            }
            .padding()

            ImportScanSummary(summary: importVM.scanSummary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .bottom])

            if let error = importVM.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding([.horizontal, .bottom])
            }

            Divider()

            // Skill list
            List {
                // Duplicates warning
                if !importVM.duplicateGroups.isEmpty {
                    Section {
                        Label(
                            "\(importVM.duplicateGroups.count) duplicate group(s) detected",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.orange)
                        .font(.caption)
                    }
                }

                // Skills grouped by platform
                let grouped = Dictionary(grouping: importVM.discoveredSkills) { $0.sourcePlatform }
                ForEach(grouped.keys.sorted(), id: \.self) { platform in
                    Section(platformDisplayName(platform)) {
                        ForEach(grouped[platform] ?? [], id: \.sourcePath) { skill in
                            ImportSkillRow(
                                skill: skill,
                                isSelected: importVM.isSelected(skill),
                                onToggle: { importVM.toggleSelection(skill) }
                            )
                        }
                    }
                }
            }

            Divider()

            // Footer
            HStack {
                Text("\(importVM.selectedSkills.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Import Selected") {
                    onImport()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(importVM.selectedSkills.isEmpty)
            }
            .padding()
        }
    }

    func platformDisplayName(_ key: String) -> String {
        switch key {
        case "claude-code": "Claude Code"
        case "grok": "Grok"
        case "cursor": "Cursor"
        case "codex": "Codex"
        case "folder": "Folder"
        default: key
        }
    }
}

// MARK: - Import Skill Row

private struct ImportSkillRow: View {
    let skill: DiscoveredSkill
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack {
            Toggle(isOn: Binding(get: { isSelected }, set: { _ in onToggle() })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.name)
                        .font(.body)

                    Text(skill.sourcePath)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .toggleStyle(.checkbox)
        }
    }
}
