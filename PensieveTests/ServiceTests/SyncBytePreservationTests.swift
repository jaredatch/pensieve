import SwiftData
import XCTest
@testable import Pensieve

/// Real sync, install and checkout under two separate user homes. The HTTPS helper accepts only
/// the rewritten fixture URL and connects to a local bare repository; it never opens the network.
@MainActor
final class SyncBytePreservationTests: XCTestCase {
    private var base: String!
    private let files = FileService()
    private let remoteURL = "https://github.com/fixture/store.git"

    override func setUpWithError() throws {
        base = TestTemporaryDirectory.path + "SyncBytes-" + UUID().uuidString
        try files.createDirectory(at: base)
    }

    override func tearDownWithError() throws {
        if let base { try files.deleteDirectory(at: base) }
    }

    func testGlobalIgnoreAndLineEndingRulesPreserveImportedAndAuthoredBytes() throws {
        try roundTrip(skillRules: false, installed: false)
    }

    func testInstalledSkillRulesAndControlFilesPreserveBytesAndHash() throws {
        try roundTrip(skillRules: true, installed: true)
    }

    func testGlobalIdentFilterAndEncodingRulesPreserveBytes() throws {
        try roundTrip(skillRules: false, installed: false, transformations: true)
    }

    func testSkillIdentFilterAndEncodingRulesPreserveBytes() throws {
        try roundTrip(skillRules: true, installed: false, transformations: true)
    }

    func testExistingStoreStatusAndFastForwardPreserveSkillBytes() throws {
        try roundTrip(skillRules: true, installed: false, transformations: true, fastForward: true)
    }

    private func roundTrip(skillRules: Bool, installed: Bool, transformations: Bool = false,
                           fastForward: Bool = false) throws {
        let remote = base + "/remote.git"
        let gitA = try userGit("A", remote: remote, skillRules: skillRules)
        let gitB = try userGit("B", remote: remote, skillRules: skillRules)
        try seedRemote(git: gitA, remote: remote)
        let storeA = base + "/storeA"
        try gitA.clone(remote: remoteURL, into: storeA, credential: nil)
        let contextA = try makeContext()
        if installed {
            try installSkill(git: gitA, store: storeA, remote: remote, context: contextA)
        } else {
            try writeSkill(at: storeA + "/skills/bytes", skillRules: skillRules, transformations: transformations)
            let row = Skill(name: "Bytes", skillDescription: "Byte fixture", directoryName: "bytes",
                            importedFrom: "claudeCode")
            contextA.insert(row)
            // Authored skills share the same store operations, independently of import provenance.
            try files.writeFile(at: storeA + "/skills/authored/SKILL.md",
                content: "---\nname: Authored\ndescription: Authored fixture\n---\noriginal\n")
            contextA.insert(Skill(name: "Authored", skillDescription: "Authored fixture", directoryName: "authored"))
            try contextA.save()
        }
        let expected = try inventory(at: storeA + "/skills")
        try files.writeFile(at: storeA + "/.DS_Store", content: "Finder metadata")
        try files.writeFile(at: storeA + "/skills/bytes/.DS_Store", content: "Finder metadata")
        let installer = installService(git: gitA, store: storeA)
        let beforeHash = try installer.stableContentHash(at: storeA + "/skills/bytes")
        XCTAssertEqual(try engine(git: gitA).sync(root: storeA, message: "A bytes", credential: nil,
            context: contextA), .synced(pushed: true, warnings: []))
        XCTAssertEqual(try installer.stableContentHash(at: storeA + "/skills/bytes"), beforeHash)
        try assertRemoteBytes(expected, git: gitA, remote: remote)
        XCTAssertEqual(try gitA.runData(["--git-dir", remote, "show", "main:manifest/manifest.yaml"], in: nil)
            .stdout, try files.readData(at: storeA + "/manifest/manifest.yaml"),
            "Global excludes must not hide the manifest")

        let storeB = base + "/storeB"
        try gitB.clone(remote: remoteURL, into: storeB, credential: nil)
        XCTAssertEqual(try inventory(at: storeB + "/skills"), expected, "Fresh checkout changed skill bytes")
        XCTAssertTrue(files.isUserExecutableFile(at: storeB + "/skills/bytes/scripts/run.sh"))
        let contextB = try makeContext()
        let rebuild = StoreRebuildService().rebuild(fromRoot: storeB, context: contextB)
        XCTAssertFalse(rebuild.storeUnreadable)
        XCTAssertTrue(try contextB.fetch(FetchDescriptor<Skill>()).contains { $0.directoryName == "bytes" })
        _ = try engine(git: gitB).sync(root: storeB, message: "B sync-in", credential: nil, context: contextB)
        XCTAssertEqual(try inventory(at: storeB + "/skills"), expected)

        if fastForward { try assertExistingStorePull(gitA: gitA, gitB: gitB, context: contextA) }
        try assertRewrittenTransport()
    }

