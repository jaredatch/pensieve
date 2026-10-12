import Foundation
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class ManifestSaveFixture {
    final class Messages { var lines: [String] = [] }
    let root: String
    let lockPath: String
    let files = FileService()
    let manifest = ManifestService()
    let context: ModelContext
    let saves: ManifestSaveModel
    let recording: RecordingSaveManifest
    let messages = Messages()
    let library: SkillLibraryViewModel
    let categories: CategoryStore
    let local = Pensieve.Category(name: "Local")
    let doomed = Pensieve.Category(name: "ZDelete")
    let alpha = Skill(name: "Alpha", directoryName: "alpha")
    let beta = Skill(name: "Beta", directoryName: "beta")
    let project: Project

    init(unopenableLock: Bool = false, waitSeconds: TimeInterval = 0.01, rebuildFiles: FileServiceProtocol? = nil) throws {
        root = TestTemporaryDirectory.path + "manifest-save-" + UUID().uuidString
        lockPath = root + "/support/sync.lock"
        context = ModelContext(try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true)))
        recording = RecordingSaveManifest()
        let messages = messages
        saves = ManifestSaveModel(manifest: recording, root: root, lockPath: lockPath,
        waitSeconds: waitSeconds, files: rebuildFiles ?? files, log: { messages.lines.append($0) })
        library = SkillLibraryViewModel(skillStore: SkillStore(fileService: files, baseDir: root + "/skills", storeRoot: root),
            fileWatchService: FileWatchService(rootDir: root + "/skills"),
            manifestRoot: root, manifestSaves: saves)
        categories = CategoryStore( manifestSaves: saves)
        project = Project(name: "Local", path: root + "/project")
        project.identityKey = "local-key"
        for skill in [alpha, beta] {
            skill.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
            context.insert(skill)
            try files.writeFile(at: skill.canonicalPath(skillsDirectory: root + "/skills"),
                content: SkillSerializer.serialize(name: skill.name, description: "description", body: "body"))
        }
        context.insert(local)
        context.insert(doomed)
        context.insert(project)
        try context.save()
        try manifest.write(try manifest.snapshot(from: context), toRoot: root)
        if unopenableLock { try files.createDirectory(at: lockPath) }
    }

    func manifestBytes() throws -> [String: Data] {
        try Self.manifestBytes(root: root, files: files)
    }

    func assertWaitingBehindHeldLock(pending: Int, before: [String: Data],
                                     file: StaticString = #filePath, line: UInt = #line) async {
        await TestWait.until(failureMessage: "The queued saves never reached their lock wait or completion") {
            self.saves.isWaiting || self.saves.pendingCount == 0
        }
        XCTAssertTrue(saves.isWaiting, "Saves must wait for the held sync.lock", file: file, line: line)
        XCTAssertEqual(saves.pendingCount, pending, file: file, line: line)
        XCTAssertTrue(recording.writes.isEmpty, "No queued writer may publish through the held lock", file: file, line: line)
        XCTAssertEqual(try manifestBytes(), before, file: file, line: line)
    }

    static func manifestBytes(root: String, files: FileServiceProtocol) throws -> [String: Data] {
        var result: [String: Data] = [:]
        func walk(_ relative: String) throws {
            for name in try files.listDirectory(at: root + "/manifest" + relative) {
                let path = relative + "/" + name
                if files.directoryExists(at: root + "/manifest" + path) { try walk(path) } else {
                    result[path] = try files.readData(at: root + "/manifest" + path)
                }
            }
        }
        try walk("")
        return result
    }

    func cleanup() { try? files.deleteDirectory(at: root) }
}

/// Records the real full-snapshot writes, preserving their thread order; it does not implement merging.
final class RecordingSaveManifest: ManifestSnapshotting {
    private let base = ManifestService()
    private let lock = NSLock()
    private var snapshots: [ManifestSnapshot] = []
    var failingWrites = 0
    var failingSnapshots = 0
    var failingRebuildSnapshots = 0
    var afterWrite: (() -> Void)?
    var afterRebuildSnapshot: (() throws -> Void)?
    struct Refused: LocalizedError { var errorDescription: String? { "The local library could not be read." } }
    var writes: [ManifestSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return snapshots
    }
    func snapshot(from context: ModelContext) throws -> ManifestSnapshot {
        if !Thread.isMainThread, failingRebuildSnapshots > 0 {
            failingRebuildSnapshots -= 1
            throw CocoaError(.fileReadCorruptFile)
        }
        // These faults belong to the window fallback/projection read, not the worker result read.
        if Thread.isMainThread, failingSnapshots > 0 { failingSnapshots -= 1; throw Refused() }
        let value = try base.snapshot(from: context)
        if !Thread.isMainThread { try afterRebuildSnapshot?() }
        return value
    }
    func read(fromRoot root: String) throws -> ManifestSnapshot { try base.read(fromRoot: root) }
    func write(_ snapshot: ManifestSnapshot, toRoot root: String) throws {
        if failingWrites > 0 { failingWrites -= 1; throw CocoaError(.fileWriteNoPermission) }
        try base.write(snapshot, toRoot: root)
        lock.lock()
        snapshots.append(snapshot)
        lock.unlock()
        afterWrite?()
    }
}
