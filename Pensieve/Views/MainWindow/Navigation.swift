import Foundation

/// The sidebar's five rows. Selection is a section — never an instance (Photos' People/Places,
/// Music's Artists/Genres). Raw values are stable identifiers, not display strings.
enum SidebarSection: String, Hashable, CaseIterable, Identifiable {
    case skills
    case projects
    case categories
    case tags
    case machines

    var id: String { rawValue }
}

/// The content column's selected entity. Remote projects use their cross-machine identity;
/// skills keep their own `Set<Skill>` multi-selection in ContentView.
enum EntitySelection: Hashable {
    case project(UUID)
    case remoteProject(String)
    case category(UUID)
    case machine(String)
    case tag(String)

    /// The section this selection can legally appear in. The routing functions use this to
    /// refuse a mismatched pair, so a selection left over from another section is inert.
    var section: SidebarSection {
        switch self {
        case .project, .remoteProject: return .projects
        case .category: return .categories
        case .machine:  return .machines
        case .tag:      return .tags
        }
    }
}

enum ContentColumn: Equatable {
    case skillList
    case projectList
    case categoryList
    case tagList
    case machineList
}

enum DetailColumn: Equatable {
    case project(UUID)
    case remoteProject(String)
    case category(UUID)
    case machine(String)
    case tag(String)
    case skill
    case bulk
    case emptyNoSkills
    case selectSkillPrompt
    case selectEntityPrompt(SidebarSection)
}

/// The content column is a pure function of the sidebar section — one list per section, and a
/// section can NEVER route to another section's list.
func contentColumn(for section: SidebarSection) -> ContentColumn {
    switch section {
    case .skills:     return .skillList
    case .projects:   return .projectList
    case .categories: return .categoryList
    case .tags:       return .tagList
    case .machines:   return .machineList
    }
}

/// The detail column is a pure function of (section, entity, skill multi-select, emptiness).
/// An entity selection whose `section` differs from the live section is IGNORED — so a stale
/// selection surviving a section switch can never render another section's detail, exactly as
/// the pre-PLAN-27 model made stale `selectedSkills` unable to surface bulk UI. The view layer
/// also clears on section change; that clearing is a courtesy, this refusal is the guarantee.
func detailColumn(for section: SidebarSection, entity: EntitySelection?,
                  selectedSkillCount: Int, skillsEmpty: Bool) -> DetailColumn {
    if section != .skills {
        guard let entity, entity.section == section else { return .selectEntityPrompt(section) }
        switch entity {
        case .project(let id):  return .project(id)
        case .remoteProject(let key): return .remoteProject(key)
        case .category(let id): return .category(id)
        case .machine(let id):  return .machine(id)
        case .tag(let name):    return .tag(name)
        }
    }
    if selectedSkillCount > 1 { return .bulk }
    if selectedSkillCount == 1 { return .skill }
    if skillsEmpty { return .emptyNoSkills }
    return .selectSkillPrompt
}

/// Drops an entity selection whose entity no longer exists. Without this a deleted project leaves
/// the detail column showing "Project Not Found" until the user clicks elsewhere; Finder clears the
/// selection instead. Tags are included: a tag stops existing when its last carrier loses it.
func prunedEntitySelection(_ entity: EntitySelection?, projectIDs: Set<UUID>,
                           categoryIDs: Set<UUID>,
                           machineIDs: Set<String>, tags: Set<String>,
                           remoteProjectKeys: Set<String> = []) -> EntitySelection? {
    switch entity {
    case .project(let id):  return projectIDs.contains(id) ? entity : nil
    case .remoteProject(let key): return remoteProjectKeys.contains(key) ? entity : nil
    case .category(let id): return categoryIDs.contains(id) ? entity : nil
    case .machine(let id):  return machineIDs.contains(id) ? entity : nil
    case .tag(let name):    return tags.contains(name) ? entity : nil
    case nil:               return nil
    }
}

/// Selects a newly-created entity only when its section is still visible, clearing any search that
/// would hide its row. Add Project can also be presented from a skill's Deployments tab, where
/// dismissing the sheet must leave that skill and its search alone.
func selectionAfterCreating(_ created: EntitySelection?, in section: SidebarSection,
                            entity: inout EntitySelection?, searchText: inout String) {
    guard let created, created.section == section else { return }
    entity = created
    searchText = ""
}

/// Machines is the one conditional row (`showsMachines`). If sync is disconnected and the last
/// machine state disappears while Machines is the live section, the sidebar would show no selected
/// row over an empty column. Fall back to .skills, which is unconditional.
func availableSection(_ section: SidebarSection, showsMachines: Bool) -> SidebarSection {
    (section == .machines && !showsMachines) ? .skills : section
}

/// Whether a section change clears the skill multi-selection. LEAVING Skills drops it; ARRIVING at
/// Skills must NOT — `revealSkill` writes `section = .skills` and `selectedSkills = [skill]` in the
/// same update, so an unconditional clear in the section-change handler would erase the very
/// selection the reveal just made and land the user on the "No Skill Selected" state instead.
func clearsSkillSelection(movingFrom old: SidebarSection, to new: SidebarSection) -> Bool {
    old == .skills && new != .skills
}

/// Reveal a skill: switch to the Skills section and make it the sole selection. Mirrors Finder's
/// "reveal in enclosing folder" — the destination is the library, not a nested drill-down, so the
/// detail column never grows a navigation stack.
///
/// The list filter and the search text are cleared in the same update because a revealed skill hidden
/// by either would land on an empty list. The section-change handler that also clears search runs on
/// the next update, too late for a list whose mount-time pruning handler has already looked. Finder's
/// Reveal has the same contract — it changes whatever view state it must to show you the thing.
func revealSkill(_ skill: Skill, section: inout SidebarSection,
                 entity: inout EntitySelection?, selectedSkills: inout Set<Skill>,
                 filter: inout SkillListFilter, searchText: inout String) {
    section = .skills
    entity = nil
    selectedSkills = [skill]
    filter = SkillListFilter()
    searchText = ""
}
