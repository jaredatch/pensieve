import Foundation
import Yams

// MARK: - Parsed Skill

struct PreservedFrontmatter {
    struct Entry {
        let key: String
        /// A range into `PreservedFrontmatter.source`, from this key line to the next key line.
        let sourceRange: Range<String.Index>
    }

    /// Exact source text between the opening and closing fence lines.
    let source: String
    let entries: [Entry]
    /// False means callers may copy `source`, but must not use `entries` to rewrite individual keys.
    let entriesAreTrustworthy: Bool
}

struct PreservedSkillFile {
    /// Exact original file bytes, returned directly when a body-only save changes no body text.
    let source: String
    /// Exact bytes around the frontmatter source, used by migration to replace only identity entries.
    let frontmatterPrefix: String
    let frontmatterSuffix: String
    /// Exact bytes before and after the canonical body, used to splice a changed body without
    /// reconstructing leading trivia, fence lines, separators, or terminal line breaks.
    let bodyPrefix: String
    let bodySuffix: String
    /// Canonical body inside the closed fence pair, even when the YAML is not admissible.
    let body: String
}

private struct ExtractedFrontmatter {
    let frontmatter: String
    let body: String
    let preservedFile: PreservedSkillFile
}

struct ParsedSkill {
    var name: String?
    var description: String?
    var tags: [String]
    var scope: SkillScope?
    var cursorConfig: CursorAdapterConfig?
    var body: String
    var importedFrom: String?
    var preservedFrontmatter: PreservedFrontmatter?
    var preservedFile: PreservedSkillFile?
    /// The exact number of terminal LF characters in the source file, separate from canonical `body`.
    var trailingNewlineCount = 0
    /// Exact terminal YAML line-break bytes, retained separately from the canonical body.
    var trailingLineBreaks = ""
    /// The file's existing line-ending style. Structural lines added by a rewrite use this style.
    var preferredLineEnding = "\n"

    /// Tolerant signal: the file had a parseable YAML mapping carrying a `name` key.
    /// (A present-but-empty `description` still counts as "has frontmatter".)
    /// Distinct from `hasRequiredFrontmatter`, which is the strict spec gate.
    var hasFrontmatter: Bool {
        name != nil
    }

    /// The strict Agent-Skills requirement: BOTH `name` and `description` present and non-empty.
    /// This — not `hasFrontmatter` / "did it parse" — is the gate used at import preservation
    /// (07.2), migration normalization (07.5), and rebuild admission (07.4). A body-only file
    /// parses successfully (as all-body) but is NOT a valid skill.
    var hasRequiredFrontmatter: Bool {
        (name?.isEmpty == false) && (description?.isEmpty == false)
    }
}

// MARK: - Parser

enum SkillParser {
    /// Parse a skill file that may carry YAML frontmatter (`name` + `description`, the
    /// Agent-Skills standard's two fields). Tolerant: returns whatever keys are present;
    /// absent/extra keys are ignored. Falls back to treating the entire content as body when
    /// there is no parseable YAML mapping carrying a `name`.
    static func parse(_ content: String) -> ParsedSkill {
        let trailingLineBreaks = trailingLineBreaks(in: content)
        let preferredLineEnding = preferredLineEnding(in: content)
        if let extracted = extractFrontmatter(content) {
            if let parsed = parseYAMLFrontmatter(
                extracted.frontmatter,
                body: extracted.body,
                preservedFile: extracted.preservedFile,
                trailingLineBreaks: trailingLineBreaks,
                preferredLineEnding: preferredLineEnding
            ) {
                return parsed
            }
            return ParsedSkill(
                tags: [],
                body: content,
                preservedFile: extracted.preservedFile,
                trailingNewlineCount: trailingLineBreaks.utf8.filter { $0 == 0x0A }.count,
                trailingLineBreaks: trailingLineBreaks,
                preferredLineEnding: preferredLineEnding
            )
        }
        // No valid frontmatter — treat the entire content as body.
        return ParsedSkill(
            tags: [],
            body: content,
            trailingNewlineCount: trailingLineBreaks.utf8.filter { $0 == 0x0A }.count,
            trailingLineBreaks: trailingLineBreaks,
            preferredLineEnding: preferredLineEnding
        )
    }

