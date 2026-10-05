import XCTest
@testable import Pensieve

/// PLAN-12 / 12.9 — direct tests for `DeployReconciler.reconcileCursor(manifest:)` and the full
/// `reconcile(root:)` orchestration over a hermetic temp HOME with the real `FileService`. Injected roots
/// keep it off the developer's actual `~/.cursor/rules` / store; `agentSkillDirs: []` neutralizes the
/// prune half so these tests isolate the Cursor reconcile.
final class DeployReconcilerCursorTests: XCTestCase {
    private var tempDir: String!
    private var storeSkillsDir: String!
    private var cursorRulesDir: String!
    private var deployStateStore: DeployStateStore!
    private let fileService = FileService()

    private func makeReconciler() -> DeployReconciler {
        DeployReconciler(
            fileService: fileService,
            deployState: deployStateStore,
            pensieveSkillsDir: storeSkillsDir,
            agentSkillDirs: [],
            cursorRulesDir: cursorRulesDir,
            manifestService: ManifestService()
        )
    }

    override func setUpWithError() throws {
        tempDir = TestTemporaryDirectory.path + "PensieveDeployReconcilerCursorTests-\(UUID().uuidString)"
        storeSkillsDir = tempDir + "/store/skills"
        cursorRulesDir = tempDir + "/cursor/rules"
        deployStateStore = DeployStateStore(fileService: fileService, appSupportDir: tempDir + "/app-support")
        try FileManager.default.createDirectory(atPath: storeSkillsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: cursorRulesDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: tempDir)
    }

    /// Writes `skills/<slug>/SKILL.md` with a `name`/`description` frontmatter + body. Returns the body.
    @discardableResult
    private func makeStoreSkill(_ slug: String, description: String, body: String) throws -> String {
        let dir = storeSkillsDir + "/" + slug
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let content = "---\nname: \(slug)\ndescription: \(description)\n---\n\n\(body)\n"
        try content.write(toFile: dir + "/SKILL.md", atomically: true, encoding: .utf8)
        return content
    }

    private func overlay(slug: String, cursor: CursorAdapterConfig?) -> SkillOverlay {
        SkillOverlay(slug: slug, createdAt: Date(timeIntervalSince1970: 0), scope: .user,
                     tags: [], cursor: cursor, agents: [], origin: .authored)
    }

    private func snapshot(_ overlays: [SkillOverlay]) -> ManifestSnapshot {
        ManifestSnapshot(schemaVersion: 1, categories: [], projects: [], skills: overlays)
    }

    private func record(slug: String, artifactPath: String) -> DeployStateRecord {
        DeployStateRecord(
            slug: slug,
            platform: PlatformTarget.cursor.rawValue,
            scope: "user",
            projectIdentityKey: nil,
            artifactPath: artifactPath,
            recordedAt: "2026-07-17T00:00:00Z"
        )
    }

    private func seedRecords(_ records: [DeployStateRecord]) throws {
        try deployStateStore.replaceAll(records)
    }

    /// (a) An upstream body change regenerates the `.mdc` to match `CursorMDC.generate`.
    func testStaleMdcRegenerated() throws {
        let raw = try makeStoreSkill("foo", description: "Foo desc", body: "NEW BODY")
        let mdcPath = cursorRulesDir + "/foo.mdc"
        try "STALE".write(toFile: mdcPath, atomically: true, encoding: .utf8)
        try seedRecords([record(slug: "foo", artifactPath: mdcPath)])
        let result = makeReconciler().reconcileCursor(manifest: snapshot([overlay(slug: "foo", cursor: nil)]))
        let expected = CursorMDC.generate(directoryName: "foo", description: "Foo desc",
                                          cursorConfig: nil, body: SkillParser.stripFrontmatter(raw))
        XCTAssertEqual(try String(contentsOfFile: mdcPath, encoding: .utf8), expected)
        XCTAssertEqual(result.recompiled, [mdcPath])
    }

    /// (b) When the Cursor overlay's description is nil, the regenerated `.mdc` uses the SKILL.md
    ///     frontmatter description.
    func testDescriptionFallsBackToFrontmatter() throws {
        try makeStoreSkill("bar", description: "Frontmatter Desc", body: "body")
        let mdcPath = cursorRulesDir + "/bar.mdc"
        try "STALE".write(toFile: mdcPath, atomically: true, encoding: .utf8)
        try seedRecords([record(slug: "bar", artifactPath: mdcPath)])
        let cursor = CursorAdapterConfig(description: nil, globs: nil, alwaysApply: false)
        _ = makeReconciler().reconcileCursor(manifest: snapshot([overlay(slug: "bar", cursor: cursor)]))
        let content = try String(contentsOfFile: mdcPath, encoding: .utf8)
        XCTAssertTrue(content.contains("description: Frontmatter Desc"), "expected frontmatter description, got:\n\(content)")
    }

    /// (c) A `.mdc` whose slug matches a canonical Pensieve skill but has no deploy-state record is left
    ///     byte-identical — slug inference no longer claims ownership.
    func testUnrecordedCollisionMdcUntouched() throws {
        try makeStoreSkill("foo", description: "Foo desc", body: "canonical body")
        let mdcPath = cursorRulesDir + "/foo.mdc"
        try "USER COLLISION\n".write(toFile: mdcPath, atomically: true, encoding: .utf8)
        let result = makeReconciler().reconcileCursor(manifest: snapshot([overlay(slug: "foo", cursor: nil)]))
        XCTAssertEqual(try String(contentsOfFile: mdcPath, encoding: .utf8), "USER COLLISION\n")
        XCTAssertEqual(result.recompiled, [])
    }

