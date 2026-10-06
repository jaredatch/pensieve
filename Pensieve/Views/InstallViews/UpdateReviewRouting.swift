import AppKit
import SwiftData
import SwiftUI

/// The production entry points share one presenter and keep sheet selection separate from preview lifetime.
@MainActor
struct UpdateReviewRouting {
    let preview: ViewChangesViewModel
    let updates: UpdatesViewModel
    let library: SkillLibraryViewModel
    let context: ModelContext
    var windows: () -> [NSWindow] = { NSApp.windows }
    let openWindow: (String) -> Void

    func banner(for skill: Skill) -> SkillUpdateAvailableBanner {
        SkillUpdateAvailableBanner(
            upstreamDate: skill.upstreamCommitDate,
            onViewChanges: { presentChanges(skillID: skill.id) },
            onUpdate: { presentUpdates(skillID: skill.id) }
        )
    }

    var sheet: UpdatesView {
        UpdatesView(model: updates, onViewChanges: { presentChanges(skillID: $0.id) })
    }

    var window: ViewChangesView {
        ViewChangesView(model: preview, library: library, onUpdate: {
            guard preview.canUpdate, let skillID = preview.requestedSkillID else { return }
            presentUpdates(skillID: skillID)
        })
    }

    func presentUpdates(skillID: UUID? = nil) {
        let currentWindows = windows()
        let main = WindowPolicy.mainWindow(among: currentWindows)
        WindowPolicy.showMainWindow(among: currentWindows) { openWindow("main") }
        guard updates.isPresented || main?.attachedSheet == nil else { return }
        updates.present(selecting: skillID, library: library)
    }

    func presentChanges(skillID: UUID) {
        ViewChangesWindow.present(skillID: skillID, model: preview, library: library,
                                  context: context, windows: windows()) {
            openWindow(WindowPolicy.changesWindowID)
        }
    }
}
