import SwiftUI

struct InstallPickerView: View {
    @Bindable var model: SkillInstallViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Found \(model.candidates.count) Skills")
                        .font(.title2)
                    Text("Select which skills to install into Pensieve.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("All") { model.selectAll() }
                Button("None") { model.selectNone() }
            }
            .padding(Spacing.lg)

            Divider()
            List(model.candidates, id: \.path) { candidate in
                InstallCandidateRow(model: model, candidate: candidate)
            }
        }
    }
}

struct InstallCandidateSummary: View {
    let candidate: SkillCandidate

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(candidate.name ?? candidate.slug)
                .font(.headline)
            if let description = candidate.skillDescription {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text(candidate.path.isEmpty ? "Repository root" : candidate.path)
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct InstallCandidateRow: View {
    @Bindable var model: SkillInstallViewModel
    let candidate: SkillCandidate

    var body: some View {
        Toggle(
            isOn: Binding(
                get: { model.isSelected(candidate) },
                set: { _ in model.toggleSelection(candidate) }
            )
        ) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                InstallCandidateSummary(candidate: candidate)
                if let reason = candidate.unavailableReason {
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .toggleStyle(.checkbox)
        .disabled(!candidate.isInstallable)
        .padding(.vertical, Spacing.xs)
    }
}
