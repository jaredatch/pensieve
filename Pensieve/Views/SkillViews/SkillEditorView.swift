import SwiftUI

struct SkillEditorView: View {
    let skill: Skill
    @Bindable var library: SkillLibraryViewModel

    // The body to (re)load into the editor, and a token bumped on each load event. The editor is
    // pushed ONLY when this token changes (a load/reload) — never on incidental SwiftUI updates or
    // user keystrokes — so a stale push can't clobber live edits (the 02.3-class clobber bug).
    @State private var bodyToLoad: String = ""
    @State private var loadVersion: Int = 0
    @State private var editorText: String = "" // what the editor holds, by the last load or keystroke

    private var isDirty: Bool { library.hasUnsavedChanges(for: skill) }

    var body: some View {
        VStack(spacing: 0) {
            // Editor — CodeMirror in a hardened WKWebView. Every keystroke updates the
            // draft on the view model; nothing reaches disk until Save.
            MarkdownEditorWebView(
                bodyToLoad: bodyToLoad,
                loadVersion: loadVersion,
                onContentChange: { newValue in
                    editorText = newValue
                    library.noteEditorChanged(skill, body: newValue)
                }
            )
            .background(Color(.textBackgroundColor))
        }
        .onAppear { loadBody() }
        .onChange(of: skill.id) { _, _ in loadBody() }
        // An accepted external change, a discard, a restore, or the app's own write: reload the file only
        // while nothing is unsaved — a dirty draft is the user's, and the view model has asked about it.
        .onChange(of: library.reloadToken) { _, _ in reloadIfClean() }
        .onChange(of: library.appWriteRevision) { _, _ in reloadIfClean() }
    }

    /// The app's own write or an accepted change: reload only while nothing is unsaved, and push only when the
    /// file differs from what the editor shows — a push replaces the document (the caret moves, a keystroke in
    /// flight between a save and its push is lost), so the editor keeps its text when the file already matches
    /// (batch Layer-2).
    private func reloadIfClean() {
        guard !isDirty else { return }
        let body = library.editorBody(for: skill)
        guard SkillParser.canonicalBody(editorText) != body else { return }
        push(body)
    }

    /// The draft when one exists, else the file; either way the fingerprint is re-seeded to the file.
    private func loadBody() { push(library.editorBody(for: skill)) }

    private func push(_ body: String) {
        editorText = body
        bodyToLoad = body
        loadVersion += 1
    }
}
