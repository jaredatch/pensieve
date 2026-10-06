import XCTest
@testable import Pensieve

final class WebLinkPolicyTests: XCTestCase {
    func testEditorNavigationPopupAndPreviewAgreeOnExternalURLs() throws {
        let cases = [
            ("http://example.com", true), ("HTTPS://example.com", true),
            ("file:///tmp/skill.md", false), ("mailto:a@example.com", false),
            ("javascript:alert(1)", false), ("pensieve:action", false), ("references/x.md", false)
        ]
        for (link, expected) in cases {
            let url = try XCTUnwrap(URL(string: link))
            let navigation = EditorNavigationPolicy.decision(for: url, navigationType: .linkActivated,
                                                             scheme: "pensieve-editor")
            let popup = EditorNavigationPolicy.popupDecision(for: url)
            let preview = SkillPreviewLinkPolicy.decision(for: url, documentRelativePath: "SKILL.md",
                                                           files: ["SKILL.md", "references/x.md"])
            XCTAssertEqual([navigation == .openExternally, popup == .openExternally, preview == .openWeb],
                           [expected, expected, expected], "navigation, popup, preview: \(link)")
        }
    }
}
