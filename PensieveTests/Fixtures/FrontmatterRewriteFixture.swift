import Foundation

/// Expected bytes come from fixture construction, independently of the parser's fence and entry ranges.
struct FrontmatterRewriteFixture {
    let label: String
    let source: String
    let header: String?
    let trustsEntries: Bool
    let lineEnding: String
    let terminal: String

    private struct Block {
        let label: String
        let yaml: String
        let safe: Bool

        init(_ label: String, _ yaml: String, _ safe: Bool) {
            self.label = label
            self.yaml = yaml
            self.safe = safe
        }
    }

    static let lineBreaks = ["\n", "\r\n", "\r", "\u{85}", "\u{2028}", "\u{2029}"]

    struct Syntax {
        let label: String
        let fields: String
        let trusted: Bool
        var expectedKey: String?
        var expectedValue: String?
        var excludedText: [String] = []
        var rootPrefix = ""

        func document(name: String) -> String {
            "---\n\(rootPrefix)name: \(name)\ndescription: Use for *.md files\n\(fields)\n---\n\nOriginal body\n"
        }
    }

    static let syntaxCases: [Syntax] = [
        Syntax(label: "plain star", fields: "allowed-tools: Bash(npm run *)", trusted: true,
               expectedKey: "allowed-tools", expectedValue: "Bash(npm run *)"),
        Syntax(label: "plain ampersand", fields: "company: A &partner", trusted: true,
               expectedKey: "company", expectedValue: "A &partner"),
        Syntax(label: "double quoted star", fields: "patterns: \"*.md files\"", trusted: true,
               expectedKey: "patterns", expectedValue: "*.md files"),
        Syntax(label: "double quoted ampersand", fields: "patterns: \"A &partner\"", trusted: true,
               expectedKey: "patterns", expectedValue: "A &partner"),
        Syntax(label: "single quoted star", fields: "patterns: '*.md files'", trusted: true,
               expectedKey: "patterns", expectedValue: "*.md files"),
        Syntax(label: "single quoted ampersand", fields: "patterns: 'A &partner'", trusted: true,
               expectedKey: "patterns", expectedValue: "A &partner"),
        Syntax(label: "comment star", fields: "# see *.md\nlicense: MIT", trusted: true,
               expectedKey: "license", expectedValue: "MIT", excludedText: ["# see *.md"]),
        Syntax(label: "comment ampersand", fields: "# see &notes\nlicense: MIT", trusted: true,
               expectedKey: "license", expectedValue: "MIT", excludedText: ["# see &notes"]),
        Syntax(label: "flow star", fields: "tools: {commands: [Bash(npm run *), '*.md']}", trusted: true,
               expectedKey: "tools", expectedValue: "{commands: [Bash(npm run *), '*.md']}"),
        Syntax(label: "flow ampersand", fields: "tools: {names: [\"A &partner\"]}", trusted: true,
               expectedKey: "tools", expectedValue: "{names: [\"A &partner\"]}"),
        Syntax(label: "block scalar star", fields: "notes: |-\n  Use *.md", trusted: true,
               expectedKey: "notes", expectedValue: "Use *.md"),
        Syntax(label: "block scalar ampersand", fields: "notes: |-\n  Use A &partner", trusted: true,
               expectedKey: "notes", expectedValue: "Use A &partner"),
        Syntax(label: "mapping scalar anchor", fields: "metadata: &details value\ncopy: *details", trusted: false),
        Syntax(label: "mapping container anchor", fields: "metadata: &details\n  owner: upstream\ncopy: *details",
               trusted: false),
        Syntax(label: "sequence item anchor", fields: "tools:\n  - &tool Read\n  - *tool", trusted: false),
        Syntax(label: "sequence container anchor", fields: "tools: &tools [Read]\ncopy: *tools", trusted: false),
        Syntax(label: "nested flow anchor", fields: "metadata: {nested: [&item {key: value}, *item]}", trusted: false),
        Syntax(label: "merge alias", fields: "defaults: &defaults {owner: upstream}\nmetadata:\n  <<: *defaults", trusted: false),
        Syntax(label: "alias key", fields: "key-name: &key extra\n*key: value", trusted: false),
        Syntax(label: "anchor without alias", fields: "metadata: &details value", trusted: false),
        Syntax(label: "sequence anchor without alias", fields: "tools: &tools [Read]", trusted: false),
        Syntax(label: "mapping anchor without alias", fields: "metadata: &details {owner: upstream}", trusted: false),
        Syntax(label: "block mapping anchor without alias", fields: "metadata: &details\n  owner: upstream", trusted: false),
        Syntax(label: "block sequence anchor without alias", fields: "tools: &tools\n  - Read", trusted: false),
        Syntax(label: "root anchor without alias", fields: "license: MIT", trusted: false, rootPrefix: "&root\n"),
        Syntax(label: "key anchor without alias", fields: "&key license: MIT", trusted: false)
    ]

