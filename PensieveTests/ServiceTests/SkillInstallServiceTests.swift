import XCTest
@testable import Pensieve

final class SkillInstallServiceTests: XCTestCase {
    var tempDir: String!
    var scratchRoot: String!
    var fileService: FileService!
    var gitService: GitService!
    var service: SkillInstallService!

    override func setUpWithError() throws {
        tempDir = NSTemporaryDirectory() + "PensieveSkillInstallServiceTests-\(UUID().uuidString)"
        scratchRoot = tempDir + "/scratch"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        fileService = FileService()
        gitService = GitService(fileService: fileService)
        service = SkillInstallService(
            gitService: gitService,
            credentialStore: InMemoryCredentialStore(),
            fileService: fileService,
            scratchRoot: scratchRoot,
            remoteValidator: fixtureRemoteValidator
        )
    }

    var fixtureRemoteValidator: InstallRemotePolicy.Validator {
        { ValidatedInstallRemote(repo: $0, cloneRemote: $0) }
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir) {
            try FileManager.default.removeItem(atPath: tempDir)
        }
    }

    struct RawResult {
        let stdout: String
        let stderr: String
        let exit: Int32
    }

    @discardableResult
    func rawGit(_ args: [String]) throws -> RawResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return RawResult(
            stdout: String(bytes: stdoutData, encoding: .utf8) ?? "",
            stderr: String(bytes: stderrData, encoding: .utf8) ?? "",
            exit: process.terminationStatus
        )
    }

    func makeRepository(named name: String = "fixture") throws -> String {
        let path = tempDir + "/" + name
        let result = try rawGit(["init", "--initial-branch=main", path])
        XCTAssertEqual(result.exit, 0, result.stderr)
        return path
    }

    func write(_ relativePath: String, content: String, in repository: String) throws {
        let path = repository + "/" + relativePath
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func writeSkill(_ relativeDirectory: String, name: String, description: String,
                    in repository: String) throws {
        let prefix = relativeDirectory.isEmpty ? "" : relativeDirectory + "/"
        try write(
            prefix + "SKILL.md",
            content: "---\nname: \(name)\ndescription: \(description)\n---\nbody\n",
            in: repository
        )
    }

    @discardableResult
    func commit(_ repository: String, message: String = "seed") throws -> String {
        let add = try rawGit(["-C", repository, "add", "-A"])
        XCTAssertEqual(add.exit, 0, add.stderr)
        let result = try rawGit([
            "-C", repository,
            "-c", "user.email=t@t",
            "-c", "user.name=t",
            "commit", "-m", message
        ])
        XCTAssertEqual(result.exit, 0, result.stderr)
        return try revision("HEAD", in: repository)
    }

    func revision(_ value: String, in repository: String) throws -> String {
        let result = try rawGit(["-C", repository, "rev-parse", value])
        XCTAssertEqual(result.exit, 0, result.stderr)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func assertScratchHasNoClones(file: StaticString = #filePath,
                                          line: UInt = #line) throws {
        XCTAssertTrue(fileService.directoryExists(at: scratchRoot), file: file, line: line)
        XCTAssertEqual(try fileService.listDirectory(at: scratchRoot), [], file: file, line: line)
    }

    func testFetchDiscoversFlatLayoutAndRecordsGitCoordinates() throws {
        let repository = try makeRepository(named: "Flat Fixture")
        try writeSkill("skills/PDF Tools", name: "PDF", description: "Work with PDFs", in: repository)
        let expectedCommit = try commit(repository)
        let expectedTree = try revision("HEAD:skills/PDF Tools", in: repository)

        let result = try service.fetch(repo: repository, ref: nil, credential: nil)

        XCTAssertEqual(result.ref, "main")
        XCTAssertEqual(result.headCommit, expectedCommit)
        XCTAssertEqual(result.candidates, [
            SkillCandidate(
                path: "skills/PDF Tools",
                slug: "pdf-tools",
                name: "PDF",
                skillDescription: "Work with PDFs",
                treeHash: expectedTree,
                containsSymlink: false,
                unavailableReason: nil
            )
        ])
        try assertScratchHasNoClones()
    }

    func testDiscoveryFindsCatalogAndHonorsShallowShadowing() throws {
        let repository = try makeRepository()
        try writeSkill("skills/catalog", name: "Catalog", description: "shallow", in: repository)
        try writeSkill("skills/catalog/hidden", name: "Hidden", description: "shadowed", in: repository)
        try writeSkill("skills/writing/reviewer", name: "Reviewer", description: "nested", in: repository)
        try commit(repository)

        let candidates = try service.fetch(repo: repository, ref: nil, credential: nil).candidates

        XCTAssertEqual(candidates.map(\.path), ["skills/catalog", "skills/writing/reviewer"])
        XCTAssertEqual(candidates.map(\.slug), ["catalog", "reviewer"])
    }

    func testDiscoveryFindsRootAndClaudeLayouts() throws {
        let repository = try makeRepository(named: "Root Skill Repo")
        try writeSkill("", name: "Root", description: "root skill", in: repository)
        try writeSkill(".claude/skills/helper", name: "Helper", description: "claude", in: repository)
        try commit(repository)
        let rootTree = try revision("HEAD^{tree}", in: repository)

        let candidates = try service.fetch(repo: repository, ref: nil, credential: nil).candidates

        XCTAssertEqual(candidates.map(\.path), ["", ".claude/skills/helper"])
        XCTAssertEqual(candidates.first?.slug, "root-skill-repo")
        XCTAssertEqual(candidates.first?.treeHash, rootTree)
    }

    func testDiscoveryStaysWithinFrozenBoundedWalk() throws {
        let repository = try makeRepository()
        try writeSkill("skills/ok", name: "OK", description: "found", in: repository)
        try writeSkill("skills/.curated/nope", name: "Nope", description: "dot container", in: repository)
        try writeSkill("skills/a/b/c", name: "Deep", description: "too deep", in: repository)
        try writeSkill("other/deep", name: "Other", description: "recursive fallback", in: repository)
        try commit(repository)

        let candidates = try service.fetch(repo: repository, ref: nil, credential: nil).candidates

        XCTAssertEqual(candidates.map(\.path), ["skills/ok"])
    }

    func testDiscoverySurfacesInvalidFrontmatterAsUnavailable() throws {
        let repository = try makeRepository()
        try write(
            "skills/broken/SKILL.md",
            content: "---\nname: broken\n---\nbody\n",
            in: repository
        )
        // A truly frontmatter-less body — not just partial frontmatter — must also surface
        // visible-but-non-installable (Layer-2 19.3: partial-only fixtures can't catch a parser
        // that admits body-only files).
        try write(
            "skills/bare/SKILL.md",
            content: "just a body, no frontmatter at all\n",
            in: repository
        )
        try commit(repository)

        let candidates = try service.fetch(repo: repository, ref: nil, credential: nil).candidates

        XCTAssertEqual(candidates.map(\.path), ["skills/bare", "skills/broken"])
        let bare = try XCTUnwrap(candidates.first { $0.path == "skills/bare" })
        XCTAssertNil(bare.name)
        XCTAssertFalse(bare.isInstallable)
        XCTAssertNotNil(bare.unavailableReason)
        let broken = try XCTUnwrap(candidates.first { $0.path == "skills/broken" })
        XCTAssertEqual(broken.name, "broken")
        XCTAssertNil(broken.skillDescription)
        XCTAssertFalse(broken.isInstallable)
        XCTAssertNotNil(broken.unavailableReason)
    }

    func testDiscoveryRejectsNonScalarKeyFrontmatter() throws {
        let repository = try makeRepository()
        try write(
            "skills/hostile/SKILL.md",
            content: "---\nname: Hostile\ndescription: Hostile\nmeta:\n  ? [x]\n  : y\n---\nbody\n",
            in: repository
        )
        try commit(repository)

        let candidate = try XCTUnwrap(
            service.fetch(repo: repository, ref: nil, credential: nil).candidates.first
        )

        XCTAssertEqual(candidate.path, "skills/hostile")
        XCTAssertNil(candidate.name)
        XCTAssertFalse(candidate.isInstallable)
        XCTAssertEqual(
            candidate.unavailableReason,
            "SKILL.md needs parseable frontmatter with non-empty name and description"
        )
    }
}

extension SkillInstallServiceTests {
    func testDiscoveryFlagsSymlinkCandidate() throws {
        let repository = try makeRepository()
        try writeSkill("skills/hostile", name: "Hostile", description: "has link", in: repository)
        let outside = tempDir + "/outside.txt"
        try "outside".write(toFile: outside, atomically: true, encoding: .utf8)
        let link = repository + "/skills/hostile/assets/escape"
        try FileManager.default.createDirectory(
            atPath: (link as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: outside)
        try commit(repository)

        let candidate = try XCTUnwrap(
            service.fetch(repo: repository, ref: nil, credential: nil).candidates.first
        )

        XCTAssertTrue(candidate.containsSymlink)
        XCTAssertFalse(candidate.isInstallable)
        XCTAssertEqual(candidate.unavailableReason, "skill contains a symbolic link")
    }

    func testDiscoveryFlagsSymlinkDirectoryWithoutFollowingIt() throws {
        let repository = try makeRepository()
        let outside = tempDir + "/outside-skill"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try writeSkill("", name: "Outside", description: "must not be read", in: outside)
        try FileManager.default.createDirectory(
            atPath: repository + "/skills",
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: repository + "/skills/linked",
            withDestinationPath: outside
        )
        try commit(repository)

        let candidate = try XCTUnwrap(
            service.fetch(repo: repository, ref: nil, credential: nil).candidates.first
        )

        XCTAssertEqual(candidate.path, "skills/linked")
        XCTAssertTrue(candidate.containsSymlink)
        XCTAssertNil(candidate.name, "discovery must not follow the directory symlink")
        XCTAssertFalse(candidate.isInstallable)
    }

    func testTargetedDiscoveryReturnsOnlyNamedDirectory() throws {
        let repository = try makeRepository()
        try writeSkill("skills/one", name: "One", description: "one", in: repository)
        try writeSkill("skills/two", name: "Two", description: "two", in: repository)
        try commit(repository)

        let result = try service.fetch(
            repo: repository,
            ref: "main",
            path: "skills/two",
            credential: nil
        )

        XCTAssertEqual(result.ref, "main")
        XCTAssertEqual(result.candidates.map(\.path), ["skills/two"])
        try assertScratchHasNoClones()
    }

    func testTargetedDiscoveryMissingSkillThrowsAndCleansClone() throws {
        let repository = try makeRepository()
        try write("skills/missing/README.md", content: "not a skill\n", in: repository)
        try commit(repository)

        XCTAssertThrowsError(
            try service.fetch(
                repo: repository,
                ref: nil,
                path: "skills/missing",
                credential: nil
            )
        ) { error in
            XCTAssertEqual(error.localizedDescription, "no SKILL.md at skills/missing")
        }
        try assertScratchHasNoClones()
    }

    func testFetchUsesExplicitBranchAndRecordsItsHead() throws {
        let repository = try makeRepository()
        try writeSkill("skills/main", name: "Main", description: "main", in: repository)
        try commit(repository)
        let checkout = try rawGit(["-C", repository, "checkout", "-b", "release"])
        XCTAssertEqual(checkout.exit, 0, checkout.stderr)
        try writeSkill("skills/release", name: "Release", description: "release", in: repository)
        let releaseCommit = try commit(repository, message: "release")

        let result = try service.fetch(repo: repository, ref: "release", credential: nil)

        XCTAssertEqual(result.ref, "release")
        XCTAssertEqual(result.headCommit, releaseCommit)
        XCTAssertEqual(result.candidates.map(\.path), ["skills/main", "skills/release"])
    }

    func testLaunchCleanupWipesStaleScratchRoot() throws {
        try fileService.createDirectory(at: scratchRoot + "/stale/partial.git")
        try fileService.writeFile(at: scratchRoot + "/stale/partial.git/HEAD", content: "partial")

        SkillInstallService.cleanupScratchRoot(
            fileService: fileService,
            scratchRoot: scratchRoot
        )

        XCTAssertFalse(fileService.directoryExists(at: scratchRoot))
    }
}
