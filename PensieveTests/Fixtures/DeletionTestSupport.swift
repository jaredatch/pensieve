import Foundation
import SwiftData
@testable import Pensieve

struct DeletionTestError: LocalizedError {
    var errorDescription: String? { "injected failure" }
}

struct DeletionTestDetection: AgentDetectionServiceProtocol {
    let installed: [PlatformTarget]
    func isInstalled(_ platform: PlatformTarget) -> Bool { installed.contains(platform) }
    func installedPlatforms() -> [PlatformTarget] { installed }
}

final class DeletionTestLinkService: LinkServiceProtocol {
    var linkedPaths: Set<String> = []
    var foreignSymlinkPaths: Set<String> = []
    var failingUnlinkPaths: Set<String> = []
    private(set) var linkCalls: [(PlatformTarget, String?)] = []
    private(set) var unlinkCalls: [(PlatformTarget, String?)] = []

    func path(_ skill: Skill, _ platform: PlatformTarget, _ projectPath: String?) -> String {
        "/links/\(platform.rawValue)/\(projectPath ?? "user")/\(skill.directoryName)"
    }

    func link(skill: Skill, platform: PlatformTarget, projectPath: String?) throws {
        linkCalls.append((platform, projectPath))
        linkedPaths.insert(path(skill, platform, projectPath))
    }

    func unlink(skill: Skill, platform: PlatformTarget, projectPath: String?) throws {
        let value = path(skill, platform, projectPath)
        unlinkCalls.append((platform, projectPath))
        if failingUnlinkPaths.contains(value) { throw DeletionTestError() }
        linkedPaths.remove(value)
    }

    func isLinked(skill: Skill, platform: PlatformTarget, projectPath: String?) -> Bool {
        linkedPaths.contains(path(skill, platform, projectPath))
    }

    func linkPath(skill: Skill, platform: PlatformTarget, projectPath: String?) -> String {
        path(skill, platform, projectPath)
    }

    func targetPath(skill: Skill, platform: PlatformTarget, projectPath: String?) -> String {
        "/target/\(skill.directoryName)"
    }

    func validateAll(skills: [Skill]) -> [BrokenLink] { [] }
}

final class DeletionTestCursorCompiler: CursorCompilerProtocol {
    var ownedProjectPaths: Set<String?> = []
    private(set) var removeProjectPaths: [String?] = []
    func compile(skill: Skill, projectPath: String?) throws {}
    func remove(skill: Skill, projectPath: String?) throws { removeProjectPaths.append(projectPath) }
    func isUpToDate(skill: Skill, projectPath: String?) -> Bool { false }
    func ownsArtifact(skill: Skill, projectPath: String?) throws -> Bool { ownedProjectPaths.contains(projectPath) }
    func outputPath(skill: Skill, projectPath: String?) -> String {
        "/cursor/\(projectPath ?? "user")/\(skill.directoryName).mdc"
    }
}

extension DeployStateStore {
    /// A store no test can reach the developer's ledger through: PLAN-29's constructor read goes to
    /// memory, and the lock file a write would take — `SyncLock` opens it with `FileManager`, outside
    /// the file service — lands under a unique temporary root, never under the real Application Support.
    static var memoryBacked: DeployStateStore {
        DeployStateStore(fileService: MemoryDeployFileService(),
                         appSupportDir: NSTemporaryDirectory() + "PensieveMemoryDeployState-" + UUID().uuidString)
    }
}

final class MemoryDeployFileService: FileServiceProtocol {
    var files: [String: String] = [:]
    var failingWrites: Set<String> = []
    var readCounts: [String: Int] = [:]

    func readFile(at path: String) throws -> String {
        readCounts[path, default: 0] += 1
        guard let value = files[path] else { throw DeletionTestError() }
        return value
    }

    func writeFile(at path: String, content: String) throws {
        if failingWrites.contains(path) { throw DeletionTestError() }
        files[path] = content
    }

    func deleteFile(at path: String) throws { files[path] = nil }
    func fileExists(at path: String) -> Bool { files[path] != nil }
    func isExecutableFile(at path: String) -> Bool { false }
    func directoryExists(at path: String) -> Bool { false }
    func createDirectory(at path: String) throws {}
    func deleteDirectory(at path: String) throws {}
    func createSymlink(at linkPath: String, pointingTo targetPath: String) throws {}
    func symlinkTarget(at path: String) throws -> String { throw DeletionTestError() }
    func isSymlink(at path: String) -> Bool { false }
    func isRegularFile(at path: String) -> Bool { files[path] != nil }
    func listDirectory(at path: String) throws -> [String] { [] }
    func contentsHash(at path: String) throws -> String { "hash" }
}

