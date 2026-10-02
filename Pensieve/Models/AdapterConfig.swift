import Foundation

/// Cursor-specific adapter configuration.
/// Only Cursor needs per-platform config — Claude Code and Codex just get symlinks.
struct CursorAdapterConfig: Codable, Equatable {
    var description: String?
    var globs: [String]?
    var alwaysApply: Bool

    init(description: String? = nil, globs: [String]? = nil, alwaysApply: Bool = false) {
        self.description = description
        self.globs = globs
        self.alwaysApply = alwaysApply
    }
}
