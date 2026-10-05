import Foundation

/// Presentation of precomputed hunks only. This mapping never runs a diff or reads file contents.
enum ViewChangesPresentation {
    static func subtitle(_ row: UpdatesRow) -> String {
        let days = max(0, Int(row.updateDate.timeIntervalSince(row.installedDate) / 86_400))
        let age = days == 1 ? "1 day newer" : "\(days) days newer"
        return "\(row.repositoryDisplay) · \(row.shortInstalledCommit) → \(row.shortUpstreamCommit) · \(age)"
    }

    static func summary(_ file: PinnedSkillFileDiff) -> String {
        guard let added = file.linesAdded, let removed = file.linesRemoved else {
            switch file.content {
            case .binary: return "Binary file"
            case .tooLarge: return "Too large to show"
            case .diffBudgetExhausted: return "Preview diff budget exhausted"
            case .text, .modeOnly: return ""
            }
        }
        return "\(added) \(added == 1 ? "addition" : "additions"), \(removed) \(removed == 1 ? "deletion" : "deletions")"
    }

    static func unavailableReason(_ file: PinnedSkillFileDiff) -> String? {
        switch file.content {
        case .text: return nil
        case .binary: return "This binary file changed. View the change on GitHub."
        case .tooLarge: return "This file is too large to show within the preview limits. View the change on GitHub."
        case .diffBudgetExhausted:
            return "The preview's shared diff budget ran out before this file could be shown. View the change on GitHub."
        case let .modeOnly(oldExecutable, newExecutable):
            return "File contents are unchanged. Executable permission changed from "
                + "\(oldExecutable & 0o100 != 0 ? "on" : "off") to \(newExecutable & 0o100 != 0 ? "on" : "off")."
        }
    }

    static func incompleteNote(_ unread: Int) -> String {
        let noun = unread == 1 ? "file wasn't" : "files weren't"
        return "Preview incomplete: \(unread) \(noun) read. View the remaining changes on GitHub."
    }

    static func lineText(_ line: UnifiedDiffLine) -> String {
        var text = line.text
        if text.hasSuffix("\r\n") || text.hasSuffix("\n") { text.removeLast() }
        return text
    }
}
