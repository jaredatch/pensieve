import SwiftUI

struct UpstreamHistoryDiffSheet: View {
    let sha: String
    let versionBody: String
    let currentBody: String
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("Changes since " + InstalledSkillHistoryPresentation.shortHash(sha))
                .font(.headline)
            ScrollView {
                LineDiffView(
                    this: versionBody,
                    other: SkillHistoryPresentation.previewBody(from: currentBody),
                    thisLabel: "That version",
                    otherLabel: "This copy"
                )
            }
            .frame(minHeight: 420)
            closeButton
        }
        .padding(Spacing.xl)
        .frame(width: 760)
    }

    private var closeButton: some View {
        HStack {
            Spacer()
            Button("Close", action: onClose).keyboardShortcut(.cancelAction)
        }
    }
}

struct LocalEditsDiffSheet: View {
    let title: String
    let summary: String?
    let changes: [UpstreamHistoryLocalChange]
    let onClose: () -> Void

    private var textChanges: [UpstreamHistoryLocalChange] {
        changes.filter { $0.installedText != nil || $0.currentText != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text(title).font(.headline)
            if let summary {
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.xl) {
                    ForEach(textChanges, id: \.path) { change in
                        VStack(alignment: .leading, spacing: Spacing.sm) {
                            Text(change.path)
                                .font(.system(.body, design: .monospaced))
                            LineDiffView(
                                this: change.installedText ?? "",
                                other: change.currentText ?? "",
                                thisLabel: "Installed",
                                otherLabel: "This copy"
                            )
                        }
                    }
                    if textChanges.isEmpty {
                        Text("No text changes are available to compare.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minHeight: 420)
            HStack {
                Spacer()
                Button("Close", action: onClose).keyboardShortcut(.cancelAction)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 760)
    }
}