    private func assertRewrittenTransport() throws {
        // Both actual network operations must reach the helper through the rewrite.
        for user in ["A", "B"] {
            let transport = try files.readFile(at: base + "/" + user + "/transport")
            XCTAssertTrue(transport.contains("git-upload-pack"))
            XCTAssertTrue(transport.contains("git-receive-pack"))
        }
    }

    private func engine(git: GitService) -> SyncEngine {
        SyncEngine(gitService: git, lockPath: base + "/sync.lock")
    }

    private func seedRemote(git: GitService, remote: String) throws {
        try git.runOrThrow(["init", "--bare", "--initial-branch=main", remote], in: nil)
        let seed = base + "/seed"
        try files.createDirectory(at: seed)
        try git.initRepository(at: seed)
        try files.writeFile(at: seed + "/.gitignore", content: ".DS_Store\n")
        try files.writeFile(at: seed + "/.gitattributes", content: "manifest/categories/*.yaml merge=union\n")
        try ManifestService().write(ManifestSnapshot(schemaVersion: ManifestService.currentSchemaVersion,
            categories: [], projects: [], skills: []), toRoot: seed)
        try git.stageAllAndCommit(at: seed, message: "seed")
        try git.setRemote(remoteURL, at: seed)
        try git.push(at: seed, credential: nil)
    }

    private func assertExistingStorePull(gitA: GitService, gitB: GitService, context: ModelContext) throws {
        let storeA = base + "/storeA"
        let storeB = base + "/storeB"
        let script = "/skills/bytes/scripts/run.sh"
        try files.writeFile(at: storeA + script, content: "#!/bin/sh\necho changed\n")
        _ = try engine(git: gitA).sync(root: storeA, message: "A changes script", credential: nil, context: context)
        // A checkout made by an older build has no local override. Its bytes still define its state.
        try files.deleteFile(at: storeB + "/.git/info/attributes")
        // Invalidate git's cached stat without changing bytes, so status must examine conversions.
        for name in ["identity.id", "content.filtered", "content.utf16"] {
            try files.touchRegularFile(at: storeB + "/skills/bytes/references/" + name,
                date: Date(timeIntervalSince1970: 2_000_000_000))
        }
        XCTAssertTrue(gitB.isWorktreeClean(at: storeB), "Settings alone cannot make the old store dirty")
        try files.writeFile(at: storeB + "/skills/bytes/assets/ignored.bin", content: "untracked skill bytes")
        XCTAssertFalse(gitB.isWorktreeClean(at: storeB), "Skill ignores cannot hide pending store changes")
        try files.deleteFile(at: storeB + "/skills/bytes/assets/ignored.bin")
        guard case .fastForwarded = try gitB.fastForwardOnly(at: storeB, credential: nil) else {
            return XCTFail("Expected fast-forward")
        }
        XCTAssertEqual(try files.readData(at: storeB + script), try files.readData(at: storeA + script))
    }

