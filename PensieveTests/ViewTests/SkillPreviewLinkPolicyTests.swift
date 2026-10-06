import XCTest
@testable import Pensieve

final class SkillPreviewLinkPolicyTests: XCTestCase {
    private struct RouteCase {
        let link: String
        let document: String
        let expected: SkillPreviewLinkPolicy.Decision
    }

    func testRoutesWebAnchorsAndAdmittedRelativeFiles() throws {
        let cases: [RouteCase] = [
            .init(link: "https://example.com", document: "SKILL.md", expected: .openWeb),
            .init(link: "HTTP://example.com", document: "SKILL.md", expected: .openWeb),
            .init(link: "HTTPS://example.com", document: "SKILL.md", expected: .openWeb),
            .init(link: "#authoring-gate", document: "SKILL.md", expected: .scrollTo("authoring-gate")),
            .init(link: "#caf%C3%A9", document: "SKILL.md", expected: .scrollTo("café")),
            .init(link: "SKILL.md#authoring-gate", document: "SKILL.md", expected: .scrollTo("authoring-gate")),
            .init(link: "./SKILL.md#x", document: "SKILL.md", expected: .scrollTo("x")),
            .init(link: "./guide.md#part", document: "references/guide.md", expected: .scrollTo("part")),
            .init(link: "CAMPAIGN.md", document: "SKILL.md", expected: .selectFile("CAMPAIGN.md")),
            .init(link: "./references/x.md", document: "SKILL.md", expected: .selectFile("references/x.md")),
            .init(link: "references/x.md#part", document: "SKILL.md", expected: .selectFile("references/x.md")),
            .init(link: "x.md#part", document: "references/guide.md", expected: .selectFile("references/x.md")),
            .init(link: "../CAMPAIGN.md", document: "references/guide.md", expected: .selectFile("CAMPAIGN.md")),
            .init(link: "./sub/../x.md", document: "references/guide.md", expected: .selectFile("references/x.md")),
            .init(link: "references/a%20b.md", document: "SKILL.md", expected: .selectFile("references/a b.md")),
            .init(link: "references%2Fx.md", document: "SKILL.md", expected: .selectFile("references/x.md"))
        ]
        let files = ["SKILL.md", "CAMPAIGN.md", "references/x.md", "references/a b.md"]
        for entry in cases {
            let url = try XCTUnwrap(URL(string: entry.link))
            XCTAssertEqual(SkillPreviewLinkPolicy.decision(for: url, documentRelativePath: entry.document, files: files),
                           entry.expected, entry.link)
        }
    }

    func testIgnoresSchemesAbsolutePathsEscapesAndFilesOutsidePicker() throws {
        let files = ["SKILL.md", "references/x.md"]
        let blocked = ["file:///tmp/x.md", "FILE:///tmp/x.md", "mailto:a@example.com", "javascript:alert(1)",
                       "pensieve:action", "/references/x.md", "//example.com/x.md", "../SKILL.md",
                       "%2E%2E/SKILL.md", "references/../../SKILL.md", "%2Freferences/x.md",
                       "references/%00x.md", "references/x.md?download=1", "unlisted.md", "#"]
        for link in blocked {
            let url = try XCTUnwrap(URL(string: link))
            XCTAssertEqual(SkillPreviewLinkPolicy.decision(for: url, documentRelativePath: "SKILL.md", files: files),
                           .ignore, link)
        }
        XCTAssertEqual(SkillPreviewLinkPolicy.decision(for: try XCTUnwrap(URL(string: "../../SKILL.md")),
                                                      documentRelativePath: "references/guide.md", files: files), .ignore)
    }

    func testAnExistingFileOutsidePickerAndAPreviewWithoutPickerCannotSelectFiles() throws {
        let files = FileService()
        let root = NSTemporaryDirectory() + "PreviewLinks-" + UUID().uuidString
        defer { try? files.deleteDirectory(at: root) }
        try files.writeFile(at: root + "/unlisted.md", content: "Exists, but is not admitted by the picker")
        XCTAssertTrue(files.fileExists(at: root + "/unlisted.md"))
        XCTAssertEqual(SkillPreviewLinkPolicy.decision(for: try XCTUnwrap(URL(string: "unlisted.md")),
                                                      documentRelativePath: "SKILL.md", files: ["SKILL.md"]), .ignore)
        XCTAssertEqual(SkillPreviewLinkPolicy.decision(for: try XCTUnwrap(URL(string: "SKILL.md")),
                                                      documentRelativePath: "SKILL.md", files: []), .ignore)
        XCTAssertEqual(SkillPreviewLinkPolicy.decision(for: try XCTUnwrap(URL(string: "https://example.com")),
                                                      documentRelativePath: "SKILL.md", files: []), .openWeb)
        XCTAssertEqual(SkillPreviewLinkPolicy.decision(for: try XCTUnwrap(URL(string: "#section")),
                                                      documentRelativePath: "SKILL.md", files: []), .scrollTo("section"))
    }

    func testHeadingSlugsFollowGitHubRules() {
        let cases = [("Authoring gate", "authoring-gate"), ("Hello, World! (v2.0)", "hello-world-v20"),
                     ("A  repeated   space", "a--repeated---space"),
                     ("Keep-hyphens_and_underscores", "keep-hyphens_and_underscores"),
                     ("Café 中文 Über", "café-中文-über"), ("Cafe\u{301}", "cafe\u{301}"),
                     ("Ship 🚀 now 🎉", "ship--now-"), ("☀️ 👩‍💻 😀", "--")]
        for (heading, expected) in cases {
            XCTAssertEqual(SkillPreviewLinkPolicy.slug(heading), expected, heading)
        }
    }

    func testDuplicateSlugUsesFirstHeadingAndMissingAnchorHasNoTarget() throws {
        let first = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let second = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let third = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000003"))
        let targets: [SkillPreviewLinkPolicy.HeadingTarget] = [
            .init(id: third, slug: "authoring-gate", position: 900),
            .init(id: second, slug: "authoring-gate", position: 600),
            .init(id: UUID(), slug: "other", position: 0),
            .init(id: first, slug: "authoring-gate", position: 100)
        ]
        XCTAssertEqual(SkillPreviewLinkPolicy.firstHeading(for: "authoring-gate", in: targets), first)
        XCTAssertEqual(SkillPreviewLinkPolicy.firstHeading(for: "Authoring-Gate", in: targets), first)
        XCTAssertEqual(SkillPreviewLinkPolicy.firstHeading(for: "authoring-gate-1", in: targets), second)
        XCTAssertEqual(SkillPreviewLinkPolicy.firstHeading(for: "AUTHORING-GATE-2", in: targets), third)
        XCTAssertNil(SkillPreviewLinkPolicy.firstHeading(for: "missing", in: targets))
    }
}
