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
