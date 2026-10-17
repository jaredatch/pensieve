import CryptoKit
import XCTest
@testable import Pensieve

final class PensieveSkillTests: XCTestCase {
    private var skillDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("skills/pensieve")
    }

    func testSkillIsAdmissibleAndCarriesDiscoveryTriggersAndSafetyRules() throws {
        let text = try FileService().readFile(at: skillDirectory.appendingPathComponent("SKILL.md").path)
        let parsed = SkillParser.parse(text)
        XCTAssertTrue(parsed.hasRequiredFrontmatter)
        XCTAssertEqual(parsed.name, "pensieve")
        let description = try XCTUnwrap(parsed.description)
        for trigger in ["deploying", "installing", "updating", "removing", "skills", "Claude Code", "Grok", "Cursor",
                        "Codex", "OpenClaw", "Hermes", "projects", "another Mac"] {
            XCTAssertTrue(description.contains(trigger), "Missing discovery trigger: \(trigger)")
        }

        // Short policy phrases allow surrounding prose to change. A manual eval owns
        // meaning; this guard catches a dropped rule without pinning whole sentences.
        let body = parsed.body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let rules = [
            "For a known command", "`pensieve <command> --help --json`",
            "`pensieve commands --json` only to find an unfamiliar command",
            "Always pass `--json`", "Look names up", "Never guess",
            "Never write into `~/.claude/skills`", "or any other agent's folder",
            "or choose between ambiguous matches", "`ok`, `changed`, `error.code` and the exit code",
            "Before `install`, `skill update`, `skill delete` or `project remove`",
            "`--dry-run` before a broad change", "`-a '*'` only when the person says \"all\"",
            "names skills to install from a repository", "each as `--skill <slug>` in both the dry run and the apply",
            "ask for approval", "`--yes` only after they agree",
            "`confirmationToken` in `--confirm-plan`",
            "Retry only when `error.retryable` is true", "Report what changed",
            "`partial` result", "`changed: false`", "`next` suggestions",
            "next sync after this Mac pushes", "absolute path inside the intended app",
            "`/Applications/Pensieve.app/Contents/Helpers/pensieve`"
        ]
        for rule in rules {
            XCTAssertTrue(body.contains(rule), "Missing skill policy: \(rule)")
        }
    }

    func testBuiltAppContainsOnlyTheDistributableSkill() throws {
        let resources = try XCTUnwrap(Bundle.main.resourceURL)
        let bundled = resources.appendingPathComponent("pensieve")
        let files = FileService()
        let path = bundled.appendingPathComponent("SKILL.md").path
        XCTAssertTrue(files.fileExists(at: path), "Built app is missing pensieve/SKILL.md")
        XCTAssertEqual(try files.listDirectory(at: bundled.path).sorted(), ["SKILL.md"],
                       "Bundled skill folder must contain only SKILL.md")
        let text = try files.readFile(at: path)
        let lines = text.components(separatedBy: "\n")
        let markers = lines.filter { $0.hasPrefix("pensieve-bundled: ") }
        XCTAssertTrue(BundledSkillContent.isUnedited(Data(text.utf8)), "Shipped bytes must be recognized as unedited")
        XCTAssertEqual(BundledSkillContent.version(Data(text.utf8)), markers.first.map { String($0.dropFirst(18)) },
                       "The marker must be in front matter where version reads it")
        XCTAssertEqual(markers.count, 1, "The shipped skill must carry one version marker")
        let content = lines.filter { !$0.hasPrefix("pensieve-bundled: ") }.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(markers.first, "pensieve-bundled: " + digest,
                       "The shipped marker must match the document so unedited copies can update")
        XCTAssertEqual(try files.readData(at: path),
                       try files.readData(at: skillDirectory.appendingPathComponent("SKILL.md").path),
                       "Bundled SKILL.md must match the distributed skill")
    }
}
