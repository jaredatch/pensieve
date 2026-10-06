import Foundation

/// Pure, SwiftData-free symlink path resolution (PLAN-12 / 12.1). Extracted from
/// `LinkService.linkPath`/`targetPath` so the GUI deploy path and the daemon's reconcile share one
/// implementation. Takes a plain `directoryName` instead of a `@Model` `Skill`.
enum DeployPaths {
    /// Invert only the exact builder layout, without resolving or normalizing recorded paths.
    static func slug(artifactPath: String, platform: PlatformTarget, projectPath: String?,
                     cursorUserRulesDirectory: String = PathConstants.cursorUserRulesDir) -> String? {
        guard projectPath == nil || platform.supportsProjectScope else { return nil }
        let sentinel = "pensieve-artifact-slug"
        let template = platform == .cursor
            ? cursorPath(directoryName: sentinel, projectPath: projectPath, userRulesDirectory: cursorUserRulesDirectory)
            : linkPath(directoryName: sentinel, platform: platform, projectPath: projectPath)
        let bytes = Array(template.utf8)
        guard let slot = bytes.indices.reversed().first(where: { bytes[$0...].starts(with: sentinel.utf8) }) else {
            return nil
        }
        let prefix = bytes[..<slot]
        let suffix = bytes[(slot + sentinel.utf8.count)...]
        let path = Array(artifactPath.utf8)
        guard path.starts(with: prefix), path.suffix(suffix.count).elementsEqual(suffix),
              path.count > prefix.count + suffix.count else { return nil }
        let leaf = path.dropFirst(prefix.count).dropLast(suffix.count)
        guard !leaf.contains(UInt8(ascii: "/")) else { return nil }
        return String(bytes: leaf, encoding: .utf8)
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