    /// Parse a .mdc file (Cursor format) for import. Unchanged contract: surfaces the
    /// description + globs + alwaysApply into a CursorAdapterConfig and strips the body.
    static func parseMDC(_ content: String) -> ParsedSkill {
        guard let extracted = extractFrontmatter(content) else {
            return ParsedSkill(tags: [], body: content, importedFrom: "cursor")
        }
        let frontmatter = extracted.frontmatter
        let body = extracted.body

        var config = CursorAdapterConfig()
        var description: String?

        for line in frontmatter.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("description:") {
                description = String(trimmed.dropFirst("description:".count)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("globs:") {
                let globStr = String(trimmed.dropFirst("globs:".count)).trimmingCharacters(in: .whitespaces)
                config.globs = globStr.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            } else if trimmed.hasPrefix("alwaysApply:") {
                let val = String(trimmed.dropFirst("alwaysApply:".count)).trimmingCharacters(in: .whitespaces)
                config.alwaysApply = val == "true"
            }
        }

        config.description = description

        return ParsedSkill(
            description: description,
            tags: [],
            cursorConfig: config,
            body: body.trimmingCharacters(in: .whitespacesAndNewlines),
            importedFrom: "cursor"
        )
    }

    /// Strip YAML frontmatter (if present) and return only the markdown body.
    /// Used by editor and preview to hide raw frontmatter from the user.
    /// A file with no frontmatter reads in the same canonical form, so a fingerprint seeded from it compares
    /// with a draft the way a frontmatter-backed one does (batch Layer-2, round 4).
    static func stripFrontmatter(_ content: String) -> String {
        guard let extracted = extractFrontmatter(content) else { return canonicalBody(content) }
        return extracted.body
    }

    /// The body as the store reads it back: newlines trimmed at both ends (what `extractFrontmatter` returns).
    /// The self-write fingerprint and a draft's dirtiness compare in this form, so a body that ends in a
    /// newline is neither unsaved after its own save nor an external change when the file is read back
    /// (batch Layer-2: the app's own Save read as "Modified externally — reloaded", and the editor's last
    /// empty line vanished).
    static func canonicalBody(_ body: String) -> String {
        String(body[canonicalBodyRange(in: body)])
    }

    private static func canonicalBodyRange(in body: String) -> Range<String.Index> {
        let scalars = body.unicodeScalars
        var lower = scalars.startIndex
        var upper = scalars.endIndex
        while lower < upper, isYAMLLineBreak(scalars[lower]) {
            lower = scalars.index(after: lower)
        }
        while upper > lower {
            let previous = scalars.index(before: upper)
            guard isYAMLLineBreak(scalars[previous]) else { break }
            upper = previous
        }
        return lower..<upper
    }

    // MARK: - Private

    /// Line-based fence detection: the file must open (after any leading blank lines) with a
    /// line that is exactly `---`, and the frontmatter ends at the NEXT line that is exactly
    /// `---`. Matching whole fence lines (not the substring "\n---") makes detection robust to
    /// a YAML/markdown body that itself contains a `---` rule or a `----` setext underline.
    private static func extractFrontmatter(
        _ content: String
    ) -> ExtractedFrontmatter? {
        let lines = sourceLines(in: content)

        var openIndex = 0
        while openIndex < lines.count, content[lines[openIndex].contentRange]
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            openIndex += 1
        }
        guard openIndex < lines.count,
              content[lines[openIndex].contentRange].trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
            return nil
        }

        var closeIndex = -1
        var cursor = openIndex + 1
        while cursor < lines.count {
            if content[lines[cursor].contentRange].trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
                closeIndex = cursor
                break
            }
            cursor += 1
        }
        guard closeIndex > openIndex else { return nil }

        let frontmatterStart = lines[openIndex].sourceRange.upperBound
        let frontmatterEnd = closeIndex > openIndex + 1
            ? lines[closeIndex - 1].contentRange.upperBound
            : frontmatterStart
        let frontmatter = String(content[frontmatterStart..<frontmatterEnd])
        let bodyStart = lines[closeIndex].sourceRange.upperBound
        let rawBody = String(content[bodyStart...])
        let bodyRange = canonicalBodyRange(in: rawBody)
        let body = String(rawBody[bodyRange])
        let bodySuffix = body.isEmpty
            ? terminalLineEnding(in: content)
            : String(rawBody[bodyRange.upperBound...])
        return ExtractedFrontmatter(
            frontmatter: frontmatter,
            body: body,
            preservedFile: PreservedSkillFile(
                source: content,
                frontmatterPrefix: String(content[..<frontmatterStart]),
                frontmatterSuffix: String(content[frontmatterEnd...]),
                bodyPrefix: String(content[..<bodyStart]) + rawBody[..<bodyRange.lowerBound],
                bodySuffix: bodySuffix,
                body: body
            )
        )
    }

    /// Returns nil when there is no parseable YAML mapping OR no `name` key — the caller then
    /// falls back to whole-content-as-body. A present `name` (even empty string) yields a
    /// ParsedSkill; the strict `hasRequiredFrontmatter` predicate decides validity downstream.
    private static func parseYAMLFrontmatter(
        _ yamlString: String,
        body: String,
        preservedFile: PreservedSkillFile,
        trailingLineBreaks: String,
        preferredLineEnding: String
    ) -> ParsedSkill? {
        guard let loaded = try? CheckedYAMLLoader.composeAndLoad(yaml: yamlString),
              let root = loaded.root,
              let mapping = loaded.value as? [String: Any],
              let name = mapping["name"] as? String else {
            return nil
        }

        let description = mapping["description"] as? String

        let tags: [String]
        if let tagsArray = mapping["tags"] as? [Any] {
            tags = tagsArray.compactMap { $0 as? String }
        } else {
            tags = []
        }

        let scope: SkillScope?
        if let scopeStr = mapping["scope"] as? String {
            scope = SkillScope(rawValue: scopeStr)
        } else {
            scope = nil
        }

        return ParsedSkill(
            name: name,
            description: description,
            tags: tags,
            scope: scope,
            cursorConfig: nil,
            body: body,
            preservedFrontmatter: preservedFrontmatter(
                source: yamlString,
                yamlKeys: Set(mapping.keys),
                root: root,
                rootIsFlowMapping: loaded.rootIsFlowMapping
            ),
            preservedFile: preservedFile,
            trailingNewlineCount: trailingLineBreaks.utf8.filter { $0 == 0x0A }.count,
            trailingLineBreaks: trailingLineBreaks,
            preferredLineEnding: preferredLineEnding
        )
    }
}
