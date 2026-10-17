import SwiftData
import XCTest
@testable import Pensieve

final class TestStoreDirectoryTests: XCTestCase {
    func testCloneStagingSurvivesAnotherFixturesSweep() throws {
        try NativeTestWork.run {
            let files = FileService()
            let sweeping = TestStoreDirectory(named: "sweeping-fixture")
            let cloning = TestStoreDirectory(named: "cloning-fixture")
            defer {
                try? files.deleteDirectory(at: sweeping.root)
                try? files.deleteDirectory(at: cloning.root)
            }
            let paths = AppRuntimePaths(storeRoot: sweeping.storeRoot, appSupportDir: sweeping.root + "/support")
            let cloneLock = try XCTUnwrap(SyncLock.tryAcquire(at: cloning.root + "/sync.lock"))
            defer { cloneLock.release() }
            try files.createDirectory(at: sweeping.storeRoot)
            let context = ModelContext(try ModelContainer(
                for: Skill.self, Project.self, SkillProjectAssignment.self, DeployRecord.self, Pensieve.Category.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
            let launch = LaunchReconciler(migrationService: StoreMigrationService(skillStore: SkillStore(
                fileService: files, baseDir: paths.skillsDir, storeRoot: paths.storeRoot)),
                root: paths.storeRoot, lockPath: paths.syncLockPath, git: TestPaths.git)
            let sweeps: [(String, () -> Void)] = [
                ("direct", { GitService.cleanupCloneTemps(fileService: files,
                    storeRoot: paths.storeRoot, lockPath: paths.syncLockPath) }),
                ("runtime", { paths.cleanupGitHubSkillTemps(fileService: files) }),
                ("launch", { _ = launch.reconcileOnLaunch(context: context, alreadyMigrated: true) })
            ]
            for (name, sweep) in sweeps {
                // Match GitService.clone: staging is a sibling of the destination, not a child.
                let active = (cloning.storeRoot as NSString).deletingLastPathComponent
                    + "/.pensieve-clone-" + UUID().uuidString
                let abandoned = (sweeping.storeRoot as NSString).deletingLastPathComponent
                    + "/.pensieve-clone-" + UUID().uuidString
                defer {
                    try? files.deleteDirectory(at: active)
                    try? files.deleteDirectory(at: abandoned)
                }
                try files.writeFile(at: active + "/checkout-in-progress", content: "active clone")
                try files.writeFile(at: abandoned + "/partial", content: "abandoned clone")
                sweep()
                XCTAssertFalse(files.directoryExists(at: abandoned), "\(name) must actually sweep its own parent")
                XCTAssertTrue(files.fileExists(at: active + "/checkout-in-progress"),
                              "\(name) sweep must preserve another fixture's active clone staging folder")
            }
        }
    }
}
