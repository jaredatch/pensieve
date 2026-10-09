import XCTest
import SwiftData
@testable import Pensieve

private typealias PensieveCategory = Pensieve.Category

// MARK: - Real-git integration (union-merge over file:// clones)

extension SyncEngineTests {
    /// Bare-remote creation only (no commit → no identity needed). Production paths use GitService.
    @discardableResult
    private func rawGit(_ args: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = env
        let sink = Pipe()
        process.standardOutput = sink
        process.standardError = sink
        try process.run()
        _ = sink.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Seed the union attributes + ignore file exactly as `SyncEngine.ensureSyncAttributes` would.
    private func writeSyncControlFiles(at root: String) throws {
        let attrs = "manifest/categories/*.yaml merge=union\nmanifest/projects.yaml merge=union\n"
        try attrs.write(toFile: root + "/.gitattributes", atomically: true, encoding: .utf8)
        try ".DS_Store\n".write(toFile: root + "/.gitignore", atomically: true, encoding: .utf8)
    }

    private func insertCategory(name: String, skillSlugs: [String], into context: ModelContext) throws {
        let category = PensieveCategory(name: name)
        category.skillSlugs = skillSlugs
        context.insert(category)
        try context.save()
    }

    // MARK: (e) two-clone category union: both skill slugs survive, deduped, both converge

    func testTwoCloneCategoryUnionMergeYieldsBothSlugs() throws {
        let git = TestPaths.git
        let manifest = ManifestService()
        let engine = SyncEngine(gitService: AllowlistedRemoteGit(wrapping: git), manifestService: manifest,
                                storeRebuildService: StoreRebuildService(), fileService: FileService(), lockPath: lockPath)
        // Seed the remote with "Swift" (EMPTY slug list) + union attributes, so both clones share it as
        // the merge ANCESTOR (an add/add on a brand-new file conflicts; the seed makes the two additions
        // a modify/modify that unions).
        let remote = try seedRemote(git: git) { seed in
            let snapshot = ManifestSnapshot(schemaVersion: 1,
                                            categories: [CategoryRecord(name: "Swift", projectKeys: [], skillSlugs: [])],
                                            projects: [], skills: [])
            try manifest.write(snapshot, toRoot: seed)
        }
        let cloneA = tempDir + "/cloneA"
        let cloneB = tempDir + "/cloneB"
        try git.clone(remote: remote, into: cloneA, credential: nil)
        try git.clone(remote: remote, into: cloneB, credential: nil)

        let contextA = try makeContext()
        let contextB = try makeContext()
        try insertCategory(name: "Swift", skillSlugs: ["alpha"], into: contextA)
        try insertCategory(name: "Swift", skillSlugs: ["beta"], into: contextB)
        _ = try engine.sync(root: cloneA, message: "A", credential: nil, context: contextA)
        _ = try engine.sync(root: cloneB, message: "B", credential: nil, context: contextB)   // pull unions
        _ = try engine.sync(root: cloneA, message: "A2", credential: nil, context: contextA)   // A pulls union

        let readA = try manifest.read(fromRoot: cloneA).categories.first { $0.name == "Swift" }
        let readB = try manifest.read(fromRoot: cloneB).categories.first { $0.name == "Swift" }
        XCTAssertEqual(readA?.skillSlugs, ["alpha", "beta"], "clone A converges to both slugs deduped")
        XCTAssertEqual(readB?.skillSlugs, ["alpha", "beta"], "clone B converges to both slugs deduped")
    }

    // MARK: (f) two-clone project union: same identity_key, different names → deterministic winner

    func testTwoCloneProjectUnionConvergesToDeterministicWinner() throws {
        let git = TestPaths.git
        let manifest = ManifestService()
        let remote = try seedRemote(git: git) { seed in
            try manifest.write(ManifestSnapshot(schemaVersion: 1, categories: [], projects: [], skills: []),
                               toRoot: seed)
        }
        let cloneA = tempDir + "/pcloneA"
        let cloneB = tempDir + "/pcloneB"
        try git.clone(remote: remote, into: cloneA, credential: nil)
        try git.clone(remote: remote, into: cloneB, credential: nil)

        let key = "github.com/octocat/app"
        try writeProjects(manifest, root: cloneA,
                          [ProjectIdentityRecord(identityKey: key, identityKind: "remote", name: "App A")])
        XCTAssertTrue(try git.stageAllAndCommit(at: cloneA, message: "A registers"))
        try git.push(at: cloneA, credential: nil)

        try writeProjects(manifest, root: cloneB,
                          [ProjectIdentityRecord(identityKey: key, identityKind: "remote", name: "App B")])
        XCTAssertTrue(try git.stageAllAndCommit(at: cloneB, message: "B registers"))
        XCTAssertEqual(try git.pullRebase(at: cloneB, credential: nil), .merged)   // union
        try git.push(at: cloneB, credential: nil)
        XCTAssertEqual(try git.pullRebase(at: cloneA, credential: nil), .merged)   // A pulls union

        let winnerA = try manifest.read(fromRoot: cloneA).projects.filter { $0.identityKey == key }
        let winnerB = try manifest.read(fromRoot: cloneB).projects.filter { $0.identityKey == key }
        XCTAssertEqual(winnerA.count, 1, "the identity appears exactly ONCE after dedup")
        XCTAssertEqual(winnerB.count, 1)
        XCTAssertEqual(winnerA.first?.name, "App A", "winner = lexicographically-first (name, identity_kind)")
        XCTAssertEqual(winnerA, winnerB, "BOTH clones converge to the identical record")
    }

    private func writeProjects(_ manifest: ManifestService, root: String,
                               _ projects: [ProjectIdentityRecord]) throws {
        try manifest.write(ManifestSnapshot(schemaVersion: 1, categories: [], projects: projects, skills: []),
                           toRoot: root)
    }

    // MARK: (g) two-machine round-trip: a skill BODY + a category propagate A→B, an edit propagates B→A

    /// BETTER-1 payoff: real GitService/SyncEngine/StoreRebuildService over a bare `file://` remote.
    func testTwoMachineRoundTripSkillBodyAndCategoryPropagate() throws {
        let git = TestPaths.git
        let manifest = ManifestService()
        let engine = SyncEngine(gitService: AllowlistedRemoteGit(wrapping: git), manifestService: manifest,
                                storeRebuildService: StoreRebuildService(), fileService: FileService(), lockPath: lockPath)
        let remote = try seedRemote(git: git) { seed in
            try manifest.write(ManifestSnapshot(schemaVersion: 1, categories: [], projects: [], skills: []),
                               toRoot: seed)
        }

        // A: fixed createdAt keeps overlays byte-identical; only SKILL.md body differs.
        let cloneA = tempDir + "/rtCloneA"
        try git.clone(remote: remote, into: cloneA, credential: nil)
        try writeSkillFile(root: cloneA, slug: "greeting", description: "greeting description", body: "Hello")
        let contextA = try makeContext()
        let skillA = Skill(name: "greeting", skillDescription: "greeting description", tags: [],
                           scope: .user, directoryName: "greeting", cursorConfig: nil, importedFrom: nil)
        skillA.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        skillA.updatedAt = skillA.createdAt
        contextA.insert(skillA)
        try insertCategory(name: "Comms", skillSlugs: ["greeting"], into: contextA)
        XCTAssertEqual(try engine.sync(root: cloneA, message: "A creates greeting + Comms",
                                       credential: nil, context: contextA), .synced(pushed: true, warnings: []))

        // B: clone + rebuild → the body file AND the category rule materialized.
        let cloneB = tempDir + "/rtCloneB"
        try git.clone(remote: remote, into: cloneB, credential: nil)
        let contextB = try makeContext()
        _ = StoreRebuildService().rebuild(fromRoot: cloneB, context: contextB)
        XCTAssertEqual(try String(contentsOfFile: cloneB + "/skills/greeting/SKILL.md", encoding: .utf8)
            .contains("Hello"), true, "B's clone has the synced SKILL.md body on disk")
        let bSkill = try XCTUnwrap(fetchSkill("greeting", in: contextB), "B rebuilt the skill row")
        XCTAssertEqual(bSkill.skillDescription, "greeting description")
        let bCat = try XCTUnwrap(fetchCategory("Comms", in: contextB), "B rebuilt the category rule")
        XCTAssertEqual(bCat.skillSlugs, ["greeting"], "the category→skill assignment propagated")

        // B: edit the skill body/description, then sync (push).
        try writeSkillFile(root: cloneB, slug: "greeting", description: "EDITED description", body: "Hi there")
        _ = StoreRebuildService().rebuild(fromRoot: cloneB, context: contextB)   // pick up the edit
        _ = try engine.sync(root: cloneB, message: "B edits greeting", credential: nil, context: contextB)

        // A: pull → the edit propagated to A's store AND A's disk.
        _ = try engine.sync(root: cloneA, message: "A pulls B's edit", credential: nil, context: contextA)
        XCTAssertTrue(try String(contentsOfFile: cloneA + "/skills/greeting/SKILL.md", encoding: .utf8)
            .contains("Hi there"), "B's body edit reached A's disk")
        let aSkill = try XCTUnwrap(fetchSkill("greeting", in: contextA))
        XCTAssertEqual(aSkill.skillDescription, "EDITED description", "B's edit propagated into A's store")
    }

    /// Simulates the older peer's write/commit/pull/push order, with its frozen 0.14 attributes.
    func testLegacyPeerAttributesChurnKeepsSyncAndSkillChangesFlowing() throws {
        let git = TestPaths.git
        let files = FileService()
        let legacyAttributes = "manifest/categories/*.yaml merge=union\n"
            + "manifest/scenarios/*.yaml merge=union\nmanifest/projects.yaml merge=union\n"
        let remote = try seedRemote(git: git) { seed in
            try ManifestService().write(sampleManifestSnapshot(), toRoot: seed)
        }
        let current = tempDir + "/current"
        let legacy = tempDir + "/legacy"
        try git.clone(remote: remote, into: current, credential: nil)
        try git.clone(remote: remote, into: legacy, credential: nil)
        let context = try makeContext()
        let engine = SyncEngine(gitService: AllowlistedRemoteGit(wrapping: git), manifestService: ManifestService(),
                                storeRebuildService: StoreRebuildService(), fileService: files, lockPath: lockPath)
        _ = StoreRebuildService().rebuild(fromRoot: current, context: context)
        for round in 1...3 {
            try files.writeFile(at: legacy + "/.gitattributes", content: legacyAttributes)
            try writeSkillFile(root: legacy, slug: "from-legacy", description: "Legacy", body: "Legacy \(round)")
            XCTAssertTrue(try git.stageAllAndCommit(at: legacy, message: "Legacy \(round)"))
            try writeSkillFile(root: current, slug: "from-current", description: "Current", body: "Current \(round)")
            _ = StoreRebuildService().rebuild(fromRoot: current, context: context)
            let outcome = try engine.sync(root: current, message: "Current \(round)", credential: nil, context: context)
            guard case .synced = outcome else { return XCTFail("Current peer stopped: \(outcome)") }
            let pull = try git.pullRebase(at: legacy, credential: nil)
            XCTAssertTrue(pull == .merged || pull == .upToDate, "Legacy peer stopped: \(pull)")
            try git.push(at: legacy, credential: nil)
            let ingested = try engine.sync(root: current, message: "Ingest legacy", credential: nil, context: context)
            guard case .synced = ingested else { return XCTFail("Current peer stopped: \(ingested)") }
            XCTAssertEqual(try files.readFile(at: current + "/skills/from-legacy/SKILL.md"),
                           try files.readFile(at: legacy + "/skills/from-legacy/SKILL.md"))
            XCTAssertEqual(try files.readFile(at: legacy + "/skills/from-current/SKILL.md"),
                           try files.readFile(at: current + "/skills/from-current/SKILL.md"))
            XCTAssertTrue(try files.readFile(at: current + "/skills/from-legacy/SKILL.md").contains("Legacy \(round)"))
            XCTAssertTrue(try files.readFile(at: legacy + "/skills/from-current/SKILL.md").contains("Current \(round)"))
            XCTAssertNotNil(fetchSkill("from-legacy", in: context))
            XCTAssertFalse(files.directoryExists(at: current + "/.git/rebase-merge"))
            XCTAssertFalse(files.directoryExists(at: current + "/.git/rebase-apply"))
        }
    }

    /// Write a self-describing `SKILL.md` (canonical frontmatter + body) under `root/skills/<slug>/`.
    private func writeSkillFile(root: String, slug: String, description: String, body: String) throws {
        let dir = root + "/skills/" + slug
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let markdown = "---\nname: \(slug)\ndescription: \(description)\n---\n\n\(body)\n"
        try markdown.write(toFile: dir + "/SKILL.md", atomically: true, encoding: .utf8)
    }
    private func fetchSkill(_ slug: String, in context: ModelContext) -> Skill? {
        ((try? context.fetch(FetchDescriptor<Skill>())) ?? []).first { $0.directoryName == slug }
    }
    private func fetchCategory(_ name: String, in context: ModelContext) -> PensieveCategory? {
        ((try? context.fetch(FetchDescriptor<PensieveCategory>())) ?? []).first { $0.name == name }
    }

    /// Create a bare remote with an initial commit on `main`, so clones share a mergeable ancestor.
    private func seedRemote(git: GitService, writeSeed: (String) throws -> Void) throws -> String {
        let remotePath = tempDir + "/remote-\(UUID().uuidString).git"
        XCTAssertEqual(try rawGit(["init", "--bare", remotePath]), 0, "bare init failed")
        let remote = "file://" + remotePath
        let seed = tempDir + "/seed-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: seed, withIntermediateDirectories: true)
        try git.initRepository(at: seed)
        try git.setRemote(remote, at: seed)
        try writeSeed(seed)
        try writeSyncControlFiles(at: seed)
        XCTAssertTrue(try git.stageAllAndCommit(at: seed, message: "seed"))
        try git.push(at: seed, credential: nil)
        return remote
    }
}
