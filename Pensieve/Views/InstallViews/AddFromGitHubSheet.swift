import SwiftData
import SwiftUI

struct AddFromGitHubSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Bindable var model: SkillInstallViewModel

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
                .padding(Spacing.md)
        }
        .frame(width: 680, height: 520)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            urlEntry
        case .fetching:
            progressView(title: "Fetching Repository", detail: "Looking for installable skills…")
        case .picking:
            if model.isTargetedConfirmation, let candidate = model.candidates.first {
                targetedConfirmation(candidate)
            } else {
                InstallPickerView(model: model)
            }
        case .installing:
            if let collision = model.pendingCollision {
                InstallCollisionView(model: model, collision: collision)
            } else {
                progressView(
                    title: "Installing Skills",
                    detail: "Processed \(model.reports.count) of \(model.selectedCount)…"
                )
            }
        case .done:
            resultsView
        case let .failed(reason):
            failureView(reason)
        }
    }

    private var urlEntry: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Spacer()
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)
            Text(model.isAdoptMode ? "Connect to Repository" : "Add Skills from GitHub")
                .font(.title2)
            Text(urlEntryDescription)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: Spacing.sm) {
                TextField("https://github.com/owner/repository", text: $model.urlText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.fetch() }
                if let reason = model.urlRejectionReason {
                    Label(reason, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if model.parsedURL != nil {
                    Label("Supported GitHub URL", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .frame(maxWidth: 520, alignment: .leading)
        .padding(Spacing.xl)
    }

    private func targetedConfirmation(_ candidate: SkillCandidate) -> some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            if let target = model.adoptTarget, let repository = model.repositoryIdentity {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Link ‘\(target.name)’ to \(repository)?")
                        .font(.title2)
                    Text("Pensieve will track \(repository) as this skill’s source and keep your local copy.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Ready to Install")
                    .font(.title2)
                Text("Pensieve found the skill at the GitHub link you pasted.")
                    .foregroundStyle(.secondary)
            }
            InstallCandidateSummary(candidate: candidate)
            if !candidate.isInstallable, let reason = candidate.unavailableReason {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.xl)
    }

    private func progressView(title: String, detail: String) -> some View {
        VStack(spacing: Spacing.lg) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func failureView(_ reason: String) -> some View {
        ContentUnavailableView {
            Label("Couldn't Fetch Skills", systemImage: "exclamationmark.triangle")
        } description: {
            Text(reason)
        }
    }

    private var resultsView: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Install Results")
                    .font(.title2)
                Text("Each skill was handled independently.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(Spacing.lg)

            Divider()
            List(model.reports) { report in
                InstallReportRow(report: report)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { close() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            switch model.state {
            case .idle:
                Button("Fetch") { model.fetch() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canFetch)
            case .picking:
                Button(model.confirmButtonTitle) {
                    model.confirm(context: context)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!model.canInstall)
            case .failed:
                Button("Retry") { model.retry() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            case .done:
                Button("Done") { close() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            case .fetching, .installing:
                EmptyView()
            }
        }
    }

    private func close() {
        model.cancel()
        dismiss()
    }

    private var urlEntryDescription: String {
        if let target = model.adoptTarget {
            return "Paste a GitHub link that resolves to exactly one skill to connect ‘\(target.name)’ safely."
        }
        return "Paste a repository, skill folder, or SKILL.md link from GitHub."
    }
}

private struct InstallReportRow: View {
    let report: SkillInstallReport

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: Spacing.lg)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(report.candidate.name ?? report.candidate.slug)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Spacing.xs)
    }

    private var icon: String {
        switch report.result {
        case .installed, .adopted: "checkmark.circle.fill"
        case .skipped: "minus.circle"
        case .failed: "xmark.circle.fill"
        }
    }

    private var color: Color {
        switch report.result {
        case .installed, .adopted: .green
        case .skipped: .secondary
        case .failed: .red
        }
    }

    private var message: String {
        switch report.result {
        case let .installed(slug): "Installed as \(slug)"
        case let .adopted(localDrift):
            localDrift ? "Linked to GitHub; kept your local edits" : "Linked existing skill to GitHub"
        case .skipped: "Skipped"
        case let .failed(reason): reason
        }
    }
}
