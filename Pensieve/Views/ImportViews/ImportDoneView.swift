import SwiftUI

struct ImportDoneView: View {
    @Bindable var importVM: ImportViewModel
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: Spacing.xxl) {
            Spacer()

            Image(systemName: importVM.importedSkillCount > 0 ? "checkmark.circle.fill" : "tray")
                .font(.system(size: 48))
                .foregroundStyle(importVM.importedSkillCount > 0 ? .green : .secondary)

            Text(importVM.doneTitle)
                .font(.title.bold())
            Text(importVM.doneMessage)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            ImportScanSummary(summary: importVM.scanSummary)

            if !importVM.importNotices.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        ForEach(Array(importVM.importNotices.enumerated()), id: \.offset) { _, notice in
                            Text(verbatim: notice)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.sm)
                }
                .frame(maxHeight: 100)
            }

            if let error = importVM.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer()

            HStack {
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .padding()
    }
}
