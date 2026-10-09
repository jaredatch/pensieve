import SwiftData
import XCTest
@testable import Pensieve

extension PathGuardTests {
    @MainActor
    func testExistingComposedAndDecomposedSkillsDeploySyncAndRemove() throws {
        for name in ["caf\u{00E9}", "cafe\u{0301}"] {
            let root = TestTemporaryDirectory.path + "AccentLifecycle-" + UUID().uuidString
            let files = FileService()
            defer { try? files.deleteDirectory(at: root) }
            let storeA = root + "/caf\u{00E9}-store"
            let storeB = root + "/second"
            let remote = root + "/remote.git"
            let contextA = try lifecycleContext()
            let contextB = try lifecycleContext()
            let (skill, store) = try seedExistingLifecycle(name: name, storeA: storeA, storeB: storeB,
                remote: remote, contextA: contextA, contextB: contextB)
            let paths = DeployPaths(skillsDirectory: storeA + "/skills", userSkillsDirectories: [.claudeCode: root + "/agent"],
                                    cursorUserRulesDirectory: root + "/rules")
            let links = LinkService(fileService: files, paths: paths)
            try links.link(skill: skill, platform: .claudeCode, projectPath: nil)
            let link = links.linkPath(skill: skill, platform: .claudeCode, projectPath: nil)
            try files.deleteFile(at: link)
            let nfd = (storeA + "/skills/" + name).decomposedStringWithCanonicalMapping
            try files.createSymlink(at: link, pointingTo: nfd)
            XCTAssertTrue(try links.ownsArtifact(skill: skill, platform: .claudeCode, projectPath: nil))
            let engine = SyncEngine(gitService: AllowlistedRemoteGit(wrapping: TestPaths.git), fileService: files,
                                    lockPath: root + "/sync.lock")
            try store.writeBody(directoryName: name, body: "---\nname: Accent\ndescription: Fixture\n---\nupdated")
            XCTAssertEqual(try engine.sync(root: storeA, message: "update", credential: nil, context: contextA),
                           .synced(pushed: true, warnings: []))
            XCTAssertEqual(try engine.sync(root: storeB, message: "pull", credential: nil, context: contextB),
                           .synced(pushed: false, warnings: []))
            XCTAssertEqual(try files.readData(at: storeA + "/skills/" + name + "/SKILL.md"),
                           try files.readData(at: storeB + "/skills/" + name + "/SKILL.md"))
            XCTAssertEqual(try contextB.fetch(FetchDescriptor<Skill>()).map(\.directoryName), [name])
            let syncedName = try XCTUnwrap(contextB.fetch(FetchDescriptor<Skill>()).first).directoryName
            XCTAssertEqual(Array(syncedName.utf8), Array(name.utf8))
            XCTAssertTrue(try links.unlink(skill: skill, platform: .claudeCode, projectPath: nil))
            XCTAssertFalse(try files.entryExistsWithoutFollowingLinks(at: link))
            try store.deleteSkill(directoryName: name)
            contextA.delete(skill)
            try contextA.save()
            XCTAssertEqual(try engine.sync(root: storeA, message: "remove", credential: nil, context: contextA),
                           .synced(pushed: true, warnings: []))
            XCTAssertEqual(try engine.sync(root: storeB, message: "pull removal", credential: nil, context: contextB),
                           .synced(pushed: false, warnings: []))
            XCTAssertFalse(files.directoryExists(at: storeB + "/skills/" + name))
            XCTAssertTrue(try contextB.fetch(FetchDescriptor<Skill>()).isEmpty)
        }
    }

    @MainActor
    private func seedExistingLifecycle(name: String, storeA: String, storeB: String, remote: String,
                                       contextA: ModelContext, contextB: ModelContext) throws -> (Skill, SkillStore) {
        let files = FileService()
        let git = TestPaths.git
        try files.createDirectory(at: storeA)
        try git.runOrThrow(["init", "--bare", "--initial-branch=main", remote], in: nil)
        try git.initRepository(at: storeA)
        let store = SkillStore(fileService: files, baseDir: storeA + "/skills", storeRoot: storeA)
        try store.writeBody(directoryName: name, body: "---\nname: Accent\ndescription: Fixture\n---\noriginal")
        let skill = Skill(name: "Accent", skillDescription: "Fixture", directoryName: name)
        skill.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        contextA.insert(skill)
        try contextA.save()
        let manifest = ManifestService(fileService: files)
        try manifest.write(manifest.snapshot(from: contextA), toRoot: storeA)
        try files.writeFile(at: storeA + "/.gitattributes", content:
            "manifest/categories/*.yaml merge=union\n"
                + "manifest/scenarios/*.yaml merge=union\nmanifest/projects.yaml merge=union\n")
        try files.writeFile(at: storeA + "/.gitignore", content: ".DS_Store\n")
        try git.stageAllAndCommit(at: storeA, message: "existing accented skill")
        try git.setRemote("file://" + remote, at: storeA)
        try git.push(at: storeA, credential: nil)
        try git.clone(remote: "file://" + remote, into: storeB, credential: nil)
        // Both Macs already index this skill. A fresh clone can use Git's NFC directory spelling;
        // this compatibility case preserves the existing NFC or NFD metadata on both Macs.
        let existingB = Skill(name: "Accent", skillDescription: "Fixture", directoryName: name)
        existingB.createdAt = skill.createdAt
        contextB.insert(existingB)
        try contextB.save()
        XCTAssertFalse(StoreRebuildService().rebuild(fromRoot: storeB, context: contextB).storeUnreadable)
        try manifest.write(manifest.snapshot(from: contextB), toRoot: storeB)
        XCTAssertEqual(try git.runOrThrow(["diff"], in: storeB).stdout, "", "Seed must survive a normal rebuild unchanged")
        return (skill, store)
    }

    @MainActor
    private func lifecycleContext() throws -> ModelContext {
        let container = try ModelContainer(for: Skill.self, Project.self, Pensieve.Category.self,
            MachineDeployIntent.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }
}
