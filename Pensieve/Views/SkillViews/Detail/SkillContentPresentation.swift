import Foundation

/// Which file the Content tab shows and what it can show of it — pure, so the pulldown's order and the
/// rendered/source rule are tested apart from SwiftUI.
enum SkillContentPresentation {
    enum Mode: String, CaseIterable {
        case rendered
        case source
    }

    struct FileChoice: Equatable, Identifiable {
        let relativePath: String
        var id: String { relativePath }
        var isSkillFile: Bool { relativePath == "SKILL.md" }
        /// Markdown renders; every other text file has its source only.
        var canRender: Bool {
            let lower = relativePath.lowercased()
            return lower.hasSuffix(".md") || lower.hasSuffix(".markdown")
        }
    }

    /// One resolution of the retained file and mode against the current bundle. The Content tab and its
    /// containing layout share this value, so they agree about the presentation's vertical scroller.
    struct Resolved: Equatable {
        let choices: [FileChoice]
        let choice: FileChoice
        let shownMode: Mode

        var ownsScroller: Bool { shownMode == .source }
    }

    /// SKILL.md first, then the bundle's other text files by path.
    static func choices(inventory: SkillBundleInventory) -> [FileChoice] {
        let others = inventory.textFiles.map(\.relativePath).filter { $0 != "SKILL.md" }.sorted()
        return [FileChoice(relativePath: "SKILL.md")] + others.map { FileChoice(relativePath: $0) }
    }

    /// The mode actually shown: a file that cannot render shows its source whatever was asked.
    static func shownMode(_ mode: Mode, for choice: FileChoice) -> Mode {
        choice.canRender ? mode : .source
    }

    /// The file actually shown: the retained selection when this bundle has it, else `SKILL.md` — one
    /// answer for the picker, the editor, and the leave guard (a selection retained from another skill may
    /// name a file this bundle lacks; the guard must test the file the editor shows).
    static func resolvedFile(_ selected: String, in choices: [FileChoice]) -> String {
        choices.contains { $0.relativePath == selected } ? selected : "SKILL.md"
    }

    /// Computes the bundle choices once, then resolves the file and the mode from that same list.
    static func resolve(selectedFile: String, requestedMode: Mode, inventory: SkillBundleInventory) -> Resolved {
        let choices = choices(inventory: inventory)
        let file = resolvedFile(selectedFile, in: choices)
        let choice = choices.first { $0.relativePath == file } ?? FileChoice(relativePath: "SKILL.md")
        return Resolved(choices: choices, choice: choice, shownMode: shownMode(requestedMode, for: choice))
    }
}
