import XCTest
@testable import Pensieve

/// PLAN-12 / 12.8 — direct tests for `DeployReconciler.pruneDangling()` over a hermetic temp HOME with
/// the real `FileService`, so symlink/realpath behavior is real. The reconciler's path roots are injected
/// so nothing touches the developer's actual agent dirs.
final class DeployReconcilerPruneTests: XCTestCase {
    private var tempDir: String!
    private var storeSkillsDir: String!    // stands in for pensieveSkillsDir
    private var agentDir: String!          // stands in for one user-wide agent skill dir
    private var deployStateStore: DeployStateStore!
    private let fileService = FileService()

    private func makeReconciler(agentDirs: [String]? = nil) -> DeployReconciler {
        DeployReconciler(
            fileService: fileService,
            deployState: deployStateStore,
            pensieveSkillsDir: storeSkillsDir,
            agentSkillDirs: agentDirs ?? [agentDir]
        )
    }

    override func setUpWithError() throws {
        tempDir = NSTemporaryDirectory() + "PensieveDeployReconcilerPruneTests-\(UUID().uuidString)"
        storeSkillsDir = tempDir + "/store/skills"
        agentDir = tempDir + "/agent/skills"
        deployStateStore = DeployStateStore(fileService: fileService, appSupportDir: tempDir + "/app-support")
        try FileManager.default.createDirectory(atPath: storeSkillsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: agentDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: tempDir)
    }

