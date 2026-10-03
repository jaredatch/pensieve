import XCTest
@testable import Pensieve

/// Decorator over a real `FileService` that throws on the Nth `writeFile` call (and records every write
/// path), used to induce a mid-write failure and to inspect where the atomic manifest write builds
/// its temp tree — proving a partial build never lands inside the git-synced store root.
private final class FailOnNthWriteFileService: FileServiceProtocol {
    struct InducedFailure: Error {}
    private let wrapped: FileService
    private let failOnWrite: Int
    private var writeCount = 0
    private(set) var capturedWritePaths: [String] = []
    init(wrapped: FileService, failOnWrite: Int) {
        self.wrapped = wrapped
        self.failOnWrite = failOnWrite
    }
    func writeFile(at path: String, content: String) throws {
        writeCount += 1
        capturedWritePaths.append(path)
        if writeCount == failOnWrite { throw InducedFailure() }
        try wrapped.writeFile(at: path, content: content)
    }
    func readFile(at path: String) throws -> String { try wrapped.readFile(at: path) }
    func deleteFile(at path: String) throws { try wrapped.deleteFile(at: path) }
    func fileExists(at path: String) -> Bool { wrapped.fileExists(at: path) }
    func isExecutableFile(at path: String) -> Bool { wrapped.isExecutableFile(at: path) }
    func directoryExists(at path: String) -> Bool { wrapped.directoryExists(at: path) }
    func createDirectory(at path: String) throws { try wrapped.createDirectory(at: path) }
    func deleteDirectory(at path: String) throws { try wrapped.deleteDirectory(at: path) }
    func createSymlink(at linkPath: String, pointingTo targetPath: String) throws {
        try wrapped.createSymlink(at: linkPath, pointingTo: targetPath)
    }
    func symlinkTarget(at path: String) throws -> String { try wrapped.symlinkTarget(at: path) }
    func isSymlink(at path: String) -> Bool { wrapped.isSymlink(at: path) }
    func listDirectory(at path: String) throws -> [String] { try wrapped.listDirectory(at: path) }
    func contentsHash(at path: String) throws -> String { try wrapped.contentsHash(at: path) }
}

/// PLAN-12 / 12.3 — the atomic manifest write: build a temp tree, then swap it in.
final class ManifestAtomicWriteTests: XCTestCase {
    private var tempDir: String!
    private var fileService: FileService!
    private var service: ManifestService!

    override func setUpWithError() throws {
        tempDir = NSTemporaryDirectory() + "PensieveManifestAtomic-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        fileService = FileService()
        service = ManifestService(fileService: fileService)
    }

    override func tearDownWithError() throws {
        for path in [tempDir!, tempDir! + ".manifest-build.tmp"] where FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
    }

    // A write that fails PART-WAY must leave the previous manifest byte-for-byte intact — the new tree is
    // built in a temp dir and only swapped in at the very end, so a half-written manifest is never observable.
    func testFailedWriteLeavesPreviousManifestIntact() throws {
        let v1 = ManifestSnapshot(
            schemaVersion: 1,
            categories: [CategoryRecord(name: "Keep-A", projectKeys: [], skillSlugs: ["s1"]),
                         CategoryRecord(name: "Keep-B", projectKeys: [], skillSlugs: [])],

            projects: [], skills: [])
        try service.write(v1, toRoot: tempDir)
        XCTAssertEqual(Set(try service.read(fromRoot: tempDir).categories.map { $0.name }), ["Keep-A", "Keep-B"])

        // v2 would REPLACE the categories with just "Gone", but its write fails on the 2nd file (the "Gone"
        // overlay), so the temp tree is partial and the swap never happens.
        let faulty = FailOnNthWriteFileService(wrapped: fileService, failOnWrite: 2)
        let v2 = ManifestSnapshot(
            schemaVersion: 1,
            categories: [CategoryRecord(name: "Gone", projectKeys: [], skillSlugs: [])],

            projects: [], skills: [])
        XCTAssertThrowsError(try ManifestService(fileService: faulty).write(v2, toRoot: tempDir))

        // The LIVE manifest is still v1 — the failed write never touched it. Under the old in-place write this
        // would have pruned Keep-A/Keep-B before failing, leaving an empty/partial tree.
        XCTAssertEqual(Set(try service.read(fromRoot: tempDir).categories.map { $0.name }), ["Keep-A", "Keep-B"])
    }

