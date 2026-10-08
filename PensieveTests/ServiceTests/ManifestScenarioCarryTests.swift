import SwiftData
import XCTest
@testable import Pensieve

final class ManifestScenarioCarryTests: XCTestCase {
    var root: String!
    let files = FileService()
    var manifest: ManifestService { ManifestService(fileService: files) }
    var empty: ManifestSnapshot {
        ManifestSnapshot(schemaVersion: 5, categories: [], projects: [], skills: [])
    }

    override func setUpWithError() throws {
        root = TestTemporaryDirectory.path + "ManifestScenarioCarry-" + UUID().uuidString
        try files.createDirectory(at: root)
        try manifest.write(empty, toRoot: root)
    }

    override func tearDownWithError() throws { try files.deleteDirectory(at: root) }

    @MainActor
    func testTagsSurviveWriteAndRebuildWhileLegacyBytesStayIdentical() throws {
        let container = try AppRuntime.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let skill = Skill(name: "Skill", skillDescription: "Description", directoryName: "skill")
        context.insert(skill)
        try context.save()
        try files.createDirectory(at: root + "/skills/skill")
        try files.writeFile(at: root + "/skills/skill/SKILL.md", content: "---\nname: Skill\ndescription: Description\n---\nBody")
        let bytes = Data([0, 255, 10, 13, 42])
        try files.writeData(at: root + "/manifest/scenarios/legacy.yaml", data: bytes)
        skill.tags = ["changed"]

        try manifest.write(manifest.snapshot(from: context), toRoot: root)
        XCTAssertEqual(try manifest.read(fromRoot: root).skills.first?.tags, ["changed"])
        XCTAssertEqual(try files.readData(at: root + "/manifest/scenarios/legacy.yaml"), bytes)
        skill.tags = ["stale"]
        let result = StoreRebuildService(fileService: files, manifestService: manifest).rebuild(fromRoot: root, context: context)
        XCTAssertFalse(result.storeUnreadable)
        XCTAssertEqual(skill.tags, ["changed"])
        XCTAssertEqual(try files.readData(at: root + "/manifest/scenarios/legacy.yaml"), bytes)
    }

