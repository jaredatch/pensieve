/// One selected version: the raw `git show` document (what Restore writes back, byte for byte)
/// and the frontmatter-stripped body the preview renders. Never restore the preview.
struct SkillHistorySelection: Equatable {
    let sha: String
    let document: String
    var previewBody: String { SkillHistoryPresentation.previewBody(from: document) }
}

enum SkillHistoryPresentation {
    static func previewBody(from raw: String) -> String { SkillParser.stripFrontmatter(raw) }
    static func rowTitle(for commit: GitCommit) -> String { commit.date.formatted(date: .abbreviated, time: .shortened) }
    static func rowSubtitle(for commit: GitCommit) -> String { commit.subject + " · " + commit.author }
}
