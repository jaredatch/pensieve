import Foundation

/// Every disk read the skill detail needs, loaded ONCE off the render path (PLAN-26 / 26.1): the body the
/// Content tab renders, its token estimate, the bundle inventory (PLAN-34), and the deploy status
/// of every installed platform for This Mac and for each registered project — the Deployments tab's
/// switches and the Overview's Deployed stat. `body` reads this value and nothing else.
struct DetailContentSnapshot: Equatable {
    var body: String = ""
    /// Body-only estimate (frontmatter excluded), exactly what `library.estimatedTokens` returns.
    var tokenCount: Int = 0
    var frontmatterName: String = ""
    var frontmatterDescription: String = ""
    var frontmatterWhenToUse: String = ""
    var cursorAlwaysApply: Bool = false
    var inventory: SkillBundleInventory = .empty
    /// Per installed platform (`deployablePlatforms(forProject: false)`), from `PlatformViewModel.isDeployed`.
    var macStatus: [PlatformTarget: Bool] = [:]
    /// Per registered project (by id), per project-capable installed platform.
    var projectStatus: [UUID: [PlatformTarget: Bool]] = [:]

    var deployedOnThisMac: Int { macStatus.values.filter { $0 }.count }

    func isDeployed(to platform: PlatformTarget) -> Bool {
        macStatus[platform] == true || projectStatus.values.contains { $0[platform] == true }
    }

    static func load(skill: Skill, projects: [Project],
                     library: SkillLibraryViewModel, platformVM: PlatformViewModel) -> DetailContentSnapshot {
        var mac: [PlatformTarget: Bool] = [:]
        for platform in platformVM.deployablePlatforms(forProject: false) {
            mac[platform] = platformVM.isDeployed(skill: skill, platform: platform, target: .userWide)
        }
        var perProject: [UUID: [PlatformTarget: Bool]] = [:]
        let projectPlatforms = platformVM.deployablePlatforms(forProject: true)
        for project in projects {
            var status: [PlatformTarget: Bool] = [:]
            for platform in projectPlatforms {
                status[platform] = platformVM.isDeployed(skill: skill, platform: platform, target: .project(project))
            }
            perProject[project.id] = status
        }
        let document = library.readSkillDocument(skill) ?? ""
        let parsed = SkillParser.parse(document)
        let body = SkillParser.stripFrontmatter(document)
        return DetailContentSnapshot(body: body,
                                     tokenCount: TokenCounter.estimate(body),
                                     frontmatterName: parsed.name ?? "",
                                     frontmatterDescription: parsed.description ?? "",
                                     frontmatterWhenToUse: parsed.whenToUse ?? "",
                                     cursorAlwaysApply: skill.cursorConfig?.alwaysApply == true,
                                     inventory: library.bundleInventory(skill),
                                     macStatus: mac,
                                     projectStatus: perProject)
    }
}