    struct HeaderRewrite {
        let label: String
        let original: String
        let draft: String
        let expected: String
        let expectedIdentity: String?
        let trusted: Bool
    }

    /// Cross original document damage with the proposed YAML, including repairs of incomplete headers.
    /// Mixed endings belong to the original; a changed Source header uses the existing CRLF save policy.
    static var headerSweep: [HeaderRewrite] {
        syntaxCases.flatMap { syntax in
            ["LF", "CRLF", "mixed"].flatMap { style in
                ["complete", "empty", "missing fence", "missing final newline", "malformed section"].map { shape in
                    let yaml = syntax.rootPrefix + "name: A\ndescription: D\n" + syntax.fields
                    let body = "Original body" + (shape == "missing final newline" ? "" : "\n")
                    let header: String
                    switch shape {
                    case "empty": header = "---\n---\n\n"
                    case "missing fence": header = "---\n" + yaml + "\n\n"
                    case "malformed section": header = "---\n" + yaml + "\nbroken: [\n---\n\n"
                    default: header = "---\n" + yaml + "\n---\n\n"
                    }
                    let ending = style == "LF" ? "\n" : "\r\n"
                    let original = withEndings(header, style: style) + body.replacingOccurrences(of: "\n", with: ending)
                    let draft = "---\n" + yaml.replacingOccurrences(of: "description: D", with: "description: Edited")
                        + "\n---\n\n" + body
                    let identity: String?
                    switch shape {
                    case "empty", "malformed section": identity = nil
                    case "missing fence":
                        // Without a closed frontmatter block these tokens are body text, copied verbatim.
                        identity = "---\(ending)name: New\(ending)description: New description\(ending)---"
                            + ending + ending + original
                    default:
                        identity = syntax.trusted ? original
                            .replacingOccurrences(of: "name: A", with: "name: New")
                            .replacingOccurrences(of: "description: D", with: "description: New description")
                            : nil
                    }
                    return HeaderRewrite(label: "\(syntax.label), \(style), \(shape)", original: original,
                        draft: draft, expected: withEndings(draft, style: style == "LF" ? "LF" : "CRLF"),
                        expectedIdentity: identity, trusted: syntax.trusted)
                }
            }
        }
    }

    private static func withEndings(_ source: String, style: String) -> String {
        let lines = source.components(separatedBy: "\n")
        return lines.enumerated().map { index, line in
            guard index < lines.count - 1 else { return line }
            let ending = style == "CRLF" || (style == "mixed" && index.isMultiple(of: 2)) ? "\r\n" : "\n"
            return line + ending
        }.joined()
    }

    static var sweep: [Self] {
        let blocks: [Block] = [
            Block("plain", "name: A\ndescription: D\nlicense: MIT", true),
            Block("quoted continuation", "name: A\ndescription : \"\"\nlicense: \"MIT"
                + "\ndescription: x\n # end\"", false),
            Block("spaced colon", "name: A\ndescription : D\nlicense: MIT", false),
            Block("hidden duplicate", "name: A\ndescription: D\nlicense : MIT\nmetadata: \"value"
                + "\nlicense: fake\n # end\"", false),
            Block("single flow", "{name: A, description: D, license: MIT}", false),
            Block("multiline flow", "{\nname: A,\ndescription: D,\nlicense: MIT\n}", false),
            Block("omap", "name: A\ndescription: D\nordered: !!omap\n  - first: one\n  - second: two\n"
                + "binary: !!binary SGVsbG8=\ndate: 2026-10-03\nnull: null\nfloat: .nan\nset: !!set {a: null, b: null}", true),
            Block("pairs", "name: A\ndescription: D\npairs: !!pairs\n  - first: one\n  - first: two", true),
            Block("empty", "", false),
            Block("missing fence", "name: A\ndescription: D\nlicense: MIT", false)
        ]
        return blocks.flatMap { block in
            let label = block.label
            return lineBreaks.flatMap { ending in
                ["", ending].map { terminal in
                    let yaml = block.yaml.replacingOccurrences(of: "\n", with: ending)
                    let beforeClose = yaml.isEmpty ? "" : yaml + ending
                    let header = "---" + ending + beforeClose
                        + (label == "missing fence" ? "" : "---" + ending + ending)
                    return Self(
                        label: "\(label), \(ending.debugDescription), terminal \(terminal.debugDescription)",
                        source: header + "Original body" + terminal,
                        header: label != "missing fence" && ["\n", "\r\n"].contains(ending) ? header : nil,
                        trustsEntries: block.safe && ["\n", "\r\n"].contains(ending),
                        lineEnding: ending,
                        terminal: terminal
                    )
                }
            }
        }
    }
}
