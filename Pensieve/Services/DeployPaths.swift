import Foundation

/// Pure, SwiftData-free symlink path resolution (PLAN-12 / 12.1). Extracted from
/// `LinkService.linkPath`/`targetPath` so the GUI deploy path and the daemon's reconcile share one
/// implementation. Takes a plain `directoryName` instead of a `@Model` `Skill`.
enum DeployPaths {
    /// Invert only the exact builder layout, without resolving or normalizing recorded paths.
    static func slug(artifactPath: String, platform: PlatformTarget, projectPath: String?,
                     cursorUserRulesDirectory: String = PathConstants.cursorUserRulesDir) -> String? {
        guard projectPath == nil || platform.supportsProjectScope else { return nil }
        let suffix = platform == .cursor ? ".mdc" : platform == .codex && projectPath != nil ? ".md" : ""
        let template = platform == .cursor
            ? cursorPath(directoryName: "", projectPath: projectPath, userRulesDirectory: cursorUserRulesDirectory)
            : linkPath(directoryName: "", platform: platform, projectPath: projectPath)
        let prefix = String(template.dropLast(suffix.count))
        guard artifactPath.hasPrefix(prefix), artifactPath.hasSuffix(suffix) else { return nil }
        let leaf = artifactPath.dropFirst(prefix.count)
        guard leaf.count > suffix.count else { return nil }
        let slug = String(leaf.dropLast(suffix.count))
        return slug.contains("/") ? nil : slug
    }

    static func cursorPath(directoryName: String, projectPath: String?,
                           userRulesDirectory: String = PathConstants.cursorUserRulesDir) -> String {
        let root = projectPath.map { $0 + "/.cursor/rules" } ?? userRulesDirectory
        return root + "/" + directoryName + ".mdc"
    }

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
