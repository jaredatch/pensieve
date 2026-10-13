import Foundation

/// Ordered display values from the parser's trusted source split. Scalars use their YAML text
/// value; collections keep their authored YAML rather than a reconstructed dictionary description.
struct SkillFrontmatterRow: Equatable {
    let key: String
    let value: String
    let isCollection: Bool

    static func rows(from parsed: ParsedSkill) -> [SkillFrontmatterRow] {
        guard let source = parsed.preservedFile?.frontmatterSource,
              let document = try? CheckedYAMLLoader.composeAndLoad(yaml: source),
              let root = document.root, let mapping = root.mapping else { return [] }
        // Rendering needs a trustworthy mapping, even when required identity fields are absent.
        let preserved = SkillParser.preservedFrontmatter(
            source: source, root: root, rootIsFlowMapping: document.rootIsFlowMapping)
        guard preserved.entriesAreTrustworthy else { return [] }
        return zip(preserved.entries, mapping).map { entry, pair in
            if case let .scalar(scalar) = pair.value {
                return SkillFrontmatterRow(key: entry.key, value: scalarText(scalar.string), isCollection: false)
            }
            let source = String(preserved.source[entry.sourceRange])
            return SkillFrontmatterRow(key: entry.key, value: collectionYAML(source), isCollection: true)
        }
    }

    private static func scalarText(_ value: String) -> String {
        var scalars = value.unicodeScalars
        // LF ends normalized YAML block scalars; other hidden scalars must remain for the table to mark.
        while scalars.last?.value == 10 { scalars.removeLast() }
        return String(scalars)
    }

    private static func collectionYAML(_ entry: String) -> String {
        guard let colon = entry.firstIndex(of: ":") else { return "" }
        let source = String(entry[entry.index(after: colon)...]).replacingOccurrences(of: "\r\n", with: "\n")
        var lines = source.components(separatedBy: "\n")
        let first = lines.removeFirst().trimmingCharacters(in: .whitespaces)
        let contentLines = lines.indices.filter {
            let text = lines[$0].trimmingCharacters(in: .whitespaces)
            return !text.isEmpty && !text.hasPrefix("#")
        }
        let indent = contentLines.map { lines[$0].prefix(while: { $0 == " " }).count }.min() ?? 0
        let commentIndent = first.isEmpty || first.hasPrefix("#") ? max(1, indent) : 1
        // The trusted entry extends to the next key; lower-indent notes after its value aren't part of that value.
        if let end = lines.indices.first(where: {
            $0 > (contentLines.last ?? -1) && lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("#")
                && lines[$0].prefix(while: { $0 == " " }).count < commentIndent
        }) {
            lines.removeSubrange(end...)
        }
        // Inline flow collections already have meaningful indentation relative to their opening token.
        if !first.isEmpty, !first.hasPrefix("#") {
            return ([first] + lines).joined(separator: "\n").trimmingCharacters(in: .newlines)
        }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        return lines.map { String($0.dropFirst(min(indent, $0.prefix(while: { $0 == " " }).count))) }
            .joined(separator: "\n")
    }
}
