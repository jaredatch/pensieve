import SwiftUI

struct ImportDoneView: View {
    @Bindable var importVM: ImportViewModel
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: Spacing.xxl) {
            Spacer()

            Image(systemName: importVM.hasResults ? "checkmark.circle.fill" : "tray")
                .font(.system(size: 48))
                .foregroundStyle(importVM.hasResults ? .green : .secondary)

            if importVM.hasResults {
                Text("Import Complete")
                    .font(.title.bold())
                Text("\(importVM.selectedSkills.count) skills imported into Pensieve.")
                    .foregroundStyle(.secondary)
            } else {
                Text("No Skills Found")
                    .font(.title.bold())
                Text("No existing skills were found. Create your first skill to get started.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

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
