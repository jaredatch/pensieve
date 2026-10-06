import Foundation

/// Presentation of precomputed hunks only. This mapping never runs a diff or reads file contents.
enum ViewChangesPresentation {
    static func accessibilityLabel(_ file: PinnedSkillFileDiff) -> String {
        let path = visibleText(file.path, filename: true) as NSString
        let parent = path.deletingLastPathComponent
        return [path.lastPathComponent, parent.isEmpty ? nil : parent, summary(file)]
            .compactMap { $0 }.joined(separator: ", ")
    }

    static func sidebarHeader(_ state: ViewChangesViewModel.State) -> String? {
        guard case let .loaded(preview) = state else { return nil }
        let count = preview.files.count
        return "\(count) Changed \(count == 1 ? "File" : "Files")"
    }

    static func sidebarCounts(_ file: PinnedSkillFileDiff) -> (added: Int, removed: Int)? {
        if case .modeOnly = file.content { return nil }
        guard let added = file.linesAdded, let removed = file.linesRemoved else { return nil }
        return (added, removed)
    }

    static func unavailableTitle(_ file: PinnedSkillFileDiff) -> String {
        if case .modeOnly = file.content { return "Permissions Changed" }
        return "Diff Unavailable"
    }

    static func subtitle(_ row: UpdatesRow) -> String {
        "\(row.repositoryDisplay) · \(row.shortInstalledCommit) → \(row.shortUpstreamCommit)"
    }

    static func summary(_ file: PinnedSkillFileDiff) -> String {
        if case .modeOnly = file.content { return "Permissions changed" }
        guard let added = file.linesAdded, let removed = file.linesRemoved else {
            switch file.content {
            case .binary: return "Binary file"
            case .tooLarge: return "Too large to show"
            case .diffBudgetExhausted: return "Preview diff budget exhausted"
            case .diffOutputBoundReached: return "Preview output bound reached"
            case .text, .modeOnly: return ""
            }
        }
        let counts = "\(added) \(added == 1 ? "addition" : "additions"), \(removed) \(removed == 1 ? "deletion" : "deletions")"
        return permissionSummary(file).map { counts + " · " + $0 } ?? counts
    }

    static func unavailableReason(_ file: PinnedSkillFileDiff) -> String? {
        switch file.content {
        case .text:
            if let diff = file.diff, diff.hunks.isEmpty {
                if file.kind == .added { return "Empty file added" }
                if file.kind == .removed { return "Empty file removed" }
            }
            return nil
        case .binary: return "This binary file changed. View the change on GitHub."
        case .tooLarge: return "This file is too large to show within the preview limits. View the change on GitHub."
        case .diffBudgetExhausted:
            return "The preview's shared diff budget ran out before this file could be shown. View the change on GitHub."
        case .diffOutputBoundReached:
            return "The preview's output bound was reached before this file could be shown. View the change on GitHub."
        case let .modeOnly(before, after):
            return unchangedPermissionReason(before: before, after: after)
        }
    }

    private static func unchangedPermissionReason(before: UInt32, after: UInt32) -> String {
        let difference = before ^ after
        let executable: (UInt32, String)?
        switch difference {
        case 0o100: executable = (0o100, "Executable")
        case 0o010: executable = (0o010, "Group executable")
        case 0o001: executable = (0o001, "Other executable")
        default: executable = nil
        }
        if let (bit, name) = executable {
            return "File contents are unchanged. \(name) permission changed from "
                + "\(before & bit != 0 ? "on" : "off") to \(after & bit != 0 ? "on" : "off")."
        }
        return "File contents are unchanged. Permissions changed from "
            + String(format: "%04o", before) + " to " + String(format: "%04o", after) + "."
    }

    static func incompleteNote(_ unread: Int) -> String {
        let noun = unread == 1 ? "file wasn't" : "files weren't"
        return "Preview incomplete: \(unread) \(noun) read. View the remaining changes on GitHub."
    }

    static func sidebarMarker(_ file: PinnedSkillFileDiff) -> String? {
        if case .modeOnly = file.content { return "Mode" }
        return file.permissions == nil ? nil : "Mode"
    }

    static func permissionSummary(_ file: PinnedSkillFileDiff) -> String? {
        guard let permissions = file.permissions else { return nil }
        return "Permissions changed from " + String(format: "%04o", permissions.old)
            + " to " + String(format: "%04o", permissions.new)
    }

    /// Diff LF is a record delimiter. Every remaining break/control is displayed, never interpreted.
    static func lineText(_ line: UnifiedDiffLine) -> String {
        let text = line.text.unicodeScalars
        let content = text.last?.value == 10 ? String(text.dropLast()) : line.text
        return visibleText(content)
    }

    static func filePath(_ file: PinnedSkillFileDiff) -> String { visibleText(file.path, filename: true) }

    static func visibleText(_ text: String, filename: Bool = false) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            let value = scalar.value
            let hidden = value == 13 || value == 0x85 || value == 0x2028 || value == 0x2029
                || (0x202A...0x202E).contains(value) || (0x2066...0x2069).contains(value)
                || (0xE0000...0xE007F).contains(value)
            if hidden || (filename && scalar.properties.generalCategory == .control) {
                result += value == 13 ? "␍" : String(format: "⟨U+%04X⟩", value)
            } else { result.unicodeScalars.append(scalar) }
        }
        return result
    }
}