    func testMalformedYAMLAndNonYAMLEntriesAreCarriedWithoutReadingLinks() async throws {
        let outside = root + "/outside"
        try files.writeFile(at: outside, content: "secret")
        try files.writeFile(at: root + "/manifest/scenarios/broken.yaml", content: ":\n  - [\n")
        try files.writeData(at: root + "/manifest/scenarios/opaque.bin", data: Data([255, 0]))
        try files.createSymlink(at: root + "/manifest/scenarios/link.yaml", pointingTo: outside)
        try files.createDirectory(at: root + "/manifest/scenarios/nested")
        let guarded = ScenarioCarryFileService()
        guarded.forbiddenPrefixes = [outside, root + "/manifest/scenarios/link.yaml"]
        let service = ManifestService(fileService: guarded)

        XCTAssertNoThrow(try service.read(fromRoot: root))
        try service.write(empty, toRoot: root)
        XCTAssertEqual(Set(try files.listDirectory(at: root + "/manifest/scenarios")), ["broken.yaml", "opaque.bin"])
        XCTAssertEqual(try files.readFile(at: root + "/manifest/scenarios/broken.yaml"), ":\n  - [\n")
        XCTAssertEqual(try files.readData(at: root + "/manifest/scenarios/opaque.bin"), Data([255, 0]))
        XCTAssertFalse(guarded.touchedForbiddenPath)
        XCTAssertEqual(try files.readFile(at: outside), "secret")
        var changed = empty
        changed.categories = [CategoryRecord(name: "Cancelled writer", projectKeys: [], skillSlugs: [])]
        let snapshot = changed
        let root = try XCTUnwrap(root)
        let writer = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let cancelled = Task.isCancelled
            try service.write(snapshot, toRoot: root)
            return cancelled
        }
        let cancelled = try await writer.value
        XCTAssertTrue(cancelled, "The manifest write ran inside an already-cancelled task")
        XCTAssertEqual(try service.read(fromRoot: root).categories, changed.categories)
        XCTAssertEqual(try files.readData(at: root + "/manifest/scenarios/opaque.bin"), Data([255, 0]))
        XCTAssertEqual(try files.readFile(at: root + "/manifest/scenarios/broken.yaml"), ":\n  - [\n")
        XCTAssertFalse(guarded.touchedForbiddenPath)
    }

    func testSymlinkedScenarioDirectoryBecomesEmptyRealDirectory() throws {
        let outside = root + "/outside"
        try files.createDirectory(at: outside)
        try files.writeFile(at: outside + "/keep.yaml", content: "untouched")
        let before = files.regularFileMetadata(at: outside + "/keep.yaml")
        try files.deleteDirectory(at: root + "/manifest/scenarios")
        try files.createSymlink(at: root + "/manifest/scenarios", pointingTo: outside)
        let guarded = ScenarioCarryFileService()
        guarded.forbiddenPrefixes = [outside, root + "/manifest/scenarios"]
        try ManifestService(fileService: guarded).write(empty, toRoot: root)

        XCTAssertFalse(guarded.touchedForbiddenPath)
        XCTAssertFalse(files.isSymlink(at: root + "/manifest/scenarios"))
        XCTAssertTrue(try files.listDirectory(at: root + "/manifest/scenarios").isEmpty)
        XCTAssertEqual(try files.readFile(at: outside + "/keep.yaml"), "untouched")
        XCTAssertEqual(files.regularFileMetadata(at: outside + "/keep.yaml"), before)
    }

    func testAbsentAndNonDirectoryScenarioPathsBecomeEmptyFolders() throws {
        for isFile in [false, true] {
            try files.deleteDirectory(at: root + "/manifest/scenarios")
            if isFile { try files.writeFile(at: root + "/manifest/scenarios", content: "not a folder") }
            try manifest.write(empty, toRoot: root)
            XCTAssertTrue(files.directoryExists(at: root + "/manifest/scenarios"))
            XCTAssertTrue(try files.listDirectory(at: root + "/manifest/scenarios").isEmpty)
        }
    }

    func testListingFailurePreservesWholeManifestAndRetries() throws {
        try assertFailureRetries(listing: true)
    }

    func testPartialCopyFailurePreservesWholeManifestAndRetries() throws {
        try assertFailureRetries(listing: false)
    }

    func testDirectoryReplacementCannotRedirectScenarioCarryOutsideStore() throws {
        let source = root + "/manifest/scenarios"
        let outside = root + "/outside"
        try files.writeFile(at: source + "/legacy.yaml", content: "original")
        try files.writeFile(at: outside + "/secret.yaml", content: "outside")
        let guarded = ScenarioCarryFileService()
        var swaps = 0
        var swapError: Error?
        guarded.afterDirectoryCheck = {
            guard swaps == 0 else { return }
            swaps += 1
            do {
                try self.files.replaceItem(at: self.root + "/parked", with: source)
                try self.files.createSymlink(at: source, pointingTo: outside)
            } catch { swapError = error }
        }
        XCTAssertThrowsError(try ManifestService(fileService: guarded).write(empty, toRoot: root))
        XCTAssertNil(swapError)
        XCTAssertEqual(swaps, 1)
        XCTAssertTrue(files.isSymlink(at: source))
        XCTAssertEqual(try files.readFile(at: root + "/parked/legacy.yaml"), "original")
        XCTAssertEqual(try files.readFile(at: outside + "/secret.yaml"), "outside")
        try files.deleteFile(at: source)
        try files.replaceItem(at: source, with: root + "/parked")
        guarded.afterDirectoryCheck = nil
        try ManifestService(fileService: guarded).write(empty, toRoot: root)
        XCTAssertEqual(try files.listDirectory(at: source), ["legacy.yaml"])
        XCTAssertEqual(try files.readFile(at: source + "/legacy.yaml"), "original")
        XCTAssertEqual(try files.readFile(at: outside + "/secret.yaml"), "outside")
        XCTAssertFalse(files.fileExists(at: source + "/secret.yaml"))
    }

    @MainActor
    func testRebuildIgnoresLegacyDefinitionsWithoutChangingLocalScenarios() throws {
        let container = try AppRuntime.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let local = Scenario(name: "Local")
        context.insert(local)
        try context.save()
        let record = LegacyScenarioDefinition(id: UUID().uuidString, name: "Remote", skillSlugs: [], agents: [])
        try files.writeFile(at: root + "/manifest/scenarios/remote.yaml", content: LegacyScenarioDefinition.serialize(record))
        let result = StoreRebuildService(fileService: files, manifestService: manifest).rebuild(fromRoot: root, context: context)
        XCTAssertFalse(result.storeUnreadable)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Scenario>()).map(\.id), [local.id])
    }

    private func assertFailureRetries(listing: Bool) throws {
        try files.writeFile(at: root + "/manifest/scenarios/a.yaml", content: "first")
        try files.writeFile(at: root + "/manifest/scenarios/b.yaml", content: "second")
        let before = try treeBytes(at: root + "/manifest")
        let faulty = ScenarioCarryFileService()
        faulty.failListing = listing
        faulty.failCopyNumber = listing ? nil : 2
        var changed = empty
        changed.categories = [CategoryRecord(name: "New", projectKeys: [], skillSlugs: [])]
        XCTAssertThrowsError(try ManifestService(fileService: faulty).write(changed, toRoot: root))
        if !listing { XCTAssertEqual(faulty.copyCount, 2) }
        XCTAssertEqual(try treeBytes(at: root + "/manifest"), before)
        faulty.failListing = false
        faulty.failCopyNumber = nil
        try ManifestService(fileService: faulty).write(changed, toRoot: root)
        XCTAssertEqual(try manifest.read(fromRoot: root).categories, changed.categories)
        XCTAssertEqual(try files.readFile(at: root + "/manifest/scenarios/a.yaml"), "first")
        XCTAssertEqual(try files.readFile(at: root + "/manifest/scenarios/b.yaml"), "second")
    }

    func treeBytes(at directory: String) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for name in try files.listDirectory(at: directory) {
            let path = directory + "/" + name
            if files.directoryExists(at: path) {
                for (child, bytes) in try treeBytes(at: path) { result[name + "/" + child] = bytes }
            } else { result[name] = try files.readData(at: path) }
        }
        return result
    }
}

