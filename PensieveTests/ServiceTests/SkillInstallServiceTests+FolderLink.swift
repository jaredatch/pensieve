import SwiftData
import XCTest
@testable import Pensieve

extension SkillInstallServiceTests {
    func testFolderLinkKeepsOwnSkillAheadOfDescendants() throws {
        let repository = try makeRepository()
        try writeSkill("catalog", name: "Catalog", description: "target", in: repository)
        try writeSkill("catalog/child", name: "Child", description: "child", in: repository)
        try writeSkill("catalog/skills/nested", name: "Nested", description: "nested", in: repository)
        try writeSkill("catalog/.claude/skills/helper", name: "Helper", description: "helper", in: repository)
        try commit(repository)

        XCTAssertEqual(
            try service.fetch(repo: repository, ref: nil, path: "catalog", credential: nil).candidates.map(\.path),
            ["catalog"]
        )
    }

    func testFolderLinkListsTwoImmediateSkills() throws {
        let repository = try makeRepository(named: "agents")
        try writeSkill("skills/design", name: "Design", description: "Design skills", in: repository)
        try writeSkill("skills/review", name: "Review", description: "Review skills", in: repository)
        try commit(repository)
        let expected = try ["design", "review"].map { name in
            SkillCandidate(
                path: "skills/" + name,
                slug: name,
                name: name.capitalized,
                skillDescription: name.capitalized + " skills",
                treeHash: try revision("HEAD:skills/" + name, in: repository),
                containsSymlink: false,
                unavailableReason: nil
            )
        }

        XCTAssertEqual(
            try service.fetch(repo: repository, ref: "main", path: "skills", credential: nil).candidates,
            expected
        )
    }

    func testFolderLinkIncludesBoundedAndRepositoryLayouts() throws {
        let repository = try makeRepository()
        let expected = [
            "bundle/.claude/skills/helper", "bundle/category/reviewer", "bundle/direct",
            "bundle/skills/flat", "bundle/skills/writing/editor"
        ]
        let excluded = [
            "bundle/direct/shadowed", "bundle/category/deep/hidden",
            "bundle/skills/writing/deep/hidden", "bundle/.claude/skills/category/hidden",
            "outside/sibling"
        ]
        for path in expected + excluded {
            try writeSkill(path, name: "Skill", description: "fixture", in: repository)
        }
        try commit(repository)

        XCTAssertEqual(
            try service.fetch(repo: repository, ref: nil, path: "bundle", credential: nil).candidates.map(\.path),
            expected
        )
    }

    func testFolderLinkSkipsDotEntriesAndFlagsSymlinks() throws {
        let repository = try makeRepository()
        let hidden = [
            "bundle/.hidden", "bundle/.category/hidden", "bundle/category/.hidden",
            "bundle/skills/.hidden", "bundle/skills/.category/hidden", "bundle/skills/category/.hidden",
            "bundle/.claude/skills/.hidden"
        ]
        for path in hidden + ["bundle/valid", "bundle/with-asset-link"] {
            try writeSkill(path, name: "Skill", description: "fixture", in: repository)
        }
        let links = [
            "bundle/linked", "bundle/category/linked", "bundle/skills/linked",
            "bundle/skills/category/linked", "bundle/.claude/skills/linked"
        ]
        let outside = tempDir + "/outside-skill"
        try writeSkill("", name: "Outside", description: "must not be read", in: outside)
        for path in links + ["bundle/.hidden-link", "bundle/with-asset-link/asset"] {
            try fileService.createDirectory(at: ((repository + "/" + path) as NSString).deletingLastPathComponent)
            try fileService.createSymlink(at: repository + "/" + path, pointingTo: outside)
        }
        try fileService.createDirectory(at: repository + "/bundle/linked-markdown")
        try fileService.createSymlink(
            at: repository + "/bundle/linked-markdown/SKILL.md", pointingTo: outside + "/SKILL.md"
        )
        try commit(repository)

        let candidates = try service.fetch(repo: repository, ref: nil, path: "bundle", credential: nil).candidates
        let expected = (links + ["bundle/linked-markdown", "bundle/valid", "bundle/with-asset-link"]).sorted()
        XCTAssertEqual(candidates.map(\.path), expected)
        for candidate in candidates where candidate.path != "bundle/valid" {
            XCTAssertTrue(candidate.containsSymlink, candidate.path)
            XCTAssertFalse(candidate.isInstallable, candidate.path)
            XCTAssertEqual(candidate.unavailableReason, "skill contains a symbolic link", candidate.path)
            if candidate.path != "bundle/with-asset-link" {
                XCTAssertNil(candidate.name, "discovery must not read linked content: " + candidate.path)
            }
        }
        XCTAssertEqual(candidates.first { $0.path == "bundle/valid" }?.isInstallable, true)
    }

