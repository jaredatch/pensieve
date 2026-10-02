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
