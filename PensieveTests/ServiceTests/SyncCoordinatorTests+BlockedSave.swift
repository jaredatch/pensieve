import SwiftData
import XCTest
@testable import Pensieve

@MainActor
extension SyncCoordinatorTests {
    func testSaveDuringBlockedGitSurvivesAndNextCycleCommitsIt() async throws {
        let harness = try makeRemoteHarness()
        let block = try blockingPush(repository: harness.clone)
        defer { block.release(); try? block.cleanup() }
        let git = harness.allowlistedGit
        let paths = AppRuntimePaths(storeRoot: harness.clone, appSupportDir: block.root + "/support")
        let library = SkillLibraryViewModel(
            skillStore: SkillStore(fileService: block.files, baseDir: paths.skillsDir,
                storeRoot: paths.skillsDir), fileService: block.files,
            fileWatchService: FileWatchService(rootDir: paths.skillsDir), manifestRoot: paths.storeRoot
        )
        let context = harness.container.mainContext
        let skill = try XCTUnwrap(library.createSkill(name: "Saved Skill", description: "Saved Skill",
            body: "before", tags: [], context: context))
        skill.updatedAt = Date(timeIntervalSince1970: 1)
        try context.save()
        library.regenerateManifest(context: context)
        let coordinator = await configuredCoordinator(container: harness.container,
            engine: SyncEngine(gitService: git, lockPath: paths.syncLockPath), git: git, root: paths.storeRoot)
        let first = await coordinator.runCycle()
        guard case .synced = first else { return XCTFail("Initial cycle: \(first)") }
        try block.files.writeFile(at: block.root + "/armed", content: "arm")
        let cycle = Task { await coordinator.runCycle() }
        await TestWait.until(failureMessage: "push did not block") { block.isBlocked }
        XCTAssertNil(SyncLock.tryAcquire(at: paths.syncLockPath))
        library.noteEditorChanged(skill, body: "saved during git")
        XCTAssertTrue(library.saveDraft(skill), library.error ?? "save refused")
        library.updateMetadata(skill, tags: ["saved-during-git"], scope: .user, context: context)
        let savedAt = skill.updatedAt
        block.release()
        let finished = await cycle.value
        guard case .synced = finished else { return XCTFail("Blocked cycle: \(finished)") }
        XCTAssertEqual(library.readBody(skill), "saved during git")
        let diskBeforeNext = try rawGitOutput(["--git-dir", harness.remotePath,
            "show", "HEAD:skills/\(skill.directoryName)/SKILL.md"])
        XCTAssertEqual(SkillParser.stripFrontmatter(diskBeforeNext), "before")
        let next = await coordinator.runCycle()
        guard case .synced = next else { return XCTFail("Next cycle: \(next)") }
        let committed = try rawGitOutput(["--git-dir", harness.remotePath,
            "show", "HEAD:skills/\(skill.directoryName)/SKILL.md"])
        XCTAssertEqual(SkillParser.stripFrontmatter(committed), "saved during git")
        let overlay = try rawGitOutput(["--git-dir", harness.remotePath,
            "show", "HEAD:manifest/skills/\(skill.directoryName).yaml"])
        XCTAssertTrue(overlay.contains("saved-during-git"), "The next commit must include the UI's saved metadata")
        let freshContext = ModelContext(harness.container)
        let fresh = try XCTUnwrap(freshContext.fetch(FetchDescriptor<Skill>()).first)
        XCTAssertEqual(fresh.tags, ["saved-during-git"])
        XCTAssertGreaterThanOrEqual(fresh.updatedAt, savedAt, "Rebuild must not restore an earlier UI timestamp")
    }
    private func blockingPush(repository: String) throws -> GitBlockingFixture {
        let block = try GitBlockingFixture()
        try block.files.writeExecutableFile(at: repository + "/.git/hooks/pre-push", content: """
        #!/bin/sh
        if [ -f '\(block.root)/armed' ]; then
            printf '%s' "$$" > '\(block.root)/ready'
            while [ ! -f '\(block.root)/release' ]; do /bin/sleep 0.01; done
        fi
        exit 0
        """)
        return block
    }

}
