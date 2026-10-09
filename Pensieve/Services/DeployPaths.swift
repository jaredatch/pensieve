import Foundation

/// Pure, SwiftData-free symlink path resolution (PLAN-12 / 12.1). Extracted from
/// `LinkService.linkPath`/`targetPath` so the GUI deploy path and the daemon's reconcile share one
/// implementation. Takes a plain `directoryName` instead of a `@Model` `Skill`.
struct DeployPaths {
    let skillsDirectory: String
    let userSkillsDirectories: [PlatformTarget: String]
    let cursorUserRulesDirectory: String

    /// Invert only the exact builder layout, without resolving or normalizing recorded paths.
    func slug(artifactPath: String, platform: PlatformTarget, projectPath: String?) -> String? {
        if let projectPath {
            return Self.projectSlug(artifactPath: artifactPath, platform: platform, projectPath: projectPath)
        }
        let sentinel = "pensieve-artifact-slug"
        let template = platform == .cursor
            ? cursorPath(directoryName: sentinel, projectPath: nil)
            : linkPath(directoryName: sentinel, platform: platform, projectPath: nil)
        return Self.slug(artifactPath: artifactPath, template: template, sentinel: sentinel)
    }

    static func projectSlug(artifactPath: String, platform: PlatformTarget, projectPath: String) -> String? {
        let sentinel = "pensieve-artifact-slug"
        guard let template = projectArtifactPath(directoryName: sentinel, platform: platform,
                                                 projectPath: projectPath) else { return nil }
        return slug(artifactPath: artifactPath, template: template, sentinel: sentinel)
    }

    private static func slug(artifactPath: String, template: String, sentinel: String) -> String? {
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

    /// Project paths have no dependency on the canonical store or any user-wide root.
    static func projectArtifactPath(directoryName: String, platform: PlatformTarget, projectPath: String) -> String? {
        switch platform {
        case .claudeCode: return projectPath + "/" + PathConstants.claudeCodeProjectSkillsRel + "/" + directoryName
        case .grok: return projectPath + "/" + PathConstants.grokProjectSkillsRel + "/" + directoryName
        case .codex: return projectPath + "/" + PathConstants.codexAgentsRel + "/" + directoryName + ".md"
        case .cursor: return cursorPath(directoryName: directoryName, rulesDirectory: projectPath + "/.cursor/rules")
        case .openClaw, .hermes: return nil
        }
    }

    static func cursorPath(directoryName: String, rulesDirectory: String) -> String {
        rulesDirectory + "/" + directoryName + ".mdc"
    }

    func cursorPath(directoryName: String, projectPath: String?) -> String {
        Self.cursorPath(directoryName: directoryName,
                        rulesDirectory: projectPath.map { $0 + "/.cursor/rules" } ?? cursorUserRulesDirectory)
    }

    func userSkillsRoot(for platform: PlatformTarget) -> String? {
        userSkillsDirectories[platform]
    }

    /// An unavailable root has no artifact path. Never turn a missing root into `/<slug>`.
    func linkPath(directoryName: String, platform: PlatformTarget, projectPath: String?) -> String {
        guard platform.usesSymlinks else { return "" }
        if let projectPath, platform.supportsProjectScope {
            return Self.projectArtifactPath(directoryName: directoryName, platform: platform,
                                            projectPath: projectPath) ?? ""
        }
        guard let root = userSkillsRoot(for: platform), !root.isEmpty else { return "" }
        return root + "/" + directoryName
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
