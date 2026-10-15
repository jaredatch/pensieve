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
        for trigger in ["deploying", "installing", "removing", "skills", "Claude Code", "Grok", "Cursor",
                        "Codex", "OpenClaw", "Hermes", "projects", "another Mac"] {
            XCTAssertTrue(description.contains(trigger), "Missing discovery trigger: \(trigger)")
        }

        // These are the shipped prompt's policy clauses, not a CLI inventory. Removing a clause
        // must fail even when the same flag still appears in an example or another rule.
        let body = parsed.body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let rules = [
            "Start with `pensieve commands --json`; use `pensieve <command> --help --json`",
            "Always pass `--json`. Read `ok`, `changed`, `error.code` and the exit code.",
            "Look names up before using them with `skill list`, `agent list`, `machine list` and `project list`",
            "Never guess a name or choose between ambiguous matches.",
            "Never write into `~/.claude/skills` or any other agent's folder directly.",
            "Run `--dry-run` before a broad change. Use `-a '*'` only when the person says \"all\".",
            "Before `install`, `skill update`, `skill delete` or `project remove`, show the person the dry run "
                + "and ask for approval. Pass `--yes` only after they agree.",
            "Keep that preview's `confirmationToken` in `--confirm-plan` when applying it.",
            "Retry only when `error.retryable` is true.",
            "Report what changed.",
            "it lands on that Mac's next sync after this Mac pushes.",
            "If `pensieve` isn't on the PATH, use the absolute path inside the intended app:",
            "`/Applications/Pensieve.app/Contents/Helpers/pensieve`"
        ]
        for rule in rules {
            XCTAssertTrue(body.contains(rule), "Missing skill policy: \(rule)")
        }
    }

    func testBuiltAppContainsTheDistributableSkillAndEvals() throws {
        let resources = try XCTUnwrap(Bundle.main.resourceURL)
        let bundled = resources.appendingPathComponent("skills/pensieve")
        let files = FileService()
        for name in ["SKILL.md", "evals.json"] {
            let path = bundled.appendingPathComponent(name).path
            XCTAssertTrue(files.fileExists(at: path), "Built app is missing skills/pensieve/\(name)")
            XCTAssertEqual(try files.readData(at: path),
                           try files.readData(at: skillDirectory.appendingPathComponent(name).path),
                           "Bundled \(name) must match the distributed skill")
        }
    }
}
