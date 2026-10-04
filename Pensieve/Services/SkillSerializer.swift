import Foundation

/// Composes a skill's identity (`name` + `description`) + body into the canonical Agent-Skills
/// YAML-frontmatter format: exactly those two keys, one fence, blank line, body. New authored skills
/// use this composition; local imports preserve their source frontmatter when possible.
/// Rewrites of existing files preserve frontmatter Pensieve did not author.
/// Pensieve writes its bookkeeping (scope, tags, cursor config, origin, agents, timestamps)
/// to the manifest overlay (PLAN-07 / 07.3). Preserved source entries, including tags, stay
/// in SKILL.md as authored; the overlay remains Pensieve's tag record.
///
/// Hand-rolled rather than Yams' emitter on purpose: we control every byte so the
/// output is diff-stable and the one-list-item-per-line granularity stays available to the
/// later union-merge work. Round-trip-verified through CheckedYAMLLoader in SkillFrontmatterTests.
enum SkillSerializer {
    struct RewriteResult {
        let content: String
        let isUnchanged: Bool
    }

    /// Value-typed entry point so composing write paths (07.2) and tests need not build a Skill.
    static func serialize(name: String, description: String, body: String) -> String {
        compose(name: name, description: description, body: body, lineEnding: "\n")
    }

    private static func compose(
        name: String,
        description: String,
        body: String,
        lineEnding: String
    ) -> String {
        var lines: [String] = []
        lines.append("---")
        lines.append("name: \(quotedScalar(name))")
        lines.append("description: \(quotedScalar(description))")
        lines.append("---")
        lines.append("")
        lines.append(body)
        return lines.joined(separator: lineEnding)
    }

    /// Rewrite an existing skill without changing frontmatter Pensieve did not author.
    /// Body-only legacy files use the canonical fallback identity, matching the pre-preservation save path.
    static func rewrite(
        body: String,
        preserving parsed: ParsedSkill,
        fallbackName: String,
        fallbackDescription: String
    ) -> String {
        rewriteResult(body: body, preserving: parsed, fallbackName: fallbackName,
                      fallbackDescription: fallbackDescription).content
    }

    /// Reports the existing unchanged branch so the store need not reconstruct its return value.
    static func rewriteResult(
        body: String,
        preserving parsed: ParsedSkill,
        fallbackName: String,
        fallbackDescription: String
    ) -> RewriteResult {
        let originalBody = parsed.preservedFile?.body ?? SkillParser.canonicalBody(parsed.body)
        let draft = SkillParser.canonicalBody(body)
        if normalizeLineEndings(draft, to: "\n") == normalizeLineEndings(originalBody, to: "\n") {
            return RewriteResult(content: parsed.preservedFile?.source ?? parsed.body, isUnchanged: true)
        }
        let body = normalizeLineEndings(draft, to: parsed.preferredLineEnding)
        if let file = parsed.preservedFile {
            let separator: String
            switch file.bodyPrefix.utf8.last {
            case 0x0A: separator = ""
            case 0x0D: separator = "\n"
            default: separator = parsed.preferredLineEnding
            }
            return RewriteResult(content: file.bodyPrefix + separator + body + file.bodySuffix, isUnchanged: false)
        }
        let content = compose(
            name: fallbackName,
            description: fallbackDescription,
            body: body,
            lineEnding: parsed.preferredLineEnding
        ) + parsed.trailingLineBreaks
        return RewriteResult(content: content, isUnchanged: false)
    }

    /// Normalize the two identity entries while retaining every other trustworthy source slice.
    /// Returns nil rather than fabricating output when the parser could not safely identify entries.
    static func normalizeIdentity(name: String, description: String, parsed: ParsedSkill) -> String? {
        guard let frontmatter = parsed.preservedFrontmatter else {
            guard parsed.preservedFile == nil else { return nil }
            let output = compose(
                name: name,
                description: description,
                body: parsed.body,
                lineEnding: parsed.preferredLineEnding
            )
            return identityOutputIsValid(output, original: parsed, name: name, description: description) ? output : nil
        }
        guard frontmatter.entriesAreTrustworthy, let file = parsed.preservedFile else { return nil }
        let source = replacingIdentityEntries(
            in: frontmatter,
            name: name,
            description: description,
            lineEnding: parsed.preferredLineEnding
        )
        let output = file.frontmatterPrefix + source + file.frontmatterSuffix
        return identityOutputIsValid(output, original: parsed, name: name, description: description) ? output : nil
    }

    /// Compare checked nodes, including their resolved tags and complete nested structure. This
    /// covers Yams' tuple-valued !!omap/!!pairs as well as scalars, sequences, mappings and sets,
    /// without depending on Foundation's equality for arbitrary constructed Swift values.
    private static func identityOutputIsValid(
        _ output: String, original: ParsedSkill, name: String, description: String
    ) -> Bool {
        let written = SkillParser.parse(output)
        guard written.name == name, written.description == description,
              let writtenYAML = written.preservedFrontmatter?.source else { return false }
        guard let originalYAML = original.preservedFrontmatter?.source else { return true }
        guard let before = try? CheckedYAMLLoader.composeAndLoad(yaml: originalYAML).root,
              let after = try? CheckedYAMLLoader.composeAndLoad(yaml: writtenYAML).root,
              before.tag == after.tag,
              let beforeMapping = before.mapping, let afterMapping = after.mapping else { return false }
        let beforeEntries = beforeMapping.filter { !["name", "description"].contains($0.key.string ?? "") }
        let afterEntries = afterMapping.filter { !["name", "description"].contains($0.key.string ?? "") }
        return beforeEntries.count == afterEntries.count && zip(beforeEntries, afterEntries).allSatisfy {
            $0.key == $1.key && $0.value == $1.value
        }
    }

