import XCTest
@testable import Pensieve

extension SkillSerializerTests {
    func testChangedBodyRewritePreservesEveryOtherByteAcrossRepeatedSaves() {
        let fixtures = [
            ("canonical LF", "---\nname: A\ndescription: D\n---\n\nBody\n"),
            ("no trailing newline", "---\nname: A\ndescription: D\n---\n\nBody"),
            ("no blank line after fence", "---\nname: A\ndescription: D\n---\nBody\n"),
            ("two blank lines after fence", "---\nname: A\ndescription: D\n---\n\n\nBody\n"),
            ("leading blank line", "\n---\nname: A\ndescription: D\n---\n\nBody\n"),
            ("fence trailing whitespace", "--- \nname: A\ndescription: D\n--- \n\nBody\n"),
            ("CRLF throughout", "---\r\nname: A\r\ndescription: D\r\n---\r\n\r\nBody\r\n"),
            ("comment between keys", "---\nname: A\n# describes the next key\ndescription: D\n---\n\nBody\n"),
            (
                "nested mapping with list",
                "---\nname: A\ndescription: D\nmetadata:\n  tools:\n    - Read\n    - Write\n---\n\nBody\n"
            )
        ]

        for (label, original) in fixtures {
            let isBodyOnly = label == "leading blank line"
            if isBodyOnly {
                XCTAssertNil(SkillParser.parse(original).preservedFile)
                XCTAssertEqual(SkillParser.stripFrontmatter(original), SkillParser.canonicalBody(original))
            }
            let expected = isBodyOnly
                ? SkillSerializer.serialize(name: "Ignored", description: "Ignored", body: "Changed") + "\n"
                : original.replacingOccurrences(of: "Body", with: "Changed")
            var current = original
            for save in 1...3 {
                let parsed = SkillParser.parse(current)
                current = SkillSerializer.rewrite(
                    body: "Changed",
                    preserving: parsed,
                    fallbackName: "Ignored",
                    fallbackDescription: "Ignored"
                )
                XCTAssertEqual(current, expected, "\(label), save \(save)")
            }
        }
    }
}
