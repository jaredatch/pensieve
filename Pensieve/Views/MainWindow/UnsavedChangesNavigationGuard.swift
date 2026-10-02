import SwiftUI

/// The ways out SwiftUI decides before anyone can veto them — a row in the Skills list, a section in the
/// sidebar, a search that hides the edited row (each an AppKit table underneath, which moves its selection
/// first) — and the window's close. The selection sheet follows the move: Save or Don't Save lets it
/// stand; Cancel puts the previous selection back, its drafts intact, with the search and filter cleared so
/// the rows are on screen (the list prunes a hidden row from the selection, which would ask again). The
/// close guard's Save or Don't Save asks the window to close again through `performClose`: the proxy
/// finds no draft and lets SwiftUI close it its own way — a bare `NSWindow.close()` leaves the scene
/// believing the window is still open, and reopening from the Dock or the menu bar then does nothing.
struct UnsavedChangesNavigationGuard: ViewModifier {
    @Bindable var library: SkillLibraryViewModel
    @Binding var section: SidebarSection
    @Binding var entitySelection: EntitySelection?
    @Binding var selectedSkills: Set<Skill>
    @Binding var filter: SkillListFilter
    @Binding var searchText: String
    /// Set while a Cancel puts the selection back: that change is the guard's own, not a way out. Without
    /// it two dirty skills ask about each other without end — Cancel on A reveals A, which leaves B; Cancel
    /// on B reveals B, which leaves A.
    @State private var restoring = false

    func body(content: Content) -> some View {
        content
            .onChange(of: selectedSkills) { old, new in
                if restoring { restoring = false; return }
                // The skills being left are the ones that were selected and no longer are — a row deleted
                // from under the editor leaves the same way; a selection that still holds the edited skill
                // (⌘-click) is not a way out. The whole departing set goes to the gate, which asks about each
                // dirty one in turn and re-reads the rest after every answer.
                let departing = Array(old.subtracting(new))
                guard departing.contains(where: { library.hasUnsavedChanges(for: $0) }) else { return }
                library.confirmLeaving(departing) { proceed in
                    guard !proceed else { return }
                    // Cancel: the previous selection comes back — the rows whose files are still there, read
                    // now, not when the question was asked (a row can go while the sheet is up). A row that is
                    // gone stays unselected; its draft waits for the next global way out (a vanished file
                    // refuses Save; Don't Save discards it). Nothing to restore when the selection already is
                    // the previous one.
                    let present = old.filter { library.hasReadableSkillFile($0.directoryName) }
                    guard let first = present.min(by: { $0.directoryName < $1.directoryName }),
                          present != selectedSkills else { return }
                    restoring = true
                    revealSkill(first, section: &section, entity: &entitySelection,
                                selectedSkills: &selectedSkills, filter: &filter, searchText: &searchText)
                    if present.count > 1 { selectedSkills = present }
                }
            }
            .background(WindowCloseGuard { window in
                guard library.hasUnsavedChanges else { return true }
                library.confirmLeavingAnyDraft { proceed in if proceed { window.performClose(nil) } }
                return false
            })
    }
}
