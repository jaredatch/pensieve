import Foundation

/// The editor's complete-file save policy. Parsing remains tolerant elsewhere; changed frontmatter
/// must pass this admission before any write. Import and migration retain their identity splice policy.
enum SkillDocumentEditing {
    enum Refusal: LocalizedError {
        case unreadableFrontmatter
        case missingIdentity([String])
        case renamed(String)

        var errorDescription: String? {
            switch self {
            case .unreadableFrontmatter:
                return "Couldn't save. The frontmatter at the top of the file can't be read."
            case .missingIdentity(let keys):
                return "Couldn't save. The frontmatter needs a " + keys.joined(separator: " and a ") + "."
            case .renamed(let currentName):
                return "Couldn't save. A skill can't be renamed here yet, so change the name back to \"\(currentName)\"."
            }
        }
    }

    /// Line endings are editor transport; boundary newlines and Unicode spelling are file content.
    static func matches(_ text: String, _ baseline: String?) -> Bool {
        guard let baseline else { return false }
        return normalized(text).utf8.elementsEqual(normalized(baseline).utf8)
    }

    static func normalized(_ text: String, ending: String = "\n") -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: ending)
    }

    static func rewrite(draft: String, original: String, name: String,
                        description: String, slug: String) throws -> SkillRewriteResult {
        let before = SkillParser.parse(original, retainingBOM: true)
        let hasBOM = original.unicodeScalars.first == "\u{feff}"
        let text = hasBOM && draft.unicodeScalars.first != "\u{feff}" ? "\u{feff}" + draft : draft
        if matches(text, original) { return SkillRewriteResult(content: original, didChange: false) }
        let after = SkillParser.parse(text, retainingBOM: true)
        let output: String
        if let previous = before.preservedFile, let next = after.preservedFile,
           matches(previous.header, next.header) {
            // The unchanged header retains even mixed line endings and unreadable YAML verbatim.
            output = previous.header + normalized(next.rawBody, ending: before.preferredLineEnding)
        } else if before.preservedFile == nil && after.preservedFile == nil {
            // No recognized frontmatter on either side: retain the legacy canonical fallback.
            let body = hasBOM ? String(text.unicodeScalars.dropFirst()) : text
            let fallback = SkillSerializer.serialize(name: name, description: description,
                body: SkillParser.canonicalBody(body))
            output = (hasBOM ? "\u{feff}" : "") + normalized(fallback, ending: before.preferredLineEnding)
                + before.trailingLineBreaks
        } else {
            try validateFrontmatter(after, currentName: before.name ?? name, slug: slug)
            output = normalized(text, ending: before.preferredLineEnding)
        }
        return SkillRewriteResult(content: output, didChange: !output.utf8.elementsEqual(original.utf8))
    }

    /// One admission point for edited frontmatter, reusable by a future folder-rename operation.
    static func validateFrontmatter(_ parsed: ParsedSkill, currentName: String, slug: String) throws {
        guard let file = parsed.preservedFile,
              let loaded = try? CheckedYAMLLoader.composeAndLoad(yaml: file.frontmatterSource),
              let root = loaded.root, let mapping = loaded.value as? [String: Any],
              SkillParser.preservedFrontmatter(source: file.frontmatterSource, root: root,
                  rootIsFlowMapping: loaded.rootIsFlowMapping).entriesAreTrustworthy else {
            throw Refusal.unreadableFrontmatter
        }
        let missing = ["name", "description"].filter { (mapping[$0] as? String)?.isEmpty != false }
        guard missing.isEmpty else { throw Refusal.missingIdentity(missing) }
        guard mapping["name"] as? String == currentName else { throw Refusal.renamed(currentName) }
    }
}
