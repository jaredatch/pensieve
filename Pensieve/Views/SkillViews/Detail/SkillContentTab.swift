import SwiftUI

/// The file row — the pulldown over the bundle's text files, Revert and Save while SKILL.md's draft is
/// dirty, the rendered/source toggle — then the rendered preview or the source (the frames `Skills /
/// Details — Content` and `— Content (editing)`). SKILL.md's source is the editor with explicit save
/// while another file's source is the same editor read-only; a file that is not markdown has no
/// rendered form. The owner decides a file or mode change (each is a way out PLAN-33's gate may refuse), so
/// this view reports the choice and shows the value.
struct SkillContentTab: View {
    static let sourceEditorMinimumHeight: CGFloat = 240

    let skill: Skill
    let snapshot: DetailContentSnapshot
    @Bindable var library: SkillLibraryViewModel
    let presentation: SkillContentPresentation.Resolved
    let onSelectFile: (String) -> Void
    let onSelectMode: (SkillContentPresentation.Mode) -> Void
    @State private var loadedOtherFile: SkillContentFileText?

    private var choice: SkillContentPresentation.FileChoice { presentation.choice }
    private var file: String { choice.relativePath }
    private var shownMode: SkillContentPresentation.Mode { presentation.shownMode }
    private var isDirty: Bool { library.hasUnsavedChanges(for: skill) }
    private var otherFileKey: String {
        "\(skill.id)|\(file)|\(library.reloadToken)|\(library.appWriteRevision)|\(library.watcherEventSequence)"
    }
    private var otherFileText: String? {
        loadedOtherFile?.text(for: skill.id, relativePath: file)
    }

    var body: some View {
        VStack(spacing: 0) {
            fileRow
                .padding(.horizontal, Spacing.lg)
                .padding(.top, DesignTokens.contentRowTop)
                .padding(.bottom, Spacing.sm)
            Divider()
            content
        }
        // A bundle file's change reaches the app only as a watcher event (the library reads SKILL.md's body as
        // an echo), so the sequence is in the key beside the two SKILL.md signals.
        .task(id: otherFileKey) {
            guard !choice.isSkillFile else {
                loadedOtherFile = nil
                return
            }
            loadedOtherFile = SkillContentFileText(
                skillID: skill.id,
                relativePath: choice.relativePath,
                text: library.bundleFileText(skill, relativePath: choice.relativePath) ?? ""
            )
        }
    }

    private var fileRow: some View {
        HStack(spacing: Spacing.sm) {
            Picker("File", selection: Binding(get: { file }, set: { onSelectFile($0) })) {
                ForEach(presentation.choices) { Text($0.relativePath).tag($0.relativePath) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.large)
            // A pop-up button measures its items when it is built; rebuilt when the list changes, so the width
            // is the list's, not whichever list it first appeared with (34.2-m).
            .id(presentation.choices.map(\.relativePath))
            // A pop-up button is as wide as its widest item: capped, it gives way in a narrow column instead of
            // pushing the row past it, and its menu still lists every full path (Layer-1 over 34.2).
            .frame(maxWidth: 240, alignment: .leading)
            Spacer()
            if choice.isSkillFile, shownMode == .source, isDirty {
                Button("Revert") { library.discardDraft(skill) }
                    .controlSize(.large)
                Button("Save") { library.saveDraft(skill) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            Picker("View", selection: Binding(get: { shownMode }, set: { onSelectMode($0) })) {
                Image(systemName: "doc.text")
                    .tag(SkillContentPresentation.Mode.rendered)
                    .help("Rendered")
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .tag(SkillContentPresentation.Mode.source)
                    .help("Source")
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.large)
            .fixedSize()
            .disabled(!choice.canRender)
        }
    }

    func preview(markdownBody: String, skillsBase: String) -> SkillPreviewView {
        SkillPreviewView(markdownBody: markdownBody, scrolls: false,
                         skillDirectory: PreviewImageLoader.skillDirectory(slug: skill.directoryName, base: skillsBase),
                         documentRelativePath: file,
                         imageRevision: library.watcherEventSequence,
                         imageLoader: PreviewImageLoader(fileService: library.fileService))
    }

    @ViewBuilder private var content: some View {
        if choice.isSkillFile {
            if shownMode == .rendered {
                preview(markdownBody: snapshot.body, skillsBase: Constants.pensieveSkillsDir)
            } else {
                SkillEditorView(skill: skill, library: library)
                    // One editor per skill: switching skills tears the prior WKWebView down, so a late
                    // contentDidChange from the old skill can never reach the new skill's draft (PLAN-03 / 03.4).
                    .id(skill.id)
                    .frame(minHeight: Self.sourceEditorMinimumHeight, maxHeight: .infinity)
            }
        } else if shownMode == .rendered {
            preview(markdownBody: otherFileText ?? "", skillsBase: Constants.pensieveSkillsDir)
        } else if let otherFileText {
            MarkdownEditorWebView(bodyToLoad: otherFileText, loadVersion: otherFileText.hashValue, readOnly: true)
                .id(file)
                .frame(minHeight: Self.sourceEditorMinimumHeight, maxHeight: .infinity)
                .background(Color(.textBackgroundColor))
        } else {
            Color(.textBackgroundColor)
                .frame(minHeight: Self.sourceEditorMinimumHeight, maxHeight: .infinity)
        }
    }
}

/// The last bundle-file read stays visible while a new signal-keyed read for the same selection runs. A
/// different skill or file does not borrow it, and returning to SKILL.md clears it in `SkillContentTab`.
struct SkillContentFileText: Equatable {
    let skillID: UUID
    let relativePath: String
    let text: String

    func text(for skillID: UUID, relativePath: String) -> String? {
        self.skillID == skillID && self.relativePath == relativePath ? text : nil
    }
}
