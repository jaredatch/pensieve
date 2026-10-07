import Foundation
import SwiftUI

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
        return [contentSummary(file), permissionSummary(file)].compactMap { $0 }
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private static func contentSummary(_ file: PinnedSkillFileDiff) -> String {
        guard let added = file.linesAdded, let removed = file.linesRemoved else {
            switch file.content {
            case .binary: return "Binary file"
            case .tooLarge: return "Too large to show"
            case .diffBudgetExhausted: return "Preview diff budget exhausted"
            case .diffOutputBoundReached: return "Preview output bound reached"
            case .diffOutputTooLarge: return "Diff too large to show"
            case .text, .modeOnly: return ""
            }
        }
        let counts = "\(added) \(added == 1 ? "addition" : "additions"), \(removed) \(removed == 1 ? "deletion" : "deletions")"
        return counts
    }

    static func unavailableReason(_ file: PinnedSkillFileDiff) -> String? {
        switch file.content {
        case .text: return emptyFileReason(file)
        case .binary: return "This binary file changed. View the change on GitHub."
        case .tooLarge: return "This file is too large to show within the preview limits. View the change on GitHub."
        case .diffBudgetExhausted:
            return "The preview's shared diff budget ran out before this file could be shown. View the change on GitHub."
        case .diffOutputTooLarge: return "This file's diff is too large to show"
        case .diffOutputBoundReached:
            return "The preview's output bound was reached before this file could be shown. View the change on GitHub."
        case .modeOnly:
            guard let permissions = file.permissions else { return "File contents are unchanged." }
            return unchangedPermissionReason(before: permissions.old, after: permissions.new)
        }
    }

    private static func emptyFileReason(_ file: PinnedSkillFileDiff) -> String? {
        guard let diff = file.diff, diff.hunks.isEmpty else { return nil }
        if file.kind == .added { return "Empty file added" }
        if file.kind == .removed { return "Empty file removed" }
        return nil
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
        guard sidebarCounts(file) == nil else { return file.permissions == nil ? nil : "Mode" }
        let content = contentSummary(file)
        guard !content.isEmpty else { return file.permissions == nil ? nil : "Mode" }
        return content + (file.permissions == nil ? "" : " · Mode")
    }

    static func permissionSummary(_ file: PinnedSkillFileDiff) -> String? {
        guard let permissions = file.permissions else { return nil }
        return "Permissions changed from " + String(format: "%04o", permissions.old)
            + " to " + String(format: "%04o", permissions.new)
    }

    /// LF delimits records; CR immediately before LF belongs to the ending, not the content.
    static func lineText(_ line: UnifiedDiffLine) -> AttributedString {
        styledText(lineBody(line.text))
    }

    static func visibleText(_ text: String, filename: Bool = false) -> String {
        String(styledText(text, filename: filename).characters)
    }

    /// Marks carry their own foreground; literal lookalikes inherit the ordinary text style.
    static func styledText(_ text: String, filename: Bool = false) -> AttributedString {
        var result = AttributedString()
        var literal = ""
        for scalar in text.unicodeScalars {
            let hidden = isHidden(scalar, filename: filename)
            guard hidden else { literal.unicodeScalars.append(scalar); continue }
            result.append(AttributedString(literal))
            literal = ""
            var mark = AttributedString(scalar.value == 13 ? "␍" : String(format: "⟨U+%04X⟩", scalar.value))
            mark.foregroundColor = DesignTokens.diffHiddenCharacter
            result.append(mark)
        }
        result.append(AttributedString(literal))
        return result
    }

    private static func isHidden(_ scalar: Unicode.Scalar, filename: Bool) -> Bool {
        if !filename && [9, 10].contains(scalar.value) { return false }
        let category = scalar.properties.generalCategory
        return category == .control || category == .format || category == .lineSeparator
            || category == .paragraphSeparator || scalar.properties.isDefaultIgnorableCodePoint
    }

    /// Notes have no diff marker or line number. Ending-only pairs get one note after the added line.
    static func lineNotes(_ lines: [UnifiedDiffLine]) -> [Int: [String]] {
        var notes: [Int: [String]] = [:]
        var removed: [Data: [Int]] = [:]
        var consumed: [Data: Int] = [:]
        for (index, line) in lines.enumerated() {
            if line.text.unicodeScalars.last?.value != 10 { notes[index, default: []].append("\\ No newline at end of file") }
            switch line.kind {
            case .context:
                removed.removeAll()
                consumed.removeAll()
            case .removed: removed[Data(lineBody(line.text).utf8), default: []].append(index)
            case .added:
                let body = Data(lineBody(line.text).utf8)
                let offset = consumed[body, default: 0]
                guard let matches = removed[body], offset < matches.count else { continue }
                let old = matches[offset]
                consumed[body] = offset + 1
                let before = lineEnding(lines[old].text), after = lineEnding(line.text)
                if before != after {
                    notes.removeValue(forKey: old)
                    notes[index] = ["Line ending changed: \(before) → \(after)"]
                }
            }
        }
        return notes
    }

    private static func lineBody(_ text: String) -> String {
        var scalars = text.unicodeScalars
        if scalars.last?.value == 10 {
            scalars.removeLast()
            if scalars.last?.value == 13 { scalars.removeLast() }
        }
        return String(scalars)
    }

    private static func lineEnding(_ text: String) -> String {
        if text.hasSuffix("\r\n") { return "CRLF" }
        return text.unicodeScalars.last?.value == 10 ? "LF" : "no newline"
    }
}
