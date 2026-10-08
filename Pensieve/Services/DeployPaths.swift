import Foundation

/// Pure, SwiftData-free symlink path resolution (PLAN-12 / 12.1). Extracted from
/// `LinkService.linkPath`/`targetPath` so the GUI deploy path and the daemon's reconcile share one
/// implementation. Takes a plain `directoryName` instead of a `@Model` `Skill`.
struct DeployPaths {
    let skillsDirectory: String
    let userSkillsDirectories: [PlatformTarget: String]
    let cursorUserRulesDirectory: String

    /// Invert only the exact builder layout, without resolving or normalizing recorded paths.
    func slug(artifactPath: String, platform: PlatformTarget, projectPath: String?,
              cursorUserRulesDirectory: String? = nil) -> String? {
        guard projectPath == nil || platform.supportsProjectScope else { return nil }
        let sentinel = "pensieve-artifact-slug"
        let template = platform == .cursor
            ? cursorPath(directoryName: sentinel, projectPath: projectPath,
                userRulesDirectory: cursorUserRulesDirectory ?? self.cursorUserRulesDirectory)
            : linkPath(directoryName: sentinel, platform: platform, projectPath: projectPath)
        guard let slot = template.range(of: sentinel, options: .backwards) else { return nil }
        let prefix = Array(template[..<slot.lowerBound].utf8)
        let suffix = Array(template[slot.upperBound...].utf8)
        let path = Array(artifactPath.utf8)
        guard path.starts(with: prefix), path.suffix(suffix.count).elementsEqual(suffix),
              path.count > prefix.count + suffix.count else { return nil }
        let leaf = path.dropFirst(prefix.count).dropLast(suffix.count)
        guard !leaf.contains(UInt8(ascii: "/")) else { return nil }
        return String(bytes: leaf, encoding: .utf8)
    }

    func cursorPath(directoryName: String, projectPath: String?,
                    userRulesDirectory: String? = nil) -> String {
        let root = projectPath.map { $0 + "/.cursor/rules" } ?? userRulesDirectory ?? cursorUserRulesDirectory
        return root + "/" + directoryName + ".mdc"
    }

    func userSkillsRoot(for platform: PlatformTarget) -> String? {
        userSkillsDirectories[platform]
    }

    func linkPath(directoryName: String, platform: PlatformTarget, projectPath: String?) -> String {
        switch platform {
        case .claudeCode:
            if let projectPath {
                return projectPath + "/" + PathConstants.claudeCodeProjectSkillsRel + "/" + directoryName
            } else {
                return (userSkillsDirectories[.claudeCode] ?? "") + "/" + directoryName
            }
        case .grok:
            if let projectPath {
                return projectPath + "/" + PathConstants.grokProjectSkillsRel + "/" + directoryName
            } else {
                return (userSkillsDirectories[.grok] ?? "") + "/" + directoryName
            }
        case .codex:
            guard let projectPath else {
                return (userSkillsDirectories[.codex] ?? "") + "/" + directoryName
            }
            return projectPath + "/" + PathConstants.codexAgentsRel + "/" + directoryName + ".md"
        case .openClaw:
            return (userSkillsDirectories[.openClaw] ?? "") + "/" + directoryName
        case .hermes:
            return (userSkillsDirectories[.hermes] ?? "") + "/" + directoryName
        case .cursor:
            return ""
        }
    }

    func targetPath(directoryName: String, platform: PlatformTarget, projectPath: String?) -> String {
        switch platform {
        case .claudeCode:
            return skillsDirectory + "/" + directoryName
        case .grok:
            return skillsDirectory + "/" + directoryName
        case .codex:
            if projectPath == nil {
                return skillsDirectory + "/" + directoryName
            } else {
                return skillsDirectory + "/" + directoryName + "/SKILL.md"
            }
        case .openClaw:
            return skillsDirectory + "/" + directoryName
        case .hermes:
            return skillsDirectory + "/" + directoryName
        case .cursor:
            return ""
        }
    }
}
