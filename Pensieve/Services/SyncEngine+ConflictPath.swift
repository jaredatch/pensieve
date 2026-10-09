import Foundation

extension SyncEngine {
    /// One reading for conflict classification, grouping, badges and history lookup.
    /// Unknown paths retain the body fallback; degenerate paths never identify a skill.
    struct ConflictPath {
        let kind: ConflictKind
        let slug: String?

        var skillSlug: String? { kind == .body || kind == .overlay ? slug : nil }
    }

    static func kind(for path: String) -> ConflictKind { conflictPath(for: path).kind }

    static func conflictPath(for path: String) -> ConflictPath {
        let parts = PathSyntax.components(path, omittingEmptySubsequences: false)
        if parts.count >= 3, parts[0] == "manifest" {
            if parts[1] == "skills" {
                return ConflictPath(kind: .overlay, slug: parts.count == 3 ? manifestSlug(parts[2]) : nil)
            }
            if parts[1] == "categories" {
                return ConflictPath(kind: .category, slug: parts.count == 3 ? manifestSlug(parts[2]) : nil)
            }
        }
        if parts == ["manifest", "projects.yaml"] { return ConflictPath(kind: .project, slug: nil) }
        if parts.count == 3, parts[0] == "skills", parts[2] == "SKILL.md", isConflictName(parts[1]) {
            return ConflictPath(kind: .body, slug: parts[1])
        }
        return ConflictPath(kind: .body, slug: nil)
    }

    private static func manifestSlug(_ filename: String) -> String? {
        let scalars = filename.unicodeScalars
        let suffix = ".yaml".unicodeScalars
        guard scalars.suffix(suffix.count).elementsEqual(suffix) else { return nil }
        let slug = String(String.UnicodeScalarView(scalars.dropLast(suffix.count)))
        return isConflictName(slug) ? slug : nil
    }

    private static func isConflictName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
    }
}