    /// (d) A `.mdc` whose slug has NO canonical Pensieve skill (e.g. the user's own hand-written rule) is
    ///     LEFT UNTOUCHED — never deleted.
    func testNonPensieveMdcUntouched() throws {
        let mdcPath = cursorRulesDir + "/user-rule.mdc"   // no canonical skill "user-rule"
        try "USER CONTENT".write(toFile: mdcPath, atomically: true, encoding: .utf8)
        let result = makeReconciler().reconcileCursor(manifest: snapshot([]))
        XCTAssertTrue(fileService.fileExists(at: mdcPath), "a non-Pensieve rule must not be deleted")
        XCTAssertEqual(try String(contentsOfFile: mdcPath, encoding: .utf8), "USER CONTENT")
        XCTAssertEqual(result.recompiled, [])
    }

    /// (e) An unchanged recorded rule is a no-op on the second run (idempotent — zero files touched).
    func testIdempotentSecondRunTouchesNothing() throws {
        try makeStoreSkill("baz", description: "Baz", body: "body")
        let mdcPath = cursorRulesDir + "/baz.mdc"
        try "STALE".write(toFile: mdcPath, atomically: true, encoding: .utf8)
        try seedRecords([record(slug: "baz", artifactPath: mdcPath)])
        let manifest = snapshot([overlay(slug: "baz", cursor: nil)])
        let first = makeReconciler().reconcileCursor(manifest: manifest)
        XCTAssertEqual(first.recompiled, [mdcPath])
        let second = makeReconciler().reconcileCursor(manifest: manifest)
        XCTAssertEqual(second.recompiled, [])
    }

    /// (f) Missing/corrupt/newer deploy state makes `reconcileCursor` regenerate nothing (fail-safe).
    func testUnreadableOrMissingDeployStateRegeneratesNothing() throws {
        try makeStoreSkill("owned", description: "Owned", body: "body")
        let mdcPath = cursorRulesDir + "/owned.mdc"
        try "STALE".write(toFile: mdcPath, atomically: true, encoding: .utf8)
        let manifest = snapshot([overlay(slug: "owned", cursor: nil)])

        XCTAssertEqual(makeReconciler().reconcileCursor(manifest: manifest).recompiled, [])
        XCTAssertEqual(try String(contentsOfFile: mdcPath, encoding: .utf8), "STALE")

        try fileService.writeFile(at: tempDir + "/app-support/deploy-state.json", content: "not json")
        XCTAssertEqual(makeReconciler().reconcileCursor(manifest: manifest).recompiled, [])
        XCTAssertEqual(try String(contentsOfFile: mdcPath, encoding: .utf8), "STALE")

        try fileService.writeFile(
            at: tempDir + "/app-support/deploy-state.json",
            content: #"{"records":[],"schema_version":2}"#
        )
        XCTAssertEqual(makeReconciler().reconcileCursor(manifest: manifest).recompiled, [])
        XCTAssertEqual(try String(contentsOfFile: mdcPath, encoding: .utf8), "STALE")
    }

    /// (g) A recorded rule whose canonical `SKILL.md` leaf is unsafe is skipped, not read through.
    func testRecordedUnsafeLeafSkipped() throws {
        let dir = storeSkillsDir + "/unsafe"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let outside = tempDir + "/outside.md"
        try "outside".write(toFile: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: dir + "/SKILL.md", withDestinationPath: outside)
        let mdcPath = cursorRulesDir + "/unsafe.mdc"
        try "STALE".write(toFile: mdcPath, atomically: true, encoding: .utf8)
        try seedRecords([record(slug: "unsafe", artifactPath: mdcPath)])

        let result = makeReconciler().reconcileCursor(manifest: snapshot([overlay(slug: "unsafe", cursor: nil)]))

        XCTAssertEqual(result.recompiled, [])
        XCTAssertEqual(try String(contentsOfFile: mdcPath, encoding: .utf8), "STALE")
    }

    /// (h) A corrupt manifest makes `reconcile(root:)` skip the Cursor reconcile entirely (fail-safe) —
    ///     no `.mdc` is touched.
    func testCorruptManifestTouchesNoMdc() throws {
        let root = tempDir + "/store"
        try FileManager.default.createDirectory(atPath: root + "/manifest", withIntermediateDirectories: true)
        try "not-a-mapping".write(toFile: root + "/manifest/manifest.yaml", atomically: true, encoding: .utf8)
        let mdcPath = cursorRulesDir + "/keep.mdc"
        try makeStoreSkill("keep", description: "Keep", body: "body")
        try "ORIGINAL".write(toFile: mdcPath, atomically: true, encoding: .utf8)
        try seedRecords([record(slug: "keep", artifactPath: mdcPath)])
        let outcome = try makeReconciler().reconcile(root: root)
        XCTAssertEqual(outcome.recompiledRules, 0)
        XCTAssertEqual(try String(contentsOfFile: mdcPath, encoding: .utf8), "ORIGINAL")
    }

    /// (i) reconcile(root:) end-to-end: with a readable (empty) manifest it drives the Cursor reconcile
    ///     and regenerates a stale rule.
    func testReconcileRootDrivesCursor() throws {
        let root = tempDir + "/store2"
        try FileManager.default.createDirectory(atPath: root + "/manifest", withIntermediateDirectories: true)
        try "schema_version: 1".write(toFile: root + "/manifest/manifest.yaml", atomically: true, encoding: .utf8)
        try makeStoreSkill("qux", description: "Qux", body: "body")
        let mdcPath = cursorRulesDir + "/qux.mdc"
        try "STALE".write(toFile: mdcPath, atomically: true, encoding: .utf8)
        try seedRecords([record(slug: "qux", artifactPath: mdcPath)])
        let outcome = try makeReconciler().reconcile(root: root)
        XCTAssertEqual(outcome.recompiledRules, 1)
    }
}
