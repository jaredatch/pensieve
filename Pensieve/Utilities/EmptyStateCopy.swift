import Foundation

/// The empty states' copy, apart from SwiftUI so the strings are tested.
enum EmptyStateCopy {
    static let searchDescription = "Check the spelling or try a new search."

    /// "No Results for" over the query in curly quotes, on its own line as in the frame.
    static func searchTitle(_ text: String) -> String {
        "No Results for\n\u{201C}\(text.trimmingCharacters(in: .whitespacesAndNewlines))\u{201D}"
    }

    static func noSelectionTitle(_ section: SidebarSection) -> String {
        switch section {
        case .skills: "No Skill Selected"
        case .projects: "No Project Selected"
        case .categories: "No Category Selected"
        case .tags: "No Tag Selected"
        case .machines: "No Machine Selected"
        }
    }
}
