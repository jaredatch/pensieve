import SwiftUI

/// The detail toolbar's More menu: Reveal in Finder, View on GitHub, Copy Local Path,
/// Check for Updates, Deploy…, then Delete Skill. View on GitHub and Check for Updates are a linked skill's;
/// an unlinked skill gets Connect to Repository… in their place — PLAN-19's adoption entry, which the
/// Repository block carried. Delete keeps ⌘⌫ (File › Delete Skill) and the list's context menu.
struct SkillMoreMenu: View {
    let state: SkillMoreMenuState
    let onReveal: () -> Void
    let onViewOnGitHub: () -> Void
    let onCopyPath: () -> Void
    let onCheckForUpdates: () -> Void
    let onConnect: () -> Void
    let onDeploy: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Menu {
            Button("Reveal in Finder", action: onReveal)
            if state.isLinked {
                Button("View on GitHub", action: onViewOnGitHub)
                    .disabled(!state.canViewOnGitHub)
            }
            Button("Copy Local Path", action: onCopyPath)
            if state.isLinked {
                Button("Check for Updates", action: onCheckForUpdates)
                    .disabled(state.isChecking)
            } else {
                Button("Connect to Repository…", action: onConnect)
            }
            Button("Deploy…", action: onDeploy)
            Divider()
            Button("Delete Skill", role: .destructive, action: onDelete)
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .menuIndicator(.hidden)
        .help("More")
    }
}

/// What the menu offers, from the skill and its provenance — pure, tested apart from SwiftUI.
struct SkillMoreMenuState: Equatable {
    let isLinked: Bool
    let canViewOnGitHub: Bool
    let isChecking: Bool

    init(skill: Skill, provenance: SkillProvenance?, isChecking: Bool) {
        isLinked = skill.hasLinkedOrigin
        canViewOnGitHub = (provenance?.skillURL ?? provenance?.repositoryURL) != nil
        self.isChecking = isChecking
    }
}
