import Foundation

/// Pure, SwiftData-free symlink path resolution (PLAN-12 / 12.1). Extracted from
/// `LinkService.linkPath`/`targetPath` so the GUI deploy path and the daemon's reconcile share one
/// implementation. Takes a plain `directoryName` instead of a `@Model` `Skill`.
enum DeployPaths {
    static func userSkillsRoot(for platform: PlatformTarget) -> String? {
        switch platform {
        case .claudeCode:
            return PathConstants.claudeCodeUserSkillsDir
        case .grok:
            return PathConstants.grokUserSkillsDir
        case .cursor:
            return nil
        case .codex:
            return PathConstants.codexUserSkillsDir
        case .openClaw:
            return PathConstants.openClawUserSkillsDir
        case .hermes:
            return PathConstants.hermesUserSkillsDir + "/" + PathConstants.hermesDefaultCategory
        }
    }

    static func linkPath(directoryName: String, platform: PlatformTarget, projectPath: String?) -> String {
        if let projectPath, !projectPath.hasPrefix("/") { return "" }
        switch platform {
        case .claudeCode:
            if let projectPath {
                return projectPath + "/" + PathConstants.claudeCodeProjectSkillsRel + "/" + directoryName
            } else {
                return PathConstants.claudeCodeUserSkillsDir + "/" + directoryName
            }
        case .grok:
            if let projectPath {
                return projectPath + "/" + PathConstants.grokProjectSkillsRel + "/" + directoryName
            } else {
                return PathConstants.grokUserSkillsDir + "/" + directoryName
            }
        case .codex:
            guard let projectPath else {
                return PathConstants.codexUserSkillsDir + "/" + directoryName
            }
            return projectPath + "/" + PathConstants.codexAgentsRel + "/" + directoryName + ".md"
        case .openClaw:
            return PathConstants.openClawUserSkillsDir + "/" + directoryName
        case .hermes:
            return PathConstants.hermesUserSkillsDir + "/" + PathConstants.hermesDefaultCategory + "/" + directoryName
        case .cursor:
            return ""
        }
    }

    static func targetPath(directoryName: String, platform: PlatformTarget, projectPath: String?) -> String {
        switch platform {
        case .claudeCode:
            return PathConstants.pensieveSkillsDir + "/" + directoryName
        case .grok:
            return PathConstants.pensieveSkillsDir + "/" + directoryName
        case .codex:
            if projectPath == nil {
                return PathConstants.pensieveSkillsDir + "/" + directoryName
            } else {
                return PathConstants.pensieveSkillsDir + "/" + directoryName + "/SKILL.md"
            }
        case .openClaw:
            return PathConstants.pensieveSkillsDir + "/" + directoryName
        case .hermes:
            return PathConstants.pensieveSkillsDir + "/" + directoryName
        case .cursor:
            return ""
        }
    }
}
