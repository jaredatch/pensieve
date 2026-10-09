import SwiftData
import XCTest
@testable import Pensieve

/// Real divergent clones and sync inspection. No network or scripted conflict receipts.
@MainActor
struct SyncConflictByteFixture {
    enum Entry {
        case file(Data)
        case executable(Data)
        case symlink(String)
        case gitlink(String)
        case deleted
    }

    struct Payload {
        let name: String
        let this: Data
        let other: Data
        let drift: Data
    }

    static var payloads: [Payload] {
        [.init(name: "binary.bin", this: Data([0, 255, 128, 1]), other: Data([0, 254, 129, 2]),
               drift: Data([0, 253, 130, 3])),
         .init(name: "text.utf16", this: utf16("This Mac ☕"), other: utf16("Other Mac 😀"),
               drift: utf16("Remote drift 🔔"))]
    }

    let root: String
    let path: String
    let remote: String
    let storeA: String
    let storeB: String
    let contextA: ModelContext
    let contextB: ModelContext
    let git: GitService
    let engine: SyncEngine
    let files = FileService()

    init(name: String, this: Data?, other: Data?) throws {
        try self.init(name: name, initial: .file(Data([0, 255, 99])),
                      this: this.map(Entry.file) ?? .deleted, other: other.map(Entry.file) ?? .deleted)
    }

    init(name: String, initial: Entry, this: Entry, other: Entry) throws {
        root = TestTemporaryDirectory.path + "ConflictBytes-" + UUID().uuidString
        remote = root + "/remote.git"
        storeA = root + "/A"
        storeB = root + "/B"
        path = "skills/conflict/assets/" + name
        git = TestPaths.git
        engine = SyncEngine(gitService: AllowlistedRemoteGit(wrapping: git), lockPath: root + "/sync.lock")
        contextA = try Self.context()
        contextB = try Self.context()
        do {
            try files.createDirectory(at: root)
            try git.runOrThrow(["init", "--bare", "--initial-branch=main", remote], in: nil)
            let seed = root + "/seed"
            try files.createDirectory(at: seed)
            try git.initRepository(at: seed)
            try files.writeFile(at: seed + "/skills/conflict/SKILL.md",
                                content: "---\nname: Conflict\ndescription: Byte fixture\n---\nbody\n")
            try change(initial, at: seed)
            contextA.insert(Skill(name: "Conflict", skillDescription: "Byte fixture", directoryName: "conflict"))
            try contextA.save()
            let manifest = ManifestService()
            try manifest.write(manifest.snapshot(from: contextA), toRoot: seed)
            try git.stageAllAndCommit(at: seed, message: "base")
            try git.setRemote("file://" + remote, at: seed)
            try git.push(at: seed, credential: nil)
            try git.clone(remote: "file://" + remote, into: storeA, credential: nil)
            try git.clone(remote: "file://" + remote, into: storeB, credential: nil)
            XCTAssertFalse(StoreRebuildService().rebuild(fromRoot: storeB, context: contextB).storeUnreadable)
            try change(other, at: storeA)
            XCTAssertEqual(try engine.sync(root: storeA, message: "other changes", credential: nil,
                context: contextA), .synced(pushed: true, warnings: []))
            try change(this, at: storeB)
            XCTAssertEqual(try engine.sync(root: storeB, message: "this changes", credential: nil,
                context: contextB), .conflicted([path]))
            XCTAssertFalse(git.isRebaseInProgress(at: storeB))
        } catch {
            try? files.deleteDirectory(at: root)
            throw error
        }
    }

    func inspect() throws -> ConflictItem {
        let inspection = try engine.inspectConflicts(root: storeB, credential: nil, context: contextB)
        guard case let .conflicts(set) = inspection else {
            throw NSError(domain: "ConflictBytesFixture", code: 1)
        }
        XCTAssertEqual(set.items.map(\.path), [path])
        return try XCTUnwrap(set.items.first)
    }

    func change(_ bytes: Data?, at store: String) throws {
        try change(bytes.map(Entry.file) ?? .deleted, at: store)
    }

    func change(_ entry: Entry, at store: String) throws {
        let full = store + "/" + path
        switch entry {
        case let .file(bytes):
            try files.writeData(at: full, data: bytes)
        case let .executable(bytes):
            try files.writeExecutableFile(at: full, content: XCTUnwrap(String(bytes: bytes, encoding: .utf8)))
        case let .symlink(target):
            if try files.entryExistsWithoutFollowingLinks(at: full) { try files.deleteFile(at: full) }
            try files.createSymlink(at: full, pointingTo: target)
        case let .gitlink(object):
            try files.createDirectory(at: full)
            try git.runOrThrow(["-C", store, "update-index", "--add", "--cacheinfo", "160000," + object + "," + path], in: nil)
        case .deleted:
            if files.directoryExists(at: full) { try files.deleteDirectory(at: full) } else { try files.deleteFile(at: full) }
        }
    }

    static func gitlinkConflict(both: Bool = false) throws -> Self {
        let root = TestTemporaryDirectory.path + "GitlinkSource-" + UUID().uuidString
        let files = FileService()
        let git = TestPaths.git
        try files.createDirectory(at: root)
        defer { try? files.deleteDirectory(at: root) }
        try git.initRepository(at: root)
        try files.writeFile(at: root + "/source.txt", content: "first nested commit\n")
        try git.stageAllAndCommit(at: root, message: "first nested commit")
        let first = try git.commitSHA(at: root)
        try files.writeFile(at: root + "/source.txt", content: "second nested commit\n")
        try git.stageAllAndCommit(at: root, message: "second nested commit")
        let second = try git.commitSHA(at: root)
        try files.writeFile(at: root + "/source.txt", content: "third nested commit\n")
        try git.stageAllAndCommit(at: root, message: "third nested commit")
        let third = try git.commitSHA(at: root)
        return try Self(name: "legacy-link", initial: .gitlink(first), this: .gitlink(second),
                        other: both ? .gitlink(third) : .deleted)
    }

    func assertPublished(_ expected: Data?, line: UInt = #line) throws {
        let blob = try git.runData(["--git-dir", remote, "show", "main:" + path], in: nil)
        if let expected {
            XCTAssertEqual(blob.exit, 0, line: line)
            XCTAssertEqual(blob.stdout, expected, line: line)
        } else { XCTAssertNotEqual(blob.exit, 0, line: line) }
        let fresh = root + "/fresh-" + UUID().uuidString
        try git.clone(remote: "file://" + remote, into: fresh, credential: nil)
        for store in [storeB, fresh] {
            if let expected {
                XCTAssertEqual(try files.readData(at: store + "/" + path), expected, line: line)
            } else {
                XCTAssertFalse(files.fileExists(at: store + "/" + path), line: line)
            }
        }
    }

    private static func context() throws -> ModelContext {
        let container = try ModelContainer(for: Skill.self, Project.self, Pensieve.Category.self,
            MachineDeployIntent.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private static func utf16(_ text: String) -> Data {
        Data([0xFF, 0xFE] + text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
    }
}