    private static func replacingIdentityEntries(
        in frontmatter: PreservedFrontmatter,
        name: String,
        description: String,
        lineEnding: String
    ) -> String {
        let hasDescription = frontmatter.entries.contains { $0.key == "description" }
        var output = ""
        var cursor = frontmatter.source.startIndex
        for entry in frontmatter.entries {
            output += frontmatter.source[cursor..<entry.sourceRange.lowerBound]
            let original = String(frontmatter.source[entry.sourceRange])
            switch entry.key {
            case "name":
                let extra = hasDescription ? nil : "description: \(quotedScalar(description))"
                output += replacingEntry(
                    original,
                    with: "name: \(quotedScalar(name))",
                    additionalLine: extra,
                    lineEnding: lineEnding
                )
            case "description":
                output += replacingEntry(
                    original,
                    with: "description: \(quotedScalar(description))",
                    additionalLine: nil,
                    lineEnding: lineEnding
                )
            default:
                output += original
            }
            cursor = entry.sourceRange.upperBound
        }
        output += frontmatter.source[cursor...]
        return output
    }

    private static func replacingEntry(
        _ source: String,
        with replacement: String,
        additionalLine: String?,
        lineEnding: String
    ) -> String {
        let sourceLines = SkillParser.sourceLines(in: source, yamlBreaks: false)
        let lines = sourceLines.compactMap { line -> (content: String, ending: String)? in
            guard !line.sourceRange.isEmpty else { return nil }
            return (String(source[line.contentRange]), String(source[line.contentRange.upperBound..<line.sourceRange.upperBound]))
        }
        var triviaStart = lines.count
        while triviaStart > 1 {
            let content = lines[triviaStart - 1].content
            guard content.isEmpty || content.trimmingCharacters(in: .whitespaces).hasPrefix("#") else { break }
            triviaStart -= 1
        }
        let inserted = [replacement, additionalLine].compactMap { $0 }.joined(separator: lineEnding)
        if triviaStart < lines.count {
            return inserted + lineEnding
                + lines[triviaStart...].map { $0.content + $0.ending }.joined()
        }
        return inserted + (lines.last?.ending ?? "")
    }

    static func normalizeLineEndings(_ value: String, to lineEnding: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: lineEnding)
    }

    /// Shared canonical YAML scalar quoter for both SKILL.md frontmatter and the manifest overlay
    /// (PLAN-07 / 07.3). Emits a scalar that CheckedYAMLLoader re-reads as the EXACT original String.
    /// Double-quote and escape whenever the value is not provably a plain safe string.
    static func quotedScalar(_ value: String) -> String {
        // Force quoting when the value carries a YAML-unsafe control/break character even if the
        // resolver oracle would round-trip the bare scalar: an unquoted CR/NEL/LS/PS reaches the
        // reader as a real line break and corrupts the document. (PLAN-19 security review.)
        guard hasYAMLUnsafeControl(value) || needsQuoting(value) else { return value }
        return "\"\(escapeForDoubleQuoted(value))\""
    }

    /// True iff `value` contains a character libyaml (Yams) would treat as a line break or a raw
    /// control that a double-quoted scalar must escape: any C0 control, DEL, NEL (U+0085),
    /// LS (U+2028), PS (U+2029), or the noncharacters U+FFFE and U+FFFF.
    static func hasYAMLUnsafeControl(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            $0.value < 0x20 || ($0.value >= 0x7F && $0.value <= 0x9F)
                || $0.value == 0x2028 || $0.value == 0x2029
                || $0.value == 0xFFFE || $0.value == 0xFFFF
        }
    }

    /// Escape a string for embedding inside a YAML double-quoted scalar so libyaml (Yams) re-reads
    /// the EXACT original. Beyond `\`, `"`, and the printable-safe body we MUST escape every character
    /// libyaml folds as a line break — CR (U+000D), NEL (U+0085), LS (U+2028), PS (U+2029) — plus the
    /// remaining C0 controls, DEL, U+FFFE, and U+FFFF, or an untrusted value (e.g. a skill's
    /// repo-relative `path`) can break the scalar mid-document or silently fold, corrupting the
    /// manifest. (PLAN-19 security review.)
    static func escapeForDoubleQuoted(_ value: String) -> String {
        var out = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            case "\u{0}": out += "\\0"
            default:
                let v = scalar.value
                // C0 controls, DEL, and the ENTIRE C1 range (U+0080–U+009F, incl. NEL U+0085):
                // libyaml rejects raw C1 controls even inside a double-quoted scalar, so all of them
                // must be \xNN-escaped, not just NEL. (PLAN-19 security review round 2.)
                if v < 0x20 || (v >= 0x7F && v <= 0x9F) {
                    out += String(format: "\\x%02X", v)
                } else if v == 0x2028 || v == 0x2029 || v == 0xFFFE || v == 0xFFFF {
                    out += String(format: "\\u%04X", v)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    private static func needsQuoting(_ value: String) -> Bool {
        // Use the checked loader's single composed inspection as the oracle. Quote when the bare
        // scalar does not construct as the identical String, or when its checked integer
        // constructor safely falls back from a base-60 overflow that older builds would trap on.
        // Other non-string tags that construct as String keep their legacy bare bytes.
        // (PLAN-07 / 07.1 review fix; PLAN-38 / 38.2-f.)
        guard let inspection = try? CheckedYAMLLoader.inspectBareScalar(yaml: value) else {
            return true
        }
        return inspection.value as? String != value || inspection.requiresLegacyIntegerQuote
    }
}