    func testFolderLinkRejectsEmptyMissingAndUnsafePaths() throws {
        let repository = try makeRepository()
        try write("empty/README.md", content: "no skills", in: repository)
        try writeSkill("catalog/one", name: "One", description: "fixture", in: repository)
        try fileService.createSymlink(at: repository + "/linked", pointingTo: repository + "/catalog")
        try commit(repository)

        for path in ["empty", "missing", "linked", "linked/one"] {
            XCTAssertThrowsError(try service.discover(at: repository, path: path)) {
                XCTAssertEqual($0 as? SkillInstallError, .noSkillMarkdown(path: path), path)
                XCTAssertEqual($0.localizedDescription, "no SKILL.md at " + path)
            }
        }
        for path in ["../catalog", "/catalog", "catalog//one", "catalog/./one", "catalog/one/", "catalog\n/one"] {
            XCTAssertThrowsError(try service.discover(at: repository, path: path)) {
                XCTAssertEqual($0 as? SkillInstallError, .invalidRepositoryPath(path), path)
            }
        }
    }

    @MainActor
    func testFolderLinkInstallRecordsPathAndUpdateChecksOwnFolder() throws {
        let repository = try makeRepository()
        try writeSkill("catalog/category/one", name: "One", description: "original", in: repository)
        try writeSkill("catalog/category/two", name: "Two", description: "sibling", in: repository)
        try writeSkill("category/one", name: "One", description: "original", in: repository)
        try commit(repository)
        let root = tempDir + "/store"
        let installer = makeInstallService(root: root)
        let fetched = try installer.fetch(repo: repository, ref: nil, path: "catalog", credential: nil)
        let candidate = try XCTUnwrap(fetched.candidates.first { $0.slug == "one" })
        let container = try ModelContainer(
            for: Skill.self, RepoUpdateCursor.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        XCTAssertEqual(try installer.install(candidate: candidate, from: fetched, context: context), .installed(slug: "one"))
        let skill = try XCTUnwrap(try ModelContext(container).fetch(FetchDescriptor<Skill>()).first)
        XCTAssertEqual(skill.installedOrigin?.path, "catalog/category/one")
        let overlay = try XCTUnwrap(try ManifestService().read(fromRoot: root).skills.first)
        guard case let .installed(origin) = overlay.origin else { return XCTFail("expected installed origin") }
        XCTAssertEqual(origin.path, "catalog/category/one")
        XCTAssertEqual(
            try fileService.readFile(at: root + "/skills/one/SKILL.md"),
            try fileService.readFile(at: repository + "/catalog/category/one/SKILL.md")
        )
        let checker = UpdateCheckService(
            gitService: gitService, credentialStore: InMemoryCredentialStore(), fileService: fileService,
            contentHasher: installer, scratchRoot: tempDir + "/update-scratch", storeRoot: root,
            remoteValidator: fixtureRemoteValidator
        )
        try writeSkill("catalog/category/two", name: "Two", description: "changed sibling", in: repository)
        try commit(repository, message: "sibling changed")
        try checker.checkAll(context: context)
        let unchanged = try XCTUnwrap(try ModelContext(container).fetch(FetchDescriptor<Skill>()).first)
        XCTAssertNil(unchanged.checkError)
        XCTAssertFalse(unchanged.updateAvailable, "a sibling change must not count as this skill's update")
        try writeSkill("catalog/category/one", name: "One", description: "updated", in: repository)
        let updatedCommit = try commit(repository, message: "skill changed")
        try checker.checkAll(context: context)
        let updated = try XCTUnwrap(try ModelContext(container).fetch(FetchDescriptor<Skill>()).first)
        XCTAssertNil(updated.checkError)
        XCTAssertTrue(updated.updateAvailable)
        XCTAssertEqual(updated.upstreamCommit, updatedCommit)
        XCTAssertEqual(updated.upstreamTree, try revision("HEAD:catalog/category/one", in: repository))
    }
}