    private func makeStoreSkill(_ slug: String) throws {
        let dir = storeSkillsDir + "/" + slug
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir + "/SKILL.md", contents: Data("body".utf8))
    }

    private func link(_ name: String, to target: String) throws {
        try FileManager.default.createSymbolicLink(atPath: agentDir + "/" + name, withDestinationPath: target)
    }

    private func record(slug: String, artifactPath: String) -> DeployStateRecord {
        DeployStateRecord(
            slug: slug,
            platform: PlatformTarget.claudeCode.rawValue,
            scope: "user",
            projectIdentityKey: nil,
            artifactPath: artifactPath,
            recordedAt: "2026-07-17T00:00:00Z"
        )
    }

    /// (a) A Pensieve symlink whose canonical store dir has vanished is removed.
    func testDanglingPensieveLinkRemoved() throws {
        try link("gone", to: storeSkillsDir + "/gone")   // target never created → dangling
        let result = makeReconciler().pruneDangling()
        XCTAssertEqual(result.removed, [agentDir + "/gone"])
        XCTAssertFalse(fileService.isSymlink(at: agentDir + "/gone"))
    }

    /// (b) A Pensieve symlink whose canonical store dir still exists survives.
    func testLivePensieveLinkSurvives() throws {
        try makeStoreSkill("live")
        try link("live", to: storeSkillsDir + "/live")
        let result = makeReconciler().pruneDangling()
        XCTAssertEqual(result.removed, [])
        XCTAssertTrue(fileService.isSymlink(at: agentDir + "/live"))
    }

    /// (c) A FOREIGN symlink (target outside the store) is never touched — even when dangling. This is
    ///     the mutation-probe case: dropping the target-under-store guard removes it.
    func testForeignSymlinkSurvives() throws {
        try link("foreignlink", to: tempDir + "/outside-foreign")   // outside the store, dangling
        let result = makeReconciler().pruneDangling()
        XCTAssertEqual(result.removed, [])
        XCTAssertTrue(fileService.isSymlink(at: agentDir + "/foreignlink"))
    }

    /// (c2) A RELATIVE symlink is never touched (only absolute in-store targets are Pensieve-owned).
    func testRelativeSymlinkSurvives() throws {
        try link("rellink", to: "../../outside")   // relative → not under the absolute store prefix
        let result = makeReconciler().pruneDangling()
        XCTAssertEqual(result.removed, [])
        XCTAssertTrue(fileService.isSymlink(at: agentDir + "/rellink"))
    }

    /// (d) A regular file (not a symlink) in the agent dir is untouched.
    func testRegularFileUntouched() throws {
        FileManager.default.createFile(atPath: agentDir + "/notalink", contents: Data("x".utf8))
        let result = makeReconciler().pruneDangling()
        XCTAssertEqual(result.removed, [])
        XCTAssertTrue(fileService.fileExists(at: agentDir + "/notalink"))
    }

    /// (e) A SYMLINKED agent-dir parent is skipped entirely — its (dangling) inner link is never pruned.
    func testSymlinkedAgentDirSkipped() throws {
        let realTarget = tempDir + "/redirected"
        try FileManager.default.createDirectory(atPath: realTarget, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: realTarget + "/gone", withDestinationPath: storeSkillsDir + "/gone")
        let symlinkedAgentDir = tempDir + "/agent-symlinked"
        try FileManager.default.createSymbolicLink(atPath: symlinkedAgentDir, withDestinationPath: realTarget)
        let result = makeReconciler(agentDirs: [symlinkedAgentDir]).pruneDangling()
        XCTAssertEqual(result.skippedDirs, [symlinkedAgentDir])
        XCTAssertEqual(result.removed, [])
        XCTAssertTrue(fileService.isSymlink(at: realTarget + "/gone"))
    }

    /// (f) reconcile(root:) wraps pruneDangling and reports the pruned count.
    func testReconcileReportsPrunedCount() throws {
        try link("gone", to: storeSkillsDir + "/gone")
        let outcome = try makeReconciler().reconcile(root: tempDir + "/store")
        XCTAssertEqual(outcome.prunedLinks, 1)
    }

    /// (P2, Layer-2) A target that uses `..` to escape the store is NOT treated as owned — the
    /// containment check standardizes the path first, so a `<store>/../outside` string prefix can't fool
    /// it. Reddens on the pre-fix raw `hasPrefix`: the escaper resolves to a dangling out-of-store path
    /// and would be removed.
    func testDotDotEscapingTargetSurvives() throws {
        try link("escaper", to: storeSkillsDir + "/../escaped-out")   // resolves outside the store, dangling
        let result = makeReconciler().pruneDangling()
        XCTAssertEqual(result.removed, [])
        XCTAssertTrue(fileService.isSymlink(at: agentDir + "/escaper"))
    }

    /// (P3, Layer-2) A delete that fails is never counted as pruned — the count feeds the status file
    /// PLAN-14 reads. A read-only agent dir makes the unlink fail; the dangling link stays and is not in
    /// `removed`. Reddens on the pre-fix `try?`-then-always-append shape.
    func testFailedDeleteNotCounted() throws {
        try link("gone", to: storeSkillsDir + "/gone")   // dangling → would be pruned if the delete worked
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: agentDir)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: agentDir) }
        let result = makeReconciler().pruneDangling()
        XCTAssertEqual(result.removed, [])
        XCTAssertTrue(fileService.isSymlink(at: agentDir + "/gone"))
    }

    /// (P2c, Layer-2 round 3) A target that only *lexically* looks in-store — `<store>/alias/../out`,
    /// where `<store>/alias` is a symlink OUT of the store — must NOT be treated as owned. The
    /// exact-match ownership test rejects it; a prefix/`standardized` check would be fooled because
    /// lexical `..` collapse precedes symlink resolution. Reddens if ownership is relaxed to a prefix
    /// check (the link is then treated as owned + dangling and removed).
    func testIntermediateSymlinkTargetSurvives() throws {
        let outside = tempDir + "/outside-real"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: storeSkillsDir + "/alias", withDestinationPath: outside)
        try link("tricky", to: storeSkillsDir + "/alias/../outside-real/ghost")
        let result = makeReconciler().pruneDangling()
        XCTAssertEqual(result.removed, [])
        XCTAssertTrue(fileService.isSymlink(at: agentDir + "/tricky"))
    }

    /// (16.3) A successfully pruned Pensieve symlink removes its deploy-state record.
    func testPrunedLinkRecordRemoved() throws {
        let linkPath = agentDir + "/gone"
        try link("gone", to: storeSkillsDir + "/gone")
        try deployStateStore.replaceAll([
            record(slug: "gone", artifactPath: linkPath),
            record(slug: "other", artifactPath: agentDir + "/other")
        ])

        let result = makeReconciler().pruneDangling()

        XCTAssertEqual(result.removed, [linkPath])
        XCTAssertEqual(try deployStateStore.read().records.map(\.artifactPath), [agentDir + "/other"])
    }

    /// (16.3) A deploy-state write failure is tolerated: prune deletes the dangling link anyway.
    func testRecordRemovalFailureDoesNotBlockPrune() throws {
        let linkPath = agentDir + "/gone"
        try link("gone", to: storeSkillsDir + "/gone")
        try fileService.writeFile(
            at: tempDir + "/app-support/deploy-state.json",
            content: #"{"records":[],"schema_version":2}"#
        )

        let result = makeReconciler().pruneDangling()

        XCTAssertEqual(result.removed, [linkPath])
        XCTAssertFalse(fileService.isSymlink(at: linkPath))
    }

    /// (16.3 Layer-1) Prune must not create a deploy-state artifact on a machine that has none yet.
    func testPruneWithMissingDeployStateDoesNotCreateArtifact() throws {
        let linkPath = agentDir + "/gone"
        let statePath = tempDir + "/app-support/deploy-state.json"
        try link("gone", to: storeSkillsDir + "/gone")

        let result = makeReconciler().pruneDangling()

        XCTAssertEqual(result.removed, [linkPath])
        XCTAssertFalse(fileService.isSymlink(at: linkPath))
        XCTAssertFalse(fileService.fileExists(at: statePath))
    }
}
