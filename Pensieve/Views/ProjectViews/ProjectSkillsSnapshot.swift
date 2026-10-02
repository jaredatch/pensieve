import Foundation

/// Every disk read the project detail column needs, loaded ONCE off the render path — the same
/// contract as DetailContentSnapshot (PLAN-26 / 26.1). `body` reads this value and nothing else;
/// a call to platformVM.isDeployed from a body evaluation is 2·N·M syscalls per frame and is the
/// 2026-08-19 render-pass class of bug.
struct ProjectSkillsSnapshot: Equatable {
    struct Row: Equatable, Identifiable {
        let skillID: UUID
        let name: String
        let directoryName: String
        /// True when at least one project-capable platform has this skill linked/compiled here.
        let isDeployed: Bool
        /// True when some category containing this project assigns this skill.
        let isIntended: Bool

        var id: UUID { skillID }
    }

    var rows: [Row] = []
    var deployedCount: Int { rows.filter(\.isDeployed).count }

    static func load(project: Project, skills: [Skill], categories: [Category],
                     platformVM: PlatformViewModel) -> ProjectSkillsSnapshot {
        let intended: Set<String>
        if let key = project.identityKey {
            intended = Set(categories.filter { $0.projectKeys.contains(key) }.flatMap(\.skillSlugs))
        } else {
            intended = []
        }
        let platforms = platformVM.deployablePlatforms(forProject: true)
        let target = DeployTarget.project(project)
        let rows = skills.compactMap { skill -> Row? in
            let deployed = platforms.contains {
                platformVM.isDeployed(skill: skill, platform: $0, target: target)
            }
            let wanted = intended.contains(skill.directoryName)
            guard deployed || wanted else { return nil }
            return Row(skillID: skill.id, name: skill.name,
                       directoryName: skill.directoryName,
                       isDeployed: deployed, isIntended: wanted)
        }
        return ProjectSkillsSnapshot(rows: rows)
    }
}
