import Foundation
import SwiftData
import XCTest
@testable import Pensieve

/// Runs real rebuild saves except while the selected fault is enabled. The category fault models
/// the explicit failed-fetch result; StoreRebuildServiceTests owns the actual fetch boundary.
final class IncompleteIngestRebuild: StoreRebuildServiceProtocol {
    var fails = false
    var failsCategories = false
    var failsListing = false
    var failWhenAddedCategoryExists = false
    private(set) var calls = 0

    func rebuild(fromRoot root: String, context: ModelContext) -> RebuildResult {
        calls += 1
        let shouldFail = fails || (failWhenAddedCategoryExists
            && ((try? ManifestService().read(fromRoot: root).categories.contains { $0.name == "Added" }) == true))
        if shouldFail && failsCategories { return RebuildResult(categoryReadFailed: true) }
        return StoreRebuildService(fileService: FaultyFileService(wrapped: FileService(),
            failListPath: shouldFail && failsListing ? root + "/skills" : nil), save: { context in
            if shouldFail && !self.failsListing { throw CocoaError(.fileWriteUnknown) }
            try context.save()
        }).rebuild(fromRoot: root, context: context)
    }
}

struct IncompleteIngestFixture {
    static let message = "Rebuilding the local store failed: "
        + "Rebuild computed changes but saving the local store failed: " + CocoaError(.fileWriteUnknown).localizedDescription
    static let categoryMessage = "Rebuilding the local store failed: Couldn't read this Mac's categories."
    let base: String
    let app: String
    let peer: String
    let remote: String
    let git = TestPaths.git
    let manifest = ManifestService()
    let files = FileService()

    init(base: String, includingSurvivor: Bool = false) throws {
        self.base = base
        app = base + "/app"
        peer = base + "/peer"
        let bare = base + "/remote.git"
        remote = "file://" + bare
        try files.createDirectory(at: base)
        _ = try ingestRawGit(["init", "--bare", "--initial-branch=main", bare])
        try files.createDirectory(at: peer)
        try git.initRepository(at: peer)
        try git.setRemote(remote, at: peer)
        try manifest.write(Self.snapshot(["Deleted", "Kept"]), toRoot: peer)
        try files.writeFile(at: peer + "/skills/item/SKILL.md",
                            content: "---\nname: Item\ndescription: Item\n---\nbody\n")
        if includingSurvivor {
            try files.writeFile(at: peer + "/skills/survivor/SKILL.md",
                                content: "---\nname: Survivor\ndescription: Survivor\n---\nkept body\n")
        }
        try StoreIgnoreRules.prepare(at: peer, files: files)
        _ = try git.stageAllAndCommit(at: peer, message: "seed")
        try git.push(at: peer, credential: nil)
        try git.clone(remote: remote, into: app, credential: nil)
    }

    static func snapshot(_ names: [String]) -> ManifestSnapshot {
        ManifestSnapshot(schemaVersion: ManifestService.currentSchemaVersion,
            categories: names.map { CategoryRecord(name: $0, projectKeys: [], skillSlugs: []) },
            projects: [], skills: [])
    }

    func changePeer(conflict: Bool = false) throws {
        try manifest.write(Self.snapshot(["Added", "Kept"]), toRoot: peer)
        if conflict {
            try files.writeFile(at: peer + "/skills/item/SKILL.md",
                                content: "---\nname: Item\ndescription: Item\n---\nother body\n")
        }
        _ = try git.stageAllAndCommit(at: peer, message: "peer categories")
        try git.push(at: peer, credential: nil)
    }

    func engine(rebuild: StoreRebuildServiceProtocol, manifestService: ManifestSnapshotting = ManifestService()) -> SyncEngine {
        SyncEngine(gitService: AllowlistedRemoteGit(wrapping: git), manifestService: manifestService,
                   storeRebuildService: rebuild,
                   lockPath: base + "/sync.lock")
    }

    func remoteHead() throws -> String { try ingestRawGit(["--git-dir", base + "/remote.git", "rev-parse", "main"]) }

    func assertRemoteCategories(file: StaticString = #filePath, line: UInt = #line) throws {
        try git.fetchBranch("main", at: peer, credential: nil)
        // Read the published tree, rather than the peer's possibly stale worktree or local DB.
        let paths = try ingestRawGit(["-C", peer, "ls-tree", "-r", "--name-only", "FETCH_HEAD", "manifest/categories"])
            .split(separator: "\n").map(String.init)
        let names = try paths.map { path -> String in
            let text = try ingestRawGit(["-C", peer, "show", "FETCH_HEAD:" + path])
            let record = try XCTUnwrap(try CheckedYAMLLoader.load(yaml: text) as? [String: Any])
            return try XCTUnwrap(record["name"] as? String)
        }
        XCTAssertEqual(names.sorted(), ["Added", "Kept"], file: file, line: line)
    }
}

/// Captures the real window snapshot at the write boundary while retaining native manifest I/O.
final class IncompleteSnapshotManifest: ManifestSnapshotting {
    func repair(_ snapshot: ManifestSnapshot, root: String, replacing damage: ManifestDamage) throws -> Bool {
        try manifest.repair(snapshot, root: root, replacing: damage)
    }
    private let manifest = ManifestService()
    private(set) var categoriesAtSnapshot: [[String]] = []
    func read(fromRoot root: String) throws -> ManifestSnapshot { try manifest.read(fromRoot: root) }
    func write(_ snapshot: ManifestSnapshot, toRoot root: String) throws { try manifest.write(snapshot, toRoot: root) }
    func snapshot(from context: ModelContext) throws -> ManifestSnapshot {
        let snapshot = try manifest.snapshot(from: context)
        categoriesAtSnapshot.append(snapshot.categories.map(\.name).sorted())
        return snapshot
    }
}

@MainActor
extension IncompleteIngestFixture {
    func queuedLibrary(manifestSaves: ManifestSaveModel? = nil) -> SkillLibraryViewModel {
        let saves = manifestSaves ?? ManifestSaveModel(manifest: manifest, root: app,
            lockPath: base + "/sync.lock", waitSeconds: 0.01)
        return SkillLibraryViewModel(skillStore: SkillStore(fileService: files, baseDir: app + "/skills", storeRoot: app),
            fileWatchService: RecordingWatcher(), manifestRoot: app, manifestSaves: saves)
    }
}
