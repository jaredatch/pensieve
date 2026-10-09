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
        case folder
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
    let expectedPaths: [String]
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

    init(name: String, initial: Entry, this: Entry, other: Entry, indexMerge: Bool = false) throws {
        root = TestTemporaryDirectory.path + "ConflictBytes-" + UUID().uuidString
        remote = root + "/remote.git"
        storeA = root + "/A"
        storeB = root + "/B"
        path = "skills/conflict/assets/" + name
        if case .folder = other { expectedPaths = [path, path + "/keep"] } else { expectedPaths = [path] }
        git = indexMerge ? GitService(askpassHelperPath: root + "/askpass", executablePath: root + "/index-merge-git")
            : TestPaths.git
        engine = SyncEngine(gitService: AllowlistedRemoteGit(wrapping: git), lockPath: root + "/sync.lock")
        contextA = try Self.context()
        contextB = try Self.context()
        do {
            try files.createDirectory(at: root)
            if indexMerge {
                try installIndexMergeGit()
            }
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
                context: contextB), .conflicted(expectedPaths))
            XCTAssertFalse(git.isRebaseInProgress(at: storeB))
        } catch {
            try? files.deleteDirectory(at: root)
            throw error
        }
    }

    private func installIndexMergeGit() throws {
        // read-tree supplies native unmerged stages for a file/gitlink type conflict without
        // merge-recursive's auxiliary filename. No mocked conflict list or side receipt.
        try files.writeExecutableFile(at: root + "/index-merge-git", content: """
            #!/bin/sh
            /usr/bin/git "$@"
            result=$?
            merge_index() {
                \(FakeGitScript.skipGlobalOptions)
                if [ "$1" = rebase ] && [ "$2" != --abort ] && [ "$2" != --continue ] && \
                   /usr/bin/git -C '\(storeB)' rev-parse --verify REBASE_HEAD >/dev/null 2>&1; then
                    base=$(/usr/bin/git -C '\(storeB)' merge-base HEAD REBASE_HEAD) || exit 1
                    /usr/bin/git -C '\(storeB)' read-tree --empty || exit 1
                    /usr/bin/git -C '\(storeB)' read-tree -m "$base" HEAD REBASE_HEAD || exit 1
                    rm -f '\(storeB)/\(path)'~*
                    # Place the preservation witness after native rebase, at resolution's
                    # boundary. Git's earlier ordinary-gitlink-folder loss is filed separately.
                    if [ -f '\(root)/resolution-marker' ] && [ -d '\(storeB)/\(path)' ]; then
                        cp '\(root)/resolution-marker' '\(storeB)/\(path)/keep' || exit 1
                    fi
                fi
            }
            merge_index "$@"
            exit "$result"
            """ + "\n")
    }

    func inspect() throws -> ConflictItem { try XCTUnwrap(inspectAll().first) }

    func inspectAll() throws -> [ConflictItem] {
        let inspection = try engine.inspectConflicts(root: storeB, credential: nil, context: contextB)
        guard case let .conflicts(set) = inspection else {
            throw NSError(domain: "ConflictBytesFixture", code: 1)
        }
        XCTAssertEqual(set.items.map(\.path), expectedPaths)
        return set.items
    }

    func change(_ bytes: Data?, at store: String) throws {
        try change(bytes.map(Entry.file) ?? .deleted, at: store)
    }

    func change(_ entry: Entry, at store: String) throws {
        let full = store + "/" + path
        switch entry {
        case let .file(bytes):
            try removeFolder(at: full)
            try files.writeData(at: full, data: bytes)
        case let .executable(bytes):
            try files.writeExecutableFile(at: full, content: XCTUnwrap(String(bytes: bytes, encoding: .utf8)))
        case let .symlink(target):
            try removeEntry(at: full)
            try files.createSymlink(at: full, pointingTo: target)
        case let .gitlink(object):
            if try files.entryTypeWithoutFollowingLinks(at: full) == .regular { try files.deleteFile(at: full) }
            try files.createDirectory(at: full)
            try git.runOrThrow(["-C", store, "update-index", "--add", "--cacheinfo", "160000," + object + "," + path], in: nil)
        case .folder:
            if try files.entryExistsWithoutFollowingLinks(at: full) { try files.deleteFile(at: full) }
            try files.writeFile(at: full + "/keep", content: "chosen folder bytes")
        case .deleted:
            if files.directoryExists(at: full) { try files.deleteDirectory(at: full) } else { try files.deleteFile(at: full) }
        }
    }

    private func removeFolder(at path: String) throws {
        if try files.entryTypeWithoutFollowingLinks(at: path) == .directory { try files.deleteDirectory(at: path) }
    }

    private func removeEntry(at path: String) throws {
        if try files.entryTypeWithoutFollowingLinks(at: path) == .directory {
            try files.deleteDirectory(at: path)
        } else if try files.entryExistsWithoutFollowingLinks(at: path) { try files.deleteFile(at: path) }
    }

    static func gitlinkConflict(both: Bool = false, otherEntry: Entry? = nil) throws -> Self {
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
                        other: otherEntry ?? (both ? .gitlink(third) : .deleted), indexMerge: otherEntry != nil)
    }

    func ignoreFaultEngine(_ kind: String) throws -> SyncEngine {
        let executable = root + "/ignore-fault-git"
        let ignore = storeB + "/.gitignore"
        try files.writeFile(at: root + "/outside-key", content: "outside sentinel")
        let change: String
        switch kind {
        case "binary": change = "printf '\\377\\376' > '\(ignore)'"
        case "link": change = "ln -s '\(root)/outside-key' '\(ignore)'"
        case "folder": change = "mkdir '\(ignore)'"
        case "fifo": change = "mkfifo '\(ignore)'"
        case "unreadable": change = "printf '*\\n' > '\(ignore)'; chmod 000 '\(ignore)'"
        default: change = ":"
        }
        try files.writeExecutableFile(at: executable, content: """
            #!/bin/sh
            /usr/bin/git "$@"
            result=$?
            replace_ignore() {
                \(FakeGitScript.skipGlobalOptions)
                if [ "$1" = rebase ] && [ "$2" != --abort ] && [ "$2" != --continue ] && \
                   /usr/bin/git -C '\(storeB)' rev-parse --verify REBASE_HEAD >/dev/null 2>&1; then
                    rm -f '\(ignore)'
                    \(change)
                fi
            }
            replace_ignore "$@"
            exit "$result"
            """ + "\n")
        let fault = GitService(askpassHelperPath: root + "/askpass", executablePath: executable)
        return SyncEngine(gitService: AllowlistedRemoteGit(wrapping: fault), lockPath: root + "/sync.lock")
    }

    /// Native rebase supplies the conflict; only its selected index object's identity is replaced
    /// with an absent blob. Both inspection and resolution still use GitService's real object reads.
    func missingObjectEngine(stage: Int) throws -> SyncEngine {
        let executable = root + "/missing-object-git"
        try files.writeExecutableFile(at: executable, content: """
            #!/bin/sh
            alter() {
                \(FakeGitScript.skipGlobalOptions)
                if [ "$1" = ls-files ] && [ "$2" = --stage ] && \
                   /usr/bin/git -C '\(storeB)' rev-parse --verify REBASE_HEAD >/dev/null 2>&1; then
                    printf '100644 1111111111111111111111111111111111111111 \(stage)\t\(path)\n' | \
                      /usr/bin/git -C '\(storeB)' update-index --index-info || exit 1
                fi
            }
            alter "$@"
            exec /usr/bin/git "$@"
            """ + "\n")
        let fault = GitService(askpassHelperPath: root + "/askpass", executablePath: executable)
        return SyncEngine(gitService: AllowlistedRemoteGit(wrapping: fault), lockPath: root + "/sync.lock")
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