final class RecordingDeletionSkillStore: SkillStoreProtocol {
    var bodies: [String: String] = [:]
    var entries: Set<String> = []
    var unsafeLeaves: Set<String> = []
    var deleteFailures: Set<String> = []
    var entryProbeError = false
    var entryAnswers: [Bool] = []
    var readAnswers: [Bool] = []
    private(set) var deleteCalls: [String] = []
    private(set) var createAvoiding: [Set<String>] = []
    private(set) var writeSkillCalls: [String] = []
    private(set) var writeBodyCalls: [String] = []

    func createSkill(name: String, description: String, body: String) throws -> String {
        try createSkill(name: name, description: description, body: body, avoiding: [])
    }

    func createSkill(name: String, description: String, body: String, avoiding: Set<String>) throws -> String {
        createAvoiding.append(avoiding)
        let base = SkillStore.slugify(name)
        let blocked = Set(avoiding.map { $0.lowercased() }).union(entries.map { $0.lowercased() })
        var slug = base
        var suffix = 2
        while blocked.contains(slug.lowercased()) {
            slug = "\(base)-\(suffix)"
            suffix += 1
        }
        bodies[slug] = body
        entries.insert(slug)
        return slug
    }

    func readBody(directoryName: String) throws -> String {
        if !readAnswers.isEmpty, !readAnswers.removeFirst() { throw DeletionTestError() }
        if unsafeLeaves.contains(directoryName) { throw SkillStoreError.unsafeLeaf(directoryName) }
        guard let body = bodies[directoryName] else { throw DeletionTestError() }
        return body
    }

    func rewriteSkill(directoryName: String, body: String, preserving parsed: ParsedSkill,
                      fallbackName: String, fallbackDescription: String) throws -> SkillRewriteResult {
        writeSkillCalls.append(directoryName)
        bodies[directoryName] = body
        entries.insert(directoryName)
        return SkillRewriteResult(content: bodies[directoryName] ?? body, didChange: true)
    }

    func writeBody(directoryName: String, body: String) throws {
        writeBodyCalls.append(directoryName)
        bodies[directoryName] = body
        entries.insert(directoryName)
    }

    func deleteSkill(directoryName: String) throws {
        deleteCalls.append(directoryName)
        guard !deleteFailures.contains(directoryName), bodies[directoryName] != nil else {
            throw DeletionTestError()
        }
        bodies[directoryName] = nil
        entries.remove(directoryName)
    }

    func listSkills() throws -> [String] { Array(bodies.keys) }

    func slugEntryExists(_ directoryName: String) throws -> Bool {
        if entryProbeError { throw DeletionTestError() }
        if !entryAnswers.isEmpty { return entryAnswers.removeFirst() }
        return entries.contains { $0.lowercased() == directoryName.lowercased() }
    }
}

final class RecordingDeletionManifest: ManifestSnapshotting {
    var failingWrites: Set<Int> = []
    private(set) var snapshots: [ManifestSnapshot] = []
    private var writeNumber = 0

    func snapshot(from context: ModelContext) throws -> ManifestSnapshot {
        let skills = try context.fetch(FetchDescriptor<Skill>())
        let categories = try context.fetch(FetchDescriptor<Pensieve.Category>())
        let intents = try context.fetch(FetchDescriptor<MachineDeployIntent>())
        return ManifestSnapshot(
            schemaVersion: 3,
            categories: categories.map { CategoryRecord(name: $0.name, projectKeys: $0.projectKeys, skillSlugs: $0.skillSlugs) },
            projects: [],
            skills: skills.map {
                SkillOverlay(slug: $0.directoryName, createdAt: $0.createdAt, scope: $0.scope,
                             tags: $0.tags, cursor: $0.cursorConfig, agents: [], origin: .authored)
            },
            deployIntents: intents.map {
                DeployIntentRecord(machineID: $0.machineID, skillSlug: $0.skillSlug,
                                   platformRaw: $0.platformRaw, projectKey: $0.projectKey)
            }
        )
    }

    func write(_ snapshot: ManifestSnapshot, toRoot root: String) throws {
        writeNumber += 1
        if failingWrites.contains(writeNumber) { throw DeletionTestError() }
        snapshots.append(snapshot)
    }

    func read(fromRoot root: String) throws -> ManifestSnapshot {
        snapshots.last ?? ManifestSnapshot(schemaVersion: 3, categories: [], projects: [], skills: [])
    }
}

final class DeletionCounter {
    private(set) var value = 0
    lazy var notify: SyncStateNotifying = { [weak self] in self?.value += 1 }
    func reset() { value = 0 }
}
