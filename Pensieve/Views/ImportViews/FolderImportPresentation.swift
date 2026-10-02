import SwiftUI

/// What Import from Folder… presents, kept out of `ContentView`'s body (it sits at its lint budget):
/// the wizard opened at its results step, the "Nothing to Import" alert, and the File-menu notification
/// (⌘⇧I) that starts the flow. (PLAN-30 / 30.2)
struct FolderImportPresentation: ViewModifier {
    @Binding var showWizard: Bool
    @Binding var notice: String?
    let importVM: ImportViewModel
    let writesAllowed: Bool
    let onImportRequested: () -> Void
    /// Every main window (macOS window tabbing can open a second) observes the File-menu
    /// notification; only the one that looks active — key, or main under its own sheet — acts on it,
    /// so ⌘⇧I opens one chooser and the active window's own guards decide.
    @Environment(\.appearsActive) private var appearsActive

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showWizard) {
                ImportWizardView(importVM: importVM, writesAllowed: writesAllowed, startsAtResults: true)
            }
            .alert("Nothing to Import", isPresented: Binding(
                get: { notice != nil }, set: { if !$0 { notice = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(notice ?? "")
            }
            .onReceive(NotificationCenter.default.publisher(for: .importSkills)) { _ in
                guard appearsActive else { return }
                onImportRequested()
            }
    }
}