    private func assertRemoteBytes(_ expected: [String: Data], git: GitService, remote: String) throws {
        for (path, bytes) in expected {
            let blob = try git.runData(["--git-dir", remote, "show", "main:skills/" + path], in: nil)
            XCTAssertEqual(blob.exit, 0, "Remote lost \(path)")
            XCTAssertEqual(blob.stdout, bytes, "Staging changed \(path)")
        }
        let tree = try git.runOrThrow(["--git-dir", remote, "ls-tree", "-r", "--name-only", "main"], in: nil)
        XCTAssertFalse(tree.stdout.contains(".DS_Store"))
    }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(for: Skill.self, Project.self, Pensieve.Category.self,
            MachineDeployIntent.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private func userGit(_ name: String, remote: String, skillRules: Bool) throws -> GitService {
        let home = base + "/" + name
        let helpers = home + "/helpers"
        try files.createDirectory(at: home)
        try files.writeExecutableFile(at: helpers + "/git-remote-https", content: """
            #!/usr/bin/env python3
            import os, sys
            if sys.argv[2] != 'https://transport.test/store.git':
                sys.exit('fixture URL rewrite did not apply')
            for line in sys.stdin:
                command = line.strip()
                if command == 'capabilities':
                    print('connect\\n', flush=True)
                elif command.startswith('connect '):
                    operation = command.split()[1]
                    with open('\(home)/transport', 'a') as trace:
                        trace.write(operation + '\\n')
                    print('', flush=True)
                    os.execv('/usr/bin/git', ['git', operation.removeprefix('git-'), '\(remote)'])
                elif command.startswith('option '):
                    print('unsupported', flush=True)
            """ + "\n")
        let executable = home + "/git"
        try files.writeExecutableFile(at: executable, content: """
            #!/bin/sh
            export HOME='\(home)'
            export XDG_CONFIG_HOME='\(home)/.config'
            export GIT_EXEC_PATH='\(helpers)'
            exec /usr/bin/git "$@"
            """ + "\n")
        let git = GitService(askpassHelperPath: home + "/askpass", executablePath: executable)
        let config = home + "/.gitconfig"
        for (key, value) in [
            ("url.https://transport.test/.insteadOf", "https://github.com/fixture/"),
            ("core.autocrlf", "true"), ("core.eol", "crlf"),
            ("core.excludesFile", home + "/ignore"), ("core.attributesFile", home + "/attributes"),
            ("filter.bytechange.clean", "sed s/original/CLEAN/g"),
            ("filter.bytechange.smudge", "sed s/CLEAN/SMUDGED/g"), ("filter.bytechange.required", "true")
        ] {
            try git.runOrThrow(["config", "--file", config, key, value], in: nil)
        }
        try files.writeFile(at: home + "/ignore", content: skillRules ? "" : "*.bin\nmanifest/\n")
        try files.writeFile(at: home + "/attributes", content: skillRules ? "" : attributeRules)
        return git
    }

    private var attributeRules: String {
        "*.sh text eol=crlf\n*.id ident\n*.filtered filter=bytechange\n*.utf16 working-tree-encoding=UTF-16LE\n"
    }

    private func writeSkill(at directory: String, skillRules: Bool, transformations: Bool) throws {
        var content = [
            "SKILL.md": Data("---\nname: Bytes\ndescription: Byte fixture\n---\noriginal\n".utf8),
            "scripts/run.sh": Data("#!/bin/sh\necho original\n".utf8),
            "assets/payload.bin": Data([0, 255, 128, 10, 13]),
            "references/crlf.txt": Data("original\r\nsecond\r\n".utf8),
            "references/path[1]\nfile.txt": Data("literal path\n".utf8)
        ]
        if skillRules {
            content[".gitignore"] = Data("assets/\nreferences/\n".utf8)
            content[".gitattributes"] = Data(attributeRules.utf8)
            content["scripts/.gitattributes"] = Data("*.sh text eol=crlf\n".utf8)
        }
        if transformations {
            content["references/identity.id"] = Data("$Id: original-id $\n".utf8)
            content["references/content.filtered"] = Data("original filter bytes\n".utf8)
            content["references/content.utf16"] = Data([0x6F, 0, 0x0A, 0])
        }
        for (path, bytes) in content { try files.writeData(at: directory + "/" + path, data: bytes) }
        try files.writeExecutableFile(at: directory + "/scripts/run.sh", content: "#!/bin/sh\necho original\n")
    }

    private func installService(git: GitService, store: String) -> SkillInstallService {
        SkillInstallService(gitService: git, credentialStore: InMemoryCredentialStore(),
            scratchRoot: base + "/install-scratch", storeRoot: store, lockPath: base + "/sync.lock")
    }

    private func installSkill(git: GitService, store: String, remote: String, context: ModelContext) throws {
        let upstream = base + "/upstream"
        try files.createDirectory(at: upstream)
        try git.initRepository(at: upstream)
        try writeSkill(at: upstream + "/skills/bytes", skillRules: true, transformations: false)
        // Upstream publishes ignored assets too. Its repository has no relation to the sync remote.
        try git.runOrThrow(["-C", upstream, "add", "--force", "."], in: nil)
        try git.runOrThrow(["-C", upstream, "commit", "-m", "upstream skill"], in: nil)
        let installRemote = base + "/upstream.git"
        try git.runOrThrow(["clone", "--bare", upstream, installRemote], in: nil)
        // The test helper's sole destination changes only during install, then returns to sync.
        let helper = base + "/A/helpers/git-remote-https"
        let original = try files.readFile(at: helper)
        try files.writeExecutableFile(at: helper, content: original.replacingOccurrences(of: remote, with: installRemote))
        defer { try? files.writeExecutableFile(at: helper, content: original) }
        let installer = installService(git: git, store: store)
        let source = try installer.fetch(repo: remoteURL, ref: "main", credential: nil)
        XCTAssertEqual(try installer.install(candidate: XCTUnwrap(source.candidates.first), from: source,
            context: context), .installed(slug: "bytes"))
        XCTAssertNotNil(try context.fetch(FetchDescriptor<Skill>()).first?.installedOrigin)
    }

    private func inventory(at directory: String) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for entry in try files.listDirectory(at: directory) {
            let path = directory + "/" + entry
            if files.directoryExists(at: path) {
                for (child, bytes) in try inventory(at: path) { result[entry + "/" + child] = bytes }
            } else {
                result[entry] = try files.readData(at: path)
            }
        }
        return result
    }
}
