import Foundation

/// Pure lexical home containment and abbreviation. Membership is decided after collapsing `.` and
/// `..`; callers choose whether the published spelling is normalized or the UI keeps today's spelling.
enum HomePath {
    static func normalizedAbbreviation(_ path: String, homeDirectory: String) -> String? {
        guard let (normalizedPath, normalizedHome) = admittedPair(path, homeDirectory: homeDirectory) else {
            return nil
        }
        if normalizedPath == normalizedHome { return "~" }
        return "~" + normalizedPath.dropFirst(normalizedHome.count)
    }

    static func displayAbbreviation(_ path: String, homeDirectory: String) -> String? {
        guard admittedPair(path, homeDirectory: homeDirectory) != nil else { return nil }
        if path == homeDirectory { return "~" }
        guard path.hasPrefix(homeDirectory + "/") else { return nil }
        return "~" + path.dropFirst(homeDirectory.count)
    }

    private static func admittedPair(_ path: String, homeDirectory: String) -> (String, String)? {
        guard !homeDirectory.isEmpty else { return nil }
        let normalizedPath = lexicallyNormalized(path)
        let normalizedHome = lexicallyNormalized(homeDirectory)
        let isDescendant = normalizedHome == "/"
            ? normalizedPath.hasPrefix("/")
            : normalizedPath.hasPrefix(normalizedHome + "/")
        guard normalizedPath == normalizedHome || isDescendant else {
            return nil
        }
        return (normalizedPath, normalizedHome)
    }

    private static func lexicallyNormalized(_ path: String) -> String {
        let isAbsolute = path.hasPrefix("/")
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
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
/// Adding or renaming a live location also updates LOCATION_MEMBERS in
/// script/check-live-defaults.py. Relative paths and non-location config stay outside that inventory.
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
        return home + "/.claude/skills"
    }()
    static let grokUserSkillsDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/.grok/skills"
    }()
    static let codexUserSkillsDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/.codex/skills"
    }()
    static let openClawUserSkillsDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/.openclaw/skills"
    }()
    static let hermesUserSkillsDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/.hermes/skills"
    }()
    /// Default Hermes category for realized skills. Hermes nests skills under skills/{category}/{name}.
    static let hermesDefaultCategory = "pensieve"
    static let cursorUserRulesDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/.cursor/rules"
    }()

    // MARK: - Claude Code project-level paths (relative to project root)

    static let claudeCodeProjectSkillsRel = ".claude/skills"
    static let grokProjectSkillsRel = ".grok/skills"
    static let codexAgentsRel = "agents"

    // MARK: - Token Budgets (defaults, user-configurable)

    static let defaultClaudeCodeTokenBudget = 2500
    static let defaultGrokTokenBudget = 2500
    static let defaultCursorTokenBudget = 5000
    static let defaultCodexTokenBudget = Int.max // unlimited

    // MARK: - Token Estimation

    static let charsPerToken = 4
}
