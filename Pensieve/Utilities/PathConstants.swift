import Foundation

/// Pure lexical home containment and abbreviation. Membership is decided after collapsing `.` and
/// `..`; callers choose whether the published spelling is normalized or the UI keeps today's spelling.
enum HomePath {
    static func normalizedAbbreviation(_ path: String, homeDirectory: String) -> String? {
        guard let (normalizedPath, normalizedHome) = admittedPair(path, homeDirectory: homeDirectory) else {
            return nil
        }
        if normalizedPath == normalizedHome { return "~" }
        guard let relative = PathSyntax.relativePath(normalizedPath, under: normalizedHome) else { return nil }
        return "~/" + relative
    }

    static func displayAbbreviation(_ path: String, homeDirectory: String) -> String? {
        guard admittedPair(path, homeDirectory: homeDirectory) != nil else { return nil }
        if path == homeDirectory { return "~" }
        guard let relative = PathSyntax.relativePath(path, under: homeDirectory) else { return nil }
        return "~/" + relative
    }

    private static func admittedPair(_ path: String, homeDirectory: String) -> (String, String)? {
        guard !homeDirectory.isEmpty else { return nil }
        let normalizedPath = lexicallyNormalized(path)
        let normalizedHome = lexicallyNormalized(homeDirectory)
        let isDescendant = normalizedHome == "/"
            ? PathSyntax.isAbsolute(normalizedPath)
            : PathSyntax.hasPrefix(normalizedPath, normalizedHome + "/")
        guard normalizedPath == normalizedHome || isDescendant else {
            return nil
        }
        return (normalizedPath, normalizedHome)
    }

    private static func lexicallyNormalized(_ path: String) -> String {
        let isAbsolute = PathSyntax.isAbsolute(path)
        var components: [String] = []
        for component in PathSyntax.components(path, omittingEmptySubsequences: false) {
            switch component {
            case "", ".":
                continue
            case "..":
                if let last = components.last, last != ".." {
                    components.removeLast()
                } else if !isAbsolute {
                    components.append(component)
                }
            default:
                components.append(component)
            }
        }
        let joined = components.joined(separator: "/")
        return isAbsolute ? "/" + joined : joined
    }
}

/// SwiftUI-free path + config constants, extracted from `Constants` (PLAN-12 / 12.1) so the
/// background sync daemon can compile the shared services without dragging SwiftUI in. `Constants`
/// re-exports every member below so existing app call sites keep the `Constants.` spelling; the
/// daemon-compiled shared files reference `PathConstants` directly (they are excluded from the app
/// target's SwiftUI-importing `Constants`).
/// Classify each static member in script/runtime-path-members.json as location or nonLocation.
/// The guard checks these definitions and Constants' re-exports against that shared inventory.
enum PathConstants {
    // MARK: - Pensieve Storage

    /// The current user's home, for tilde-abbreviating paths in the UI (PLAN-29). The one place a
    /// home-relative display string is derived; every stored path stays absolute.
    static let homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path

    static let pensieveBaseDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/.pensieve"
    }()
    static var pensieveSkillsDir: String { pensieveBaseDir + "/skills" }

    // MARK: - Application Support (out-of-tree app files — NOT synced)

    static let pensieveAppSupportDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/Library/Application Support/Pensieve"
    }()
    static var gitAskpassHelperPath: String { pensieveAppSupportDir + "/git-askpass.sh" }

    // MARK: - Platform Paths

    static let claudeCodeUserSkillsDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return agentSkillsDirectory(.claudeCode, home: home)
    }()
    static let grokUserSkillsDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return agentSkillsDirectory(.grok, home: home)
    }()
    static let codexUserSkillsDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return agentSkillsDirectory(.codex, home: home)
    }()
    static let openClawUserSkillsDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return agentSkillsDirectory(.openClaw, home: home)
    }()
    static let hermesUserSkillsDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return agentSkillsDirectory(.hermes, home: home)
    }()
    /// Default Hermes category for realized skills. Hermes nests skills under skills/{category}/{name}.
    static let hermesDefaultCategory = "pensieve"
    static let cursorUserRulesDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return agentSkillsDirectory(.cursor, home: home)
    }()

    static func agentSkillsDirectory(_ platform: PlatformTarget, home: String) -> String {
        switch platform {
        case .claudeCode: return home + "/.claude/skills"
        case .grok: return home + "/.grok/skills"
        case .codex: return home + "/.codex/skills"
        case .openClaw: return home + "/.openclaw/skills"
        case .hermes: return home + "/.hermes/skills"
        case .cursor: return home + "/.cursor/rules"
        }
    }

    // MARK: - Claude Code project-level paths (relative to project root)

    static let claudeCodeProjectSkillsRel = ".claude/skills"
    static let grokProjectSkillsRel = ".grok/skills"
    static let codexAgentsRel = "agents"

    // MARK: - Skill Size Budget (default, user-configurable)

    static let defaultSkillSizeTokenBudget = 5000

    // MARK: - Token Estimation

    static let charsPerToken = 4
}
