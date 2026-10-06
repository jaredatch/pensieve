import SwiftData
import SwiftUI

struct UpdatesRowView: View {
    @Bindable var model: UpdatesViewModel
    let shown: UpdatesSheetPresentation.Row
    private var row: UpdatesRow { shown.row }
    let context: ModelContext
    let onViewChanges: (UpdatesRow) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.updatesLocalEditsGap) {
            HStack(alignment: .top, spacing: Spacing.sm) {
                Toggle(shown.name, isOn: Binding(
                    get: { shown.isSelected },
                    set: { model.setSelection($0, for: row) }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .frame(width: DesignTokens.updatesRowBodyOffset - Spacing.sm,
                       height: DesignTokens.updatesCheckboxHeight)
                .accessibilityIdentifier("updates-select-" + row.id.uuidString)
                .disabled(!shown.selectionEnabled)
                VStack(alignment: .leading, spacing: DesignTokens.updatesRowMetaGap) {
                    nameAndSource.frame(minHeight: DesignTokens.updatesRowNameLineHeight, alignment: .leading)
                    coordinates.frame(minHeight: DesignTokens.updatesRowCommitsLineHeight, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, DesignTokens.updatesRowBodyTop)
                Button(shown.changesTitle) { onViewChanges(row) }
                    .font(DesignTokens.updatesChangesButton)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.tint)
                    .accessibilityIdentifier("updates-changes-" + row.id.uuidString)
                    .disabled(!shown.changesEnabled)
                    .padding(.top, DesignTokens.updatesRowMetaGap)
            }
            if let copy = shown.localEditsCopy {
                localEdits(copy).padding(.leading, DesignTokens.updatesRowBodyOffset)
            }
            statusView
        }
        .padding(DesignTokens.updatesRowPadding)
    }

    private var nameAndSource: Text {
        Text(shown.name).font(DesignTokens.updatesRowName)
            + Text(shown.source)
            .font(DesignTokens.updatesRowSource).foregroundColor(.secondary)
    }

    private var coordinates: Text {
        Text(shown.commits)
            .font(DesignTokens.updatesRowCommits).foregroundColor(.secondary)
            + Text(shown.age).font(DesignTokens.updatesRowAge).foregroundColor(.secondary)
    }

    private func localEdits(_ copy: String) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.updatesLocalEditsContentGap) {
            HStack(alignment: .top, spacing: DesignTokens.updatesLocalEditsIconGap) {
                Image(systemName: "exclamationmark.triangle")
                    .frame(width: DesignTokens.updatesLocalEditsIconSize,
                           height: DesignTokens.updatesLocalEditsIconSize)
                    .foregroundStyle(.orange)
                Text(copy)
                    .font(DesignTokens.updatesRowSource)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle(shown.replaceTitle, isOn: Binding(
                get: { shown.replacementConfirmed },
                set: { model.setDriftConfirmation($0, for: row) }
            ))
            .font(DesignTokens.updatesRowSource)
            .toggleStyle(.checkbox)
            .frame(height: DesignTokens.updatesCheckboxHeight)
            .accessibilityIdentifier("updates-replace-" + row.id.uuidString)
            .disabled(!shown.replacementEnabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.updatesLocalEditsPadding)
        .background(DesignTokens.updatesLocalEditsFill,
                    in: RoundedRectangle(cornerRadius: DesignTokens.updatesLocalEditsCornerRadius))
    }

    @ViewBuilder
    private var statusView: some View {
        switch shown.status {
        case .idle: EmptyView()
        case .confirmationRequired:
            Label(shown.statusText ?? "",
                  systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        case .updating:
            HStack(spacing: Spacing.sm) {
                ProgressView().controlSize(.small)
                Text(shown.statusText ?? "").font(.caption).foregroundStyle(.secondary)
            }
        case .updated:
            Label(shown.statusText ?? "", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        case .failed:
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                Label(shown.statusText ?? "", systemImage: "xmark.circle")
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                if shown.showsRecheck {
                    Button(shown.recheckTitle) { model.recheck(row, context: context) }
                        .controlSize(.small)
                        .disabled(!shown.recheckEnabled)
                }
            }
        }
    }
}
