import Foundation
import Yams

/// Ordered display values from the parser's trusted source split. Scalars use their YAML text
/// value; collections also keep their authored YAML for entries that cannot fit a nested table.
struct SkillFrontmatterRow: Equatable {
    let key: String
    let value: String
    let isCollection: Bool
    let nestedValue: SkillFrontmatterValue?

    static func rows(from parsed: ParsedSkill) -> [SkillFrontmatterRow] {
        guard let source = parsed.preservedFile?.frontmatterSource,
              let document = try? CheckedYAMLLoader.composeAndLoad(yaml: source),
              let mapping = document.root?.mapping else { return [] }
        // Rendering needs a trustworthy mapping, even when required identity fields are absent.
        let preserved = SkillParser.preservedFrontmatter(
            source: source, document: document)
        guard preserved.entriesAreTrustworthy else { return [] }
        return zip(preserved.entries, mapping).map { entry, pair in
            if case let .scalar(scalar) = pair.value {
                return SkillFrontmatterRow(key: entry.key, value: scalarText(scalar.string),
                                           isCollection: false, nestedValue: nil)
            }
            let source = String(preserved.source[entry.sourceRange])
            return SkillFrontmatterRow(key: entry.key, value: collectionYAML(source), isCollection: true,
                                       nestedValue: SkillFrontmatterValue.table(from: pair.value))
        }
    }

    fileprivate static func scalarText(_ value: String) -> String {
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
        let valueToken = first.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .drop(while: { $0.hasPrefix("!") }).first
        let isFlow = valueToken?.first == "[" || valueToken?.first == "{"
        let commentIndent = isFlow ? 1 : max(1, indent)
        // The trusted entry extends to the next key; lower-indent notes after its value aren't part of that value.
        if let end = lines.indices.first(where: {
            $0 > (contentLines.last ?? -1) && lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("#")
                && lines[$0].prefix(while: { $0 == " " }).count < commentIndent
        }) {
            lines.removeSubrange(end...)
        }
        // Inline flow collections already have meaningful indentation relative to their opening token.
        if isFlow {
            while let last = lines.last {
                let text = last.trimmingCharacters(in: .whitespaces)
                guard text.isEmpty || text.hasPrefix("#") else { break }
                lines.removeLast()
            }
            return scalarText(([first] + lines).joined(separator: "\n"))
        }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        let block = lines.map { String($0.dropFirst(min(indent, $0.prefix(while: { $0 == " " }).count))) }
        let prefix = !first.isEmpty && !first.hasPrefix("#") ? [first] : []
        return scalarText((prefix + block).joined(separator: "\n"))
    }
}

/// A bounded display tree, separate from the source retained for YAML fallback.
/// Arrays preserve repeated list items and distinct YAML keys with identical text.
indirect enum SkillFrontmatterValue: Equatable {
    case scalar(String)
    case table(headers: [String]?, values: [SkillFrontmatterValue])

    static func table(from node: Node) -> SkillFrontmatterValue? {
        var remaining = 6
        guard let value = display(node, depth: 1, remaining: &remaining),
              case .table = value else { return nil }
        return value
    }

    private static func display(_ node: Node, depth: Int, remaining: inout Int) -> SkillFrontmatterValue? {
        if let scalar = node.scalar {
            remaining -= 1
            return remaining >= 0 ? .scalar(SkillFrontmatterRow.scalarText(scalar.string)) : nil
        }
        let headers: [String]?
        let children: [Node]
        switch node {
        case let .mapping(mapping):
            headers = mapping.map { SkillFrontmatterRow.scalarText($0.key.scalar?.string ?? "") }
            children = mapping.map(\.value)
        case let .sequence(sequence):
            headers = nil
            children = Array(sequence)
        default: return nil // The checked loader and trust rule already refuse aliases.
        }
        if children.isEmpty {
            remaining -= 1
            return remaining >= 0 ? .scalar(headers == nil ? "[]" : "{}") : nil
        }
        guard depth <= 3 else { return nil }
        var values: [SkillFrontmatterValue] = []
        for child in children {
            guard let value = display(child, depth: depth + 1, remaining: &remaining) else { return nil }
            values.append(value)
        }
        return .table(headers: headers, values: values)
    }
}
