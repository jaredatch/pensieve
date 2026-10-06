import SwiftData
import SwiftUI

struct UpdatesView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Bindable var model: UpdatesViewModel
    let onViewChanges: (UpdatesRow) -> Void
    @State private var maximumSheetHeight = DesignTokens.mainWindowMinimumHeight
    private var maximumRowsHeight: CGFloat { max(0, maximumSheetHeight - DesignTokens.updatesChromeHeight) }

    var body: some View {
        let shown = UpdatesSheetPresentation(model)
        VStack(spacing: 0) {
            header(shown)
            selection(shown)
            Divider().frame(height: DesignTokens.updatesDividerHeight)
            content(shown)
            Divider().frame(height: DesignTokens.updatesDividerHeight)
            footer(shown)
        }
        .frame(width: DesignTokens.updatesSheetWidth)
        .background {
            UpdatesSheetWindowSize { height in
                if maximumSheetHeight != height { maximumSheetHeight = height }
            }
        }
        .interactiveDismissDisabled(shown.isApplying)
        .task { model.load(context: context) }
    }

    private func header(_ shown: UpdatesSheetPresentation) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.updatesHeaderGap) {
            Text(shown.title).font(DesignTokens.updatesTitle)
                .frame(height: DesignTokens.updatesTitleLineHeight)
            Text(shown.subtitle)
                .font(DesignTokens.updatesSubtitle)
                .foregroundStyle(.secondary)
                .frame(height: DesignTokens.updatesSubtitleLineHeight)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, DesignTokens.updatesSheetPadding)
        .padding(.horizontal, DesignTokens.updatesSheetPadding)
        .padding(.bottom, DesignTokens.updatesHeaderBottom)
    }

    private func selection(_ shown: UpdatesSheetPresentation) -> some View {
        UpdatesSelectAllCheckbox(title: shown.selectionLabel, selection: shown.selection,
                                 isEnabled: shown.selectionEnabled) { selected in
            if selected { model.selectAll() } else { model.selectNone() }
        }
        .frame(height: DesignTokens.updatesCheckboxHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.updatesSelectionPadding)
    }

    @ViewBuilder
    private func content(_ shown: UpdatesSheetPresentation) -> some View {
        switch shown.content {
        case .loading:
            ProgressView(shown.loadingTitle).padding(DesignTokens.updatesSheetPadding)
        case let .failed(error):
            ContentUnavailableView {
                Label(shown.errorTitle, systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button(shown.retryTitle) { model.load(context: context) }
                    .accessibilityIdentifier("updates-retry")
            }
            .fixedSize(horizontal: false, vertical: true)
        case .empty:
            ContentUnavailableView {
                Label(shown.emptyTitle, systemImage: "checkmark.circle")
            } description: {
                Text(shown.emptyDescription)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .rows:
            ViewThatFits(in: .vertical) {
                rows(shown)
                ScrollView { rows(shown) }
                    .frame(height: maximumRowsHeight)
            }
            .frame(maxHeight: maximumRowsHeight)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func rows(_ shown: UpdatesSheetPresentation) -> some View {
        VStack(spacing: 0) {
            ForEach(shown.rows) { row in
                UpdatesRowView(model: model, shown: row, context: context, onViewChanges: onViewChanges)
                if row.id != shown.rows.last?.id { Divider().frame(height: DesignTokens.updatesDividerHeight) }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func footer(_ shown: UpdatesSheetPresentation) -> some View {
        HStack(spacing: Spacing.sm) {
            Spacer()
            if shown.isApplying { ProgressView().controlSize(.small) }
            Button(shown.cancelTitle) {
                model.cancel()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .frame(width: DesignTokens.updatesCancelWidth, height: DesignTokens.updatesButtonHeight)
            .accessibilityIdentifier("updates-cancel")
            .disabled(!shown.cancelEnabled)
            Button(shown.updateTitle) { model.applySelected(context: context) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .frame(width: DesignTokens.updatesUpdateWidth, height: DesignTokens.updatesButtonHeight)
                .accessibilityIdentifier("updates-apply")
                .disabled(!shown.updateEnabled)
        }
        .font(DesignTokens.updatesSubtitle)
        .controlSize(.large)
        .padding(DesignTokens.updatesFooterPadding)
    }
}
