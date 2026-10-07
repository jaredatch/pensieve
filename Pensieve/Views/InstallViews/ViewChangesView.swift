import SwiftData
import SwiftUI

struct ViewChangesView: View {
    @Bindable var model: ViewChangesViewModel
    @Bindable var library: SkillLibraryViewModel
    let onUpdate: () -> Void
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(DesignTokens.changesSidebarWidth)
        } detail: {
            VStack(spacing: 0) {
                separator
                content
            }
            .navigationTitle(model.row.map { "Changes to \($0.skillName)" } ?? "View Changes")
            .navigationSubtitle(model.row.map(ViewChangesPresentation.subtitle) ?? "")
            .toolbar { changesToolbar }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .accessibilityIdentifier("view-changes-content")
        .frame(minWidth: DesignTokens.changesWindowWidth,
               minHeight: DesignTokens.changesWindowHeight - DesignTokens.changesToolbarHeight)
        .background(ViewChangesWindowLifecycle(onClose: model.close))

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
            List(selection: Binding(get: { model.selectedFilePath }, set: { path in
                if let path { model.selectFile(path: path) }
            })) {
                ForEach(model.files, id: \.path) { file in
                    ViewChangesFileRow(file: file)
                        .padding(.vertical, DesignTokens.changesFileRowSpacing / 2)
                        .tag(file.path)
                        .listRowSeparator(.hidden)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(ViewChangesPresentation.accessibilityLabel(file))
                        .accessibilityIdentifier("changes-file-" + file.path)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .accessibilityLabel("Changed Files")
        }
        .padding(.horizontal, DesignTokens.changesSidebarInset * 2)
        .accessibilityIdentifier("changes-files")
    }

    @ToolbarContentBuilder private var changesToolbar: some ToolbarContent {
        if #available(macOS 26, *) {
            heading.sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.flexible, placement: .automatic)
        } else { heading }
        ToolbarItem(id: "changes-github", placement: .primaryAction) {
            Button("View on GitHub") {
                if let url = model.row?.compareURL { openURL(url) }
            }
            .controlSize(.large)
            .font(DesignTokens.changesButton)
            .frame(width: DesignTokens.changesGitHubButtonWidth, height: DesignTokens.changesButtonHeight)
            .disabled(model.row?.compareURL == nil)
            .accessibilityIdentifier("changes-github")
        }
        ToolbarItem(id: "changes-update", placement: .primaryAction) {
            Button("Update", action: onUpdate)
                .controlSize(.large)
                .font(DesignTokens.changesButton)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .frame(width: DesignTokens.changesUpdateButtonWidth, height: DesignTokens.changesButtonHeight)
                .disabled(!model.canUpdate || library.libraryUnavailable)
                .accessibilityIdentifier("changes-update")
        }
    }

    private var heading: some ToolbarContent {
        ToolbarItem(id: "changes-heading", placement: .navigation) {
            VStack(alignment: .leading, spacing: DesignTokens.changesTitleGap) {
                Text(model.row.map { "Changes to \($0.skillName)" } ?? "View Changes")
                    .font(DesignTokens.changesTitle)
                if let row = model.row {
                    Text(verbatim: ViewChangesPresentation.subtitle(row))
                        .font(DesignTokens.changesSubtitle).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("changes-heading")
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
                if model.needsRecheck {
                    Button("Re-check") { model.recheck(context: context) }
                        .disabled(!model.canRecheck)
                        .accessibilityIdentifier("changes-recheck")
                } else {
                    Button("Retry") { retry() }.accessibilityIdentifier("changes-retry")
                }
            }
        case let .stale(message):
            EmptyStateView("Preview No Longer Current", description: message) {
                if model.needsRecheck {
                    Button("Re-check") { model.recheck(context: context) }
                        .disabled(!model.canRecheck)
                        .accessibilityIdentifier("changes-recheck")
                }
            }
        case let .loaded(preview):
            if preview.isIncomplete {
                Text(verbatim: ViewChangesPresentation.incompleteNote(preview.unreadFileCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(Spacing.sm)
            }
            if let file = model.selectedFile {
                ViewChangesFileHeader(file: file)
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

}
