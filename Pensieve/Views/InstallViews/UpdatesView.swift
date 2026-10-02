import SwiftData
import SwiftUI

struct UpdatesView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Bindable var model: UpdatesViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 760, height: 540)
        .task { model.load(context: context) }
        .sheet(item: $model.presentedDiff) { diff in
            UpdatesDiffView(diff: diff, onClose: model.dismissDiff)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Skill Updates")
                    .font(.title2)
                Text("Review pinned changes before replacing your local copies.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("All") { model.selectAll() }
                .disabled(model.isApplying || model.rows.isEmpty)
            Button("None") { model.selectNone() }
                .disabled(model.isApplying || model.rows.isEmpty)
        }
        .padding(Spacing.lg)
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading {
            ProgressView("Checking local copies…")
        } else if let error = model.loadError {
            ContentUnavailableView {
                Label("Couldn't Load Updates", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Retry") { model.load(context: context) }
            }
        } else if model.rows.isEmpty {
            ContentUnavailableView {
                Label("No Updates Available", systemImage: "checkmark.circle")
            } description: {
                Text("Your checked GitHub skills are current.")
            }
        } else {
            List(model.rows) { row in
                UpdatesRowView(model: model, row: row, context: context)
            }
            .listStyle(.inset)
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { close() }
                .keyboardShortcut(.cancelAction)
            Text("\(model.selectedCount) selected")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if model.isApplying {
                ProgressView()
                    .controlSize(.small)
            }
            Button("Update Selected") { model.applySelected(context: context) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!model.canApply)
        }
        .padding(Spacing.md)
    }

    private func close() {
        model.cancel()
        dismiss()
    }
}

private struct UpdatesRowView: View {
    @Bindable var model: UpdatesViewModel
    let row: UpdatesRow
    let context: ModelContext

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .top, spacing: Spacing.md) {
                Toggle(isOn: Binding(
                    get: { model.isSelected(row) },
                    set: { _ in model.toggleSelection(row) }
                )) {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(row.skillName)
                            .font(.headline)
                        UpdateSourceView(
                            repositoryDisplay: row.repositoryDisplay,
                            repositoryPath: row.repositoryPath
                        )
                        coordinateLine(
                            "Installed",
                            date: row.installedDate,
                            commit: row.shortInstalledCommit
                        )
                        coordinateLine(
                            "Available",
                            date: row.updateDate,
                            commit: row.shortUpstreamCommit
                        )
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(model.isApplying)

                Spacer()
                Button("View Changes") { model.viewChanges(for: row, context: context) }
                    .disabled(
                        model.isApplying || model.diffLoadingSkillID != nil
                            || model.recheckingSkillID != nil
                    )
            }

            if row.driftedLocally {
                Toggle(isOn: Binding(
                    get: { model.confirmedDriftSkillIDs.contains(row.id) },
                    set: { model.setDriftConfirmation($0, for: row) }
                )) {
                    Text("This skill has local edits — updating will overwrite them")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .toggleStyle(.checkbox)
                .disabled(model.isApplying)
                .padding(.leading, Spacing.xxl)
            }

            statusView
                .padding(.leading, Spacing.xxl)
        }
        .padding(.vertical, Spacing.xs)
    }

    private func coordinateLine(_ label: String, date: Date, commit: String) -> some View {
        Text("\(label) \(date.formatted(date: .abbreviated, time: .omitted)) · \(commit)")
            .font(.caption)
            .foregroundStyle(.tertiary)
    }

    @ViewBuilder
    private var statusView: some View {
        switch model.status(for: row) {
        case .idle:
            EmptyView()
        case .confirmationRequired:
            Label("Confirm the overwrite for this skill, then update again.",
                  systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        case .updating:
            HStack(spacing: Spacing.sm) {
                ProgressView().controlSize(.small)
                Text("Updating…").font(.caption).foregroundStyle(.secondary)
            }
        case .updated:
            Label("Updated", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case let .failed(message, offersRecheck):
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                Label(message, systemImage: "xmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
                if offersRecheck {
                    Button("Re-check") { model.recheck(row, context: context) }
                        .controlSize(.small)
                        .disabled(model.recheckingSkillID != nil)
                }
            }
        }
    }
}

private struct UpdatesDiffView: View {
    let diff: UpdatesDiffPresentation
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Changes to \(diff.skillName)")
                        .font(.title2)
                    UpdateSourceView(
                        repositoryDisplay: diff.repositoryDisplay,
                        repositoryPath: diff.repositoryPath
                    )
                }
                Spacer()
                if let compareURL = diff.compareURL {
                    Link("View full diff on GitHub", destination: compareURL)
                }
            }
            .padding(Spacing.lg)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                LineDiffView(
                    this: diff.currentSkillMarkdown,
                    other: diff.upstreamSkillMarkdown,
                    thisLabel: "Current",
                    otherLabel: "Pinned Update"
                )
                .padding(Spacing.lg)
            }
            Divider()
            HStack {
                Spacer()
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(Spacing.md)
        }
        .frame(width: 860, height: 540)
    }
}

private struct UpdateSourceView: View {
    let repositoryDisplay: String
    let repositoryPath: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Image(systemName: repositoryDisplay.isEmpty
                ? "exclamationmark.triangle"
                : "arrow.triangle.branch")
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(repositoryDisplay.isEmpty ? "Source unavailable" : repositoryDisplay)
                    .font(.callout)
                if !repositoryPath.isEmpty {
                    Text(repositoryPath)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .foregroundStyle(repositoryDisplay.isEmpty ? .secondary : .primary)
    }
}