    // The manifest is built in a temp OUTSIDE the git-synced store root, so a partial temp left by a failed or
    // crashed write can never be staged by the sync setup's `git add -A` and pushed. Every file the write
    // touches while building goes to that sibling temp; only the final atomic swap (a rename, not a write)
    // lands inside `manifest/`.
    func testManifestBuildTempLivesOutsideStoreRoot() throws {
        let capturing = FailOnNthWriteFileService(wrapped: fileService, failOnWrite: 99)   // never fail; just capture
        try ManifestService(fileService: capturing).write(sampleAtomicSnapshot(), toRoot: tempDir)
        let insideRoot = capturing.capturedWritePaths.filter { $0.hasPrefix(tempDir + "/") }
        XCTAssertTrue(insideRoot.isEmpty,
                      "manifest build writes must target a temp OUTSIDE the store root; leaked inside: \(insideRoot)")
    }

    // A first-ever manifest write on a FRESH store must BOOTSTRAP the store root: the temp is built outside
    // `root`, so the swap's move into `root/manifest` would fail with a missing parent unless `write` creates
    // `root` first. (The other tests' setUp pre-creates the root, which hid this on-fresh-store path.)
    func testWriteBootstrapsFreshStoreRoot() throws {
        let freshRoot = tempDir + "/does-not-exist-yet"   // NOT created
        XCTAssertFalse(fileService.directoryExists(at: freshRoot))
        try service.write(sampleAtomicSnapshot(), toRoot: freshRoot)
        let read = try service.read(fromRoot: freshRoot)
        XCTAssertEqual(read.categories.map { $0.name }, ["Swift"])
        XCTAssertEqual(read.skills.map { $0.slug }, ["swift-style"])
    }

    // Each write builds in its OWN uniquely-named temp tree, so two concurrent writers for the same store
    // (a GUI mutation while sync/the daemon also snapshots) can't delete or write into each other's temp and
    // publish a mixed/partial swap. Proven by the observable property: distinct temp paths across writes.
    func testEachWriteUsesADistinctTempTree() throws {
        let a = FailOnNthWriteFileService(wrapped: fileService, failOnWrite: 99)
        let b = FailOnNthWriteFileService(wrapped: fileService, failOnWrite: 99)
        try ManifestService(fileService: a).write(sampleAtomicSnapshot(), toRoot: tempDir)
        try ManifestService(fileService: b).write(sampleAtomicSnapshot(), toRoot: tempDir)
        let tempA = try XCTUnwrap(a.capturedWritePaths.first.map { ($0 as NSString).deletingLastPathComponent })
        let tempB = try XCTUnwrap(b.capturedWritePaths.first.map { ($0 as NSString).deletingLastPathComponent })
        XCTAssertNotEqual(tempA, tempB, "each manifest write must build in a distinct temp tree")
    }

    private func sampleAtomicSnapshot() -> ManifestSnapshot {
        ManifestSnapshot(
            schemaVersion: 1,
            categories: [CategoryRecord(name: "Swift", projectKeys: [], skillSlugs: ["swift-style"])],

            projects: [ProjectIdentityRecord(identityKey: "git:x", identityKind: "remote", name: "X")],
            skills: [SkillOverlay(slug: "swift-style", createdAt: Date(timeIntervalSince1970: 1),
                                  scope: .user, tags: ["t"], cursor: nil, agents: [], origin: .authored)])
    }
}