/// Wraps real temp-store I/O. Records forbidden reads, listings and copies; injects a listing
/// failure or an Nth-copy failure. Probes and writes are forwarded and are deliberately not fenced.
final class ScenarioCarryFileService: FileServiceProtocol {
    let wrapped = FileService()
    var forbiddenPrefixes: [String] = []
    var touchedForbiddenPath = false
    var failListing = false
    var failCopyNumber: Int?
    var copyCount = 0
    var afterDirectoryCheck: (() -> Void)?
    var checkpointAction: ((FileService.DirectoryCopyCheckpoint) throws -> Void)?
    var beforeSwap: (() throws -> Void)?
    private func record(_ path: String) {
        if forbiddenPrefixes.contains(where: path.hasPrefix) { touchedForbiddenPath = true }
    }
    func readFile(at path: String) throws -> String { record(path); return try wrapped.readFile(at: path) }
    func readData(at path: String) throws -> Data { record(path); return try wrapped.readData(at: path) }
    func copyFile(at sourcePath: String, to destinationPath: String) throws {
        record(sourcePath)
        copyCount += 1
        if copyCount == failCopyNumber { throw CocoaError(.fileReadUnknown) }
        try wrapped.copyFile(at: sourcePath, to: destinationPath)
    }
    func copyRegularFiles(fromDirectory source: String, toDirectory destination: String) throws -> RegularFileCopyReceipt {
        try wrapped.copyRegularFiles(fromDirectory: source, toDirectory: destination) { checkpoint in
            try checkpointAction?(checkpoint)
            switch checkpoint {
            case .opened:
                record(source)
                afterDirectoryCheck?()
                if failListing { throw CocoaError(.fileReadUnknown) }
            case .copying(let name):
                record(source + "/" + name)
                copyCount += 1
                if copyCount == failCopyNumber { throw CocoaError(.fileReadUnknown) }
            case .copiedChunk, .unavailable:
                break
            }
        }
    }
    func writeFile(at path: String, content: String) throws {
        try wrapped.writeFile(at: path, content: content)
        if path.hasSuffix("/projects.yaml") { try beforeSwap?() }
    }
    func deleteFile(at path: String) throws { try wrapped.deleteFile(at: path) }
    func fileExists(at path: String) -> Bool { wrapped.fileExists(at: path) }
    func isExecutableFile(at path: String) -> Bool { wrapped.isExecutableFile(at: path) }
    func directoryExists(at path: String) -> Bool {
        let exists = wrapped.directoryExists(at: path)
        if exists && path.hasSuffix("/manifest/scenarios") { afterDirectoryCheck?() }
        return exists
    }
    func createDirectory(at path: String) throws { try wrapped.createDirectory(at: path) }
    func deleteDirectory(at path: String) throws { try wrapped.deleteDirectory(at: path) }
    func createSymlink(at linkPath: String, pointingTo targetPath: String) throws {
        try wrapped.createSymlink(at: linkPath, pointingTo: targetPath)
    }
    func symlinkTarget(at path: String) throws -> String { try wrapped.symlinkTarget(at: path) }
    func isSymlink(at path: String) -> Bool { wrapped.isSymlink(at: path) }
    func isRegularFile(at path: String) -> Bool { wrapped.isRegularFile(at: path) }
    func listDirectory(at path: String) throws -> [String] {
        record(path)
        if failListing && path.hasSuffix("/manifest/scenarios") { throw CocoaError(.fileReadUnknown) }
        return try wrapped.listDirectory(at: path)
    }
    func contentsHash(at path: String) throws -> String { try wrapped.contentsHash(at: path) }
}
