import XCTest
@testable import Pensieve

/// The Content tab's choices (PLAN-34 / 34.2): SKILL.md first, the text files by path, markdown alone renders.
final class SkillContentPresentationTests: XCTestCase {
    private func inventory(_ files: [(String, Int?)]) -> SkillBundleInventory {
        var inventory = SkillBundleInventory()
        inventory.files = files.map { SkillBundleInventory.File(relativePath: $0.0, bytes: 1, tokens: $0.1) }
        return inventory
    }

    func testChoicesPutSkillFileFirstThenTextFilesByPath() {
        let choices = SkillContentPresentation.choices(inventory: inventory([
            ("scripts/x.sh", 3), ("references/a.md", 5), ("img.png", nil), ("SKILL.md", 9)
        ]))

        XCTAssertEqual(choices.map(\.relativePath), ["SKILL.md", "references/a.md", "scripts/x.sh"])
        XCTAssertTrue(choices[0].isSkillFile)
        XCTAssertFalse(choices[1].isSkillFile)
    }

    func testOnlyMarkdownRenders() {
        XCTAssertTrue(SkillContentPresentation.FileChoice(relativePath: "references/a.md").canRender)
        XCTAssertTrue(SkillContentPresentation.FileChoice(relativePath: "NOTES.MARKDOWN").canRender)
        XCTAssertFalse(SkillContentPresentation.FileChoice(relativePath: "scripts/x.sh").canRender)
        XCTAssertFalse(SkillContentPresentation.FileChoice(relativePath: "data.json").canRender)
    }

    func testShownModeFallsToSourceForANonMarkdownFile() {
        let script = SkillContentPresentation.FileChoice(relativePath: "scripts/x.sh")
        let markdown = SkillContentPresentation.FileChoice(relativePath: "SKILL.md")

        XCTAssertEqual(SkillContentPresentation.shownMode(.rendered, for: script), .source)
        XCTAssertEqual(SkillContentPresentation.shownMode(.source, for: script), .source)
        XCTAssertEqual(SkillContentPresentation.shownMode(.rendered, for: markdown), .rendered)
        XCTAssertEqual(SkillContentPresentation.shownMode(.source, for: markdown), .source)

        let resolvedScript = SkillContentPresentation.resolve(
            selectedFile: "scripts/x.sh",
            requestedMode: .rendered,
            inventory: inventory([("SKILL.md", 9), ("scripts/x.sh", 3)])
        )
        let resolvedMarkdown = SkillContentPresentation.resolve(
            selectedFile: "SKILL.md",
            requestedMode: .rendered,
            inventory: inventory([("SKILL.md", 9)])
        )
        XCTAssertTrue(resolvedScript.ownsScroller)
        XCTAssertFalse(resolvedMarkdown.ownsScroller)
    }

    func testAMissingSelectionResolvesToTheSkillFile() {
        let choices = [SkillContentPresentation.FileChoice(relativePath: "SKILL.md"),
                       SkillContentPresentation.FileChoice(relativePath: "references/a.md")]

        XCTAssertEqual(SkillContentPresentation.resolvedFile("references/x.md", in: choices), "SKILL.md")
        XCTAssertEqual(SkillContentPresentation.resolvedFile("references/a.md", in: choices), "references/a.md")
        XCTAssertEqual(SkillContentPresentation.resolvedFile("SKILL.md", in: choices), "SKILL.md")
    }

    func testBundleFileTextStaysVisibleOnlyForTheSameSkillAndFile() {
        let skillID = UUID()
        let cached = SkillContentFileText(skillID: skillID, relativePath: "scripts/x.sh", text: "echo hi")

        XCTAssertEqual(cached.text(for: skillID, relativePath: "scripts/x.sh"), "echo hi")
        XCTAssertNil(cached.text(for: skillID, relativePath: "references/a.md"))
        XCTAssertNil(cached.text(for: UUID(), relativePath: "scripts/x.sh"))
    }

}
