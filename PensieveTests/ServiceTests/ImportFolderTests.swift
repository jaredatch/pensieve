import AppKit
import Darwin
import SwiftData
import SwiftUI
import XCTest
@testable import Pensieve

@MainActor
final class ImportFolderTests: XCTestCase {
    var root = ""
    let files = FileService()
    var store: String { root + "/store" }
    var sources: String { root + "/sources" }
    let body = "---\nname: Folder\ndescription: Description\nlicense: MIT\n---\n\nBody\n"

    override func setUpWithError() throws {
        root = TestTemporaryDirectory.path + "ImportFolder-" + UUID().uuidString
        try files.createDirectory(at: root)
    }

    override func tearDownWithError() throws { try files.deleteDirectory(at: root) }

    func model(using service: FileServiceProtocol? = nil) -> ImportViewModel {
        ImportViewModel(scanner: ImportScanner(fileService: files, claudeSkillsDir: sources,
            grokSkillsDir: root + "/grok", cursorRulesDir: root + "/cursor", codexSkillsDir: root + "/codex",
            storeRoot: store), skillStore: SkillStore(fileService: service ?? files, baseDir: store + "/skills",
            storeRoot: store), lockPath: root + "/sync.lock", manifestService: ManifestService(fileService: files),
            manifestRoot: store)
    }

