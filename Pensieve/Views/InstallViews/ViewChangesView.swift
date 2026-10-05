import SwiftData
import SwiftUI

struct ViewChangesView: View {
    @Bindable var model: ViewChangesViewModel
    @Bindable var library: SkillLibraryViewModel
    let onClose: () -> Void
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(DesignTokens.changesSidebarWidth)
        } detail: {
            VStack(spacing: 0) {
                separator
                if let message = model.applyMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(Spacing.sm)
                }
                if model.canRecheck && model.applyMessage != nil {
                    Button("Re-check") { model.recheck(context: context) }
                        .accessibilityIdentifier("changes-recheck")
                        .padding(Spacing.sm)
                }
                content
            }
            .toolbar { changesToolbar }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .accessibilityIdentifier("view-changes-content")
        .frame(minWidth: DesignTokens.changesWindowWidth,
               minHeight: DesignTokens.changesWindowHeight - DesignTokens.changesToolbarHeight)
        .background(ViewChangesWindowLifecycle(onClose: model.close))
        .alert("Replace your local edits?", isPresented: $model.asksToReplaceLocalEdits) {
            Button("Cancel", role: .cancel) { replaceLocalEdits(false) }
                .accessibilityIdentifier("changes-replacement-cancel")
            Button("Replace and Update", role: .destructive) { replaceLocalEdits(true) }
                .accessibilityIdentifier("changes-replace")
        } message: {
            Text("Updating replaces your local copy of this skill, including its local edits.")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let header = ViewChangesPresentation.sidebarHeader(model.state) {
                Text(header)
                .font(DesignTokens.changesFileFolder)
                .foregroundStyle(.secondary)
                .padding(.leading, DesignTokens.changesFileRowHorizontalPadding)
                .padding(.top, DesignTokens.changesSidebarHeaderTop)
                .padding(.bottom, DesignTokens.changesSidebarHeaderBottom)
            }
            ScrollView {
                LazyVStack(spacing: DesignTokens.changesFileRowSpacing) {
                    ForEach(model.files, id: \.path) { file in
                        Button { model.selectFile(path: file.path) } label: {
                            ViewChangesFileRow(file: file, selected: file.path == model.selectedFilePath)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("changes-file-" + file.path)
                    }
                }
            }
        }
        .padding(.horizontal, DesignTokens.changesSidebarInset * 2)
        .accessibilityIdentifier("changes-files")
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: DesignTokens.changesTitleGap) {
            Text(verbatim: model.row.map { "Changes to \($0.skillName)" } ?? "View Changes")
                .font(DesignTokens.changesTitle)
                .lineLimit(1)
            if let row = model.row {
                Text(verbatim: ViewChangesPresentation.subtitle(row))
                    .font(DesignTokens.changesSubtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ToolbarContentBuilder private var changesToolbar: some ToolbarContent {
        ToolbarItem(id: "changes-heading", placement: .navigation) { heading }
        ToolbarItemGroup(placement: .primaryAction) {
            Button("View on GitHub") {
                if let url = model.row?.compareURL { openURL(url) }
            }
            .controlSize(.large)
            .font(DesignTokens.changesButton)
            .frame(width: DesignTokens.changesGitHubButtonWidth, height: DesignTokens.changesButtonHeight)
            .disabled(model.row?.compareURL == nil)
            .accessibilityIdentifier("changes-github")
            if model.isApplying { ProgressView().controlSize(.small) }
            Button("Update") { model.requestUpdate(library: library, context: context, onSuccess: onClose) }
                .controlSize(.large)
                .font(DesignTokens.changesButton)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .frame(width: DesignTokens.changesUpdateButtonWidth, height: DesignTokens.changesButtonHeight)
                .disabled(!model.canUpdate || library.libraryUnavailable)
                .accessibilityIdentifier("changes-update")
        }
    }

    private var separator: some View {
        DesignTokens.changesDividerFill.frame(height: DesignTokens.changesDividerHeight)
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .idle:
            EmptyStateView("No Update Selected")
        case .loading:
            ProgressView("Loading changes…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            EmptyStateView("Couldn't Load Changes", description: message) {
                if model.canRecheck {
                    Button("Re-check") { model.recheck(context: context) }.accessibilityIdentifier("changes-recheck")
                } else {
                    Button("Retry") { retry() }.accessibilityIdentifier("changes-retry")
                }
            }
        case let .stale(message):
            EmptyStateView("Preview No Longer Current", description: message)
        case let .loaded(preview):
            if preview.isIncomplete {
                Text(verbatim: ViewChangesPresentation.incompleteNote(preview.unreadFileCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(Spacing.sm)
            }
            if let file = model.selectedFile {
                HStack {
                    Text(verbatim: file.path).font(DesignTokens.changesFilePath).lineLimit(1)
                    Spacer()
                    Text(verbatim: ViewChangesPresentation.summary(file))
                        .font(DesignTokens.changesSummary).foregroundStyle(.secondary)
                }
                .padding(.horizontal, DesignTokens.changesToolbarInset)
                .frame(height: DesignTokens.changesFileHeaderHeight)
                if let reason = ViewChangesPresentation.unavailableReason(file) {
                    EmptyStateView(ViewChangesPresentation.unavailableTitle(file), description: reason)
                } else if let diff = file.diff {
                    UnifiedDiffView(diff: diff).id(file.path)
                }
            } else {
                EmptyStateView("No File Changes", description: preview.isIncomplete
                    ? "Use View on GitHub to see the files outside this preview."
                    : "The local files already match this update.")
            }
        }
    }

    private func retry() {
        model.retry(context: context, folderRevisions: library.folderChangeRevisions)
    }

    private func replaceLocalEdits(_ replace: Bool) {
        model.confirmReplacement(replace, library: library, context: context, onSuccess: onClose)
    }
}

private struct ViewChangesFileRow: View {
    let file: PinnedSkillFileDiff
    let selected: Bool

    var body: some View {
        let parent = (file.path as NSString).deletingLastPathComponent
        HStack(spacing: DesignTokens.changesFileRowGap) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .frame(width: DesignTokens.changesFileGlyphWidth, height: DesignTokens.changesFileGlyphHeight)
            VStack(alignment: .leading, spacing: DesignTokens.changesFileFolderGap) {
                Text(verbatim: (file.path as NSString).lastPathComponent).font(DesignTokens.changesFileName).lineLimit(1)
                if !parent.isEmpty {
                    Text(verbatim: parent).font(DesignTokens.changesFileFolder).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: DesignTokens.changesCountGap) {
                if let counts = ViewChangesPresentation.sidebarCounts(file) {
                    let added = counts.added
                    let removed = counts.removed
                    if added > 0 || removed == 0 { Text("+\(added)").foregroundStyle(Color(nsColor: .systemGreen)) }
                    if removed > 0 { Text("−\(removed)").foregroundStyle(Color(nsColor: .systemRed)) }
                } else {
                    if case .modeOnly = file.content {
                        Text("Mode").foregroundStyle(.secondary)
                    } else {
                        Text(verbatim: ViewChangesPresentation.summary(file)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .font(DesignTokens.changesCount)
        }
        .padding(.horizontal, DesignTokens.changesFileRowHorizontalPadding)
        .frame(height: parent.isEmpty ? DesignTokens.changesFileRowHeight : DesignTokens.changesNestedFileRowHeight)
        .background(selected ? DesignTokens.changesFileRowSelectedFill : .clear,
                    in: RoundedRectangle(cornerRadius: DesignTokens.changesFileRowCornerRadius))
        .contentShape(Rectangle())
        .accessibilityLabel(file.path + ", " + ViewChangesPresentation.summary(file))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
