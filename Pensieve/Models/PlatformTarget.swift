import Foundation

enum PlatformTarget: String, Codable, CaseIterable, Identifiable {
    case claudeCode
    case grok
    case cursor
    case codex
    case openClaw
    case hermes

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .grok: "Grok"
        case .cursor: "Cursor"
        case .codex: "Codex"
        case .openClaw: "OpenClaw"
        case .hermes: "Hermes"
        }
    }

    var iconName: String {
        switch self {
        case .claudeCode: "terminal"
        case .grok: "terminal.fill"
        case .cursor: "cursorarrow.rays"
        case .codex: "doc.text"
        case .openClaw: "pawprint"
        case .hermes: "scroll"
        }
    }

    /// Whether this platform uses symlinks (true) or compiled output (false)
    var usesSymlinks: Bool {
        switch self {
        case .claudeCode, .grok, .codex, .openClaw, .hermes: true
        case .cursor: false
        }
    }

    var supportsProjectScope: Bool {
        switch self {
        case .claudeCode, .grok, .codex, .cursor: true
        case .openClaw, .hermes: false
        }
    }
}

/// Advisory limits checked against a skill's local deployments. Sources and dates make changes auditable.
struct AgentSkillLimit {
    enum Kind {
        case nameCharacters
        case descriptionCharacters
        case compactionTokens
        case alwaysOnTokens
    }

    let platform: PlatformTarget
    let kind: Kind
    let maximum: Int
    let source: String
    let checkedOn: String

    static let known: [AgentSkillLimit] = [
        AgentSkillLimit(platform: .codex, kind: .nameCharacters, maximum: 64,
                       source: "https://github.com/openai/codex/blob/rust-v0.160.0/codex-rs/skills/src/parser.rs",
                       checkedOn: "2026-10-07"),
        AgentSkillLimit(platform: .claudeCode, kind: .descriptionCharacters, maximum: 1_536,
                       source: "https://code.claude.com/docs/en/skills#frontmatter-reference",
                       checkedOn: "2026-10-07"),
        AgentSkillLimit(platform: .claudeCode, kind: .compactionTokens, maximum: 5_000,
                       source: "https://code.claude.com/docs/en/skills#skill-content-lifecycle",
                       checkedOn: "2026-10-07"),
        // Always-on rules enter every chat; 500 tokens is the advisory size threshold.
        AgentSkillLimit(platform: .cursor, kind: .alwaysOnTokens, maximum: 500,
                       source: "https://cursor.com/docs/rules#rule-anatomy",
                       checkedOn: "2026-10-07")
    ]
}