    func context() throws -> ModelContext {
        ModelContext(try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    func source(_ name: String, text: String? = nil) throws -> String {
        let path = sources + "/" + name
        try files.writeFile(at: path + "/SKILL.md", content: text ?? body.replacingOccurrences(of: "Folder", with: name))
        return path
    }

    func assertNoTemps(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(try files.listDirectory(at: root).contains { $0.hasPrefix("store.vendor-") }, file: file, line: line)
    }

    func assertRendered(_ notices: [String], model: ImportViewModel, uniqueFailure: String? = nil) async throws {
        let host = NSHostingView(rootView: AnyView(ImportDoneView(importVM: model, onDone: {}).frame(width: 600)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        await TestWait.until(failureMessage: "Done must render the skill's skipped paths and reasons") {
            let strings = RenderedViewTestSupport.values(in: host).compactMap { $0 as? Text }
                .flatMap { RenderedViewTestSupport.strings(in: $0) }
            return notices.allSatisfy(strings.contains)
        }
        if let uniqueFailure {
            let rows = RenderedViewTestSupport.values(in: host).compactMap { $0 as? Text }
                .filter { RenderedViewTestSupport.strings(in: $0).contains { $0.contains(uniqueFailure) } }
            XCTAssertEqual(rows.count, 1, "A skill failure must appear only once in the rendered done step")
        }
    }

    func testImportAndFreshSyncCheckoutPreserveNestedBytesModesAndPreparedSkill() throws {
        let source = try source("Folder", text: "\u{FEFF}" + body)
        let expected: [String: Data] = [
            "SKILL.md": Data(body.utf8), "scripts/run.sh": Data("#!/bin/sh\necho folder\n".utf8),
            "references/nested/guide.md": Data("Guide\r\n".utf8), "assets/payload.bin": Data([0, 255, 128, 65])
        ]
        for (path, bytes) in expected where path != "SKILL.md" { try files.writeData(at: source + "/" + path, data: bytes) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source + "/scripts/run.sh")
        try files.createDirectory(at: source + "/references/empty")
        let model = model()
        XCTAssertEqual(model.scanFolder(source), .found(1))
        let context = try context()
        model.importSelected(context: context)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.importedSkillCount, 1)
        let imported = store + "/skills/folder"
        for (path, bytes) in expected {
            XCTAssertEqual(try files.readData(at: imported + "/" + path), bytes, path)
            XCTAssertEqual(try executableBits(at: imported + "/" + path), try executableBits(at: source + "/" + path))
        }
        XCTAssertTrue(files.directoryExists(at: imported + "/references/empty"))
        XCTAssertTrue(files.isUserExecutableFile(at: imported + "/scripts/run.sh"))
        XCTAssertFalse(files.isUserExecutableFile(at: imported + "/assets/payload.bin"))
        try assertFreshCheckout(expected: expected, slug: "folder", context: context)
        try assertNoTemps()
        try assertCaseCollisionsFailWithoutReplacingFiles()
    }

    func assertFreshCheckout(expected: [String: Data], slug: String, context: ModelContext) throws {
        let git = GitService(askpassHelperPath: root + "/askpass")
        let remote = root + "/remote.git"
        try git.runOrThrow(["init", "--bare", "--initial-branch=main", remote], in: nil)
        try git.initRepository(at: store)
        try git.runOrThrow(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.com",
                           "commit", "--allow-empty", "-m", "initial"], in: store)
        try git.setRemote(remote, at: store)
        try git.push(at: store, credential: nil)
        let engine = SyncEngine(gitService: AllowlistedRemoteGit(wrapping: git), lockPath: root + "/sync.lock")
        XCTAssertEqual(try engine.sync(root: store, message: "import folder", credential: nil, context: context),
                       .synced(pushed: true, warnings: []))
        let fresh = root + "/fresh"
        try git.clone(remote: remote, into: fresh, credential: nil)
        for (path, bytes) in expected {
            XCTAssertEqual(try files.readData(at: fresh + "/skills/" + slug + "/" + path), bytes, path)
            XCTAssertEqual(try executableBits(at: fresh + "/skills/" + slug + "/" + path),
                           try executableBits(at: store + "/skills/" + slug + "/" + path), path)
        }
        let rebuilt = try self.context()
        let result = StoreRebuildService(fileService: files, manifestService: ManifestService(fileService: files))
            .rebuild(fromRoot: fresh, context: rebuilt)
        XCTAssertFalse(result.storeUnreadable)
        XCTAssertTrue(try rebuilt.fetch(FetchDescriptor<Skill>()).contains { $0.directoryName == slug })
    }

    private func executableBits(at path: String) throws -> mode_t {
        var status = stat()
        guard lstat(path, &status) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return status.st_mode & 0o111
    }

    func testDotEntriesAtBothDepthsAreExcludedFromImportRemoteAndRenderedDone() async throws {
        let originalRoot = root
        defer { root = originalRoot }
        // A file and a directory cannot share .env's path; exercise both shapes at both depths.
        for envDirectory in [false, true] {
            root = originalRoot + (envDirectory ? "/directories" : "/files")
            let source = try source("Hidden")
            let skipped = try makeImportExclusions(at: source, envDirectory: envDirectory)
            try addLargeDependencyTrees(at: source)
            var expected = try addEnvironmentTemplates(at: source)
            expected["SKILL.md"] = Data(body.replacingOccurrences(of: "Folder", with: "Hidden").utf8)
            expected["assets/payload.bin"] = Data([255, 0, 42])
            expected["assets/node_modules"] = Data("a regular file is retained".utf8)
            expected["references/guide"] = Data("included".utf8)
            for (path, data) in expected where path != "SKILL.md" {
                try files.writeData(at: source + "/" + path, data: data)
            }
            let model = model()
            XCTAssertEqual(model.scanFolder(source), .found(1))
            let context = try context()
            model.importSelected(context: context)
            XCTAssertNil(model.error)
            XCTAssertEqual(model.importedSkillCount, 1)
            for (path, data) in expected {
                XCTAssertEqual(try files.readData(at: store + "/skills/hidden/" + path), data, path)
            }
            let groups = Dictionary(grouping: skipped.keys, by: { skipped[$0]! })
            let notices = groups.map { "Hidden: \($0.key): \($0.value.sorted().joined(separator: ", "))" }
            XCTAssertEqual(model.importNotices.count, 2, "Hidden and sync exclusions each get one line")
            XCTAssertEqual(Set(model.importNotices), Set(notices))
            try await assertRendered(notices, model: model)
            try assertFreshCheckout(expected: expected, slug: "hidden", context: context)
            for path in skipped.keys {
                XCTAssertNil(try files.entryTypeWithoutFollowingLinks(at: store + "/skills/hidden/" + path))
                XCTAssertNil(try files.entryTypeWithoutFollowingLinks(at: root + "/fresh/skills/hidden/" + path))
            }
            try assertNoTemps()
        }
    }

    func addEnvironmentTemplates(at source: String) throws -> [String: Data] {
        var expected: [String: Data] = [:]
        for prefix in ["", "references/"] {
            for name in [".env.example", ".env.sample", ".env.template"] {
                let path = prefix + name
                let bytes = Data(("template: " + path + "\r\n").utf8)
                try files.writeData(at: source + "/" + path, data: bytes)
                expected[path] = bytes
            }
        }
        return expected
    }

    func addLargeDependencyTrees(at source: String) throws {
        for prefix in ["", "references/"] {
            let dependencies = source + "/" + prefix + "node_modules"
            for index in 0..<1_001 { try files.writeFile(at: dependencies + "/entry-\(index)", content: "") }
            try sparseFile(at: dependencies + "/large", size: 65 * 1_024 * 1_024)
        }
    }

    private func makeImportExclusions(at source: String, envDirectory: Bool) throws -> [String: String] {
        var skipped: [String: String] = [:]
        for path in [".gitignore", ".gitattributes", "references/.git"] {
            try files.writeFile(at: source + "/" + path, content: path == ".gitignore" ? "assets/\n" : "excluded")
            skipped[path] = "Hidden items left out"
        }
        for path in [".git", "references/.private"] {
            try files.writeFile(at: source + "/" + path + "/ignored", content: "excluded subtree")
            skipped[path] = "Hidden items left out"
        }
        for prefix in ["", "references/"] {
            let env = prefix + ".env"
            try files.writeFile(at: source + "/" + env + (envDirectory ? "/ignored" : ""), content: "excluded")
            skipped[env] = "Left out because Pensieve doesn't sync them"
            for name in [".env.local", ".env.example.local", ".DS_Store"] {
                let path = prefix + name
                try files.writeFile(at: source + "/" + path, content: "excluded")
                skipped[path] = name == ".DS_Store" ? "Hidden items left out" : "Left out because Pensieve doesn't sync them"
            }
            for name in [".venv", "node_modules"] {
                let path = prefix + name
                try files.writeFile(at: source + "/" + path + "/ignored", content: "excluded subtree")
                skipped[path] = "Left out because Pensieve doesn't sync them"
            }
        }
        return skipped
    }
}
