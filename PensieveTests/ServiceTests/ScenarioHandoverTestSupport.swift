import SwiftData
import XCTest
@testable import Pensieve

final class HandoverIdentity: MachineIdentityProviding {
    var id = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    var fails = false
    var calls = 0
    func identifier() throws -> String {
        calls += 1
        if fails { throw DeployStubFailure() }
        return id
    }
}

final class HandoverManifest: ManifestSnapshotting {
    let live = ManifestService()
    var writes = 0
    var failWrite: Int?
    var failAllWrites = false
    func snapshot(from context: ModelContext) throws -> ManifestSnapshot { try live.snapshot(from: context) }
    func read(fromRoot root: String) throws -> ManifestSnapshot { try live.read(fromRoot: root) }
    func write(_ snapshot: ManifestSnapshot, toRoot root: String) throws {
        writes += 1
        if failAllWrites || writes == failWrite { throw DeployStubFailure() }
        try live.write(snapshot, toRoot: root)
    }
}

struct HandoverArtifact: Equatable {
    let identity: FileIdentity?
    let modified: Date
    let bytes: Data?
    let linkTarget: String?
}

@MainActor
final class HandoverHarness {
    let root: String
    let container: ModelContainer
    let context: ModelContext
    let defaults: UserDefaults
    let identity = HandoverIdentity()
    let manifest = HandoverManifest()
    let files = FileService()
    var logs: [String] = []
    var nudges = 0
    var artifacts: [String] = []
    let unrelated = [
        DeployIntentRecord(machineID: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB",
                           skillSlug: "remote", platformRaw: "codex", projectKey: nil),
        DeployIntentRecord(machineID: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA",
                           skillSlug: "skill", platformRaw: "hermes", projectKey: "marker:project")
    ]

    init(defaults: UserDefaults) throws {
        self.defaults = defaults
        root = TestTemporaryDirectory.path + "ScenarioHandover-" + UUID().uuidString
        container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        context.autosaveEnabled = false
        try files.createDirectory(at: root)
        let scenario = Scenario(name: "Active")
        context.insert(scenario)
        defaults.set(scenario.id.uuidString, forKey: ScenarioHandover.activeKey)
        for record in unrelated {
            context.insert(MachineDeployIntent(machineID: record.machineID, skillSlug: record.skillSlug,
                                               platformRaw: record.platformRaw, projectKey: record.projectKey))
        }
        try context.save()
        try manifest.live.write(manifest.live.snapshot(from: context), toRoot: root)
    }

    func cleanUp() throws { try files.deleteDirectory(at: root) }

    @discardableResult
    func seed(_ slug: String = "skill", platforms: [PlatformTarget] = [.codex, .cursor]) throws -> Skill {
        let skill = Skill(name: slug, skillDescription: "Description", directoryName: slug)
        context.insert(skill)
        let scenario = try XCTUnwrap(try context.fetch(FetchDescriptor<Scenario>()).first)
        scenario.skillSlugs.append(slug)
        scenario.agentRawValues = platforms.map(\.rawValue)
        try files.createDirectory(at: root + "/skills/" + slug)
        try files.writeFile(at: root + "/skills/" + slug + "/SKILL.md",
                            content: "---\nname: \(SkillSerializer.quotedScalar(slug))\ndescription: Description\n---\nBody")
        for platform in platforms {
            let row = ScenarioAssignment(skillID: skill.id, platform: platform)
            // Stable pair order lets interruption tests name the exact persisted prefix.
            row.id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", artifacts.count + 1))!
            context.insert(row)
            let folder = root + "/agents/" + platform.rawValue
            try files.createDirectory(at: folder)
            let path = folder + "/" + slug
            if platform.usesSymlinks {
                try files.createSymlink(at: path, pointingTo: root + "/skills/" + slug)
            } else {
                try files.writeFile(at: path, content: "compiled bytes")
            }
            artifacts.append(path)
        }
        try context.save()
        try manifest.live.write(manifest.live.snapshot(from: context), toRoot: root)
        return skill
    }

    func freshContext() -> ModelContext { ModelContext(container) }

    func handover(save: @escaping (ModelContext) throws -> Void = { try $0.save() },
                  fetcher: ReconcilerStateFetching = ReconcilerStateFetcher(),
                  fileService: FileServiceProtocol? = nil) -> ScenarioHandover {
        ScenarioHandover(machineIdentity: identity, manifest: manifest, root: root, defaults: defaults,
                         deployState: { [root] skill, platform in
                             try HandoverDeployments(root: root).platformVM.scenarioHandoverDeployState(
                                 skill: skill, platform: platform)
                         }, notifier: { [weak self] in self?.nudges += 1 },
                         fileService: fileService ?? files, fetcher: fetcher, save: save,
                         log: { [weak self] in self?.logs.append($0) })
    }

    func launch(_ handover: ScenarioHandingOver? = nil) -> LaunchReconcileOutcome {
        LaunchReconciler(
            rebuildService: StoreRebuildService(fileService: files, manifestService: manifest),
            fileService: files, manifestService: manifest, root: root, lockPath: root + "/sync.lock",
            scenarioHandover: handover ?? self.handover()
        ).reconcileOnLaunch(context: freshContext(), alreadyMigrated: true)
    }

    func deployedFiles() throws -> [String: HandoverArtifact] {
        try Dictionary(uniqueKeysWithValues: artifacts.map { path in
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            return (path, HandoverArtifact(
                identity: files.fileIdentity(at: path, followingLinks: false),
                modified: try XCTUnwrap(attributes[.modificationDate] as? Date),
                bytes: files.isRegularFile(at: path) ? try files.readData(at: path) : nil,
                linkTarget: files.isSymlink(at: path) ? try files.symlinkTarget(at: path) : nil
            ))
        })
    }

    func assertComplete(_ platforms: [String] = ["codex", "cursor"], file: StaticString = #filePath, line: UInt = #line) throws {
        let fresh = freshContext()
        XCTAssertTrue(defaults.bool(forKey: ScenarioHandover.doneKey), file: file, line: line)
        XCTAssertNil(defaults.object(forKey: ScenarioHandover.activeKey), file: file, line: line)
        XCTAssertTrue(try fresh.fetch(FetchDescriptor<ScenarioAssignment>()).isEmpty, file: file, line: line)
        let carried = try fresh.fetch(FetchDescriptor<MachineDeployIntent>()).filter {
            $0.machineID == identity.id && $0.skillSlug == "skill" && $0.projectKey == nil
        }
        XCTAssertEqual(carried.map(\.platformRaw).sorted(), platforms.sorted(), file: file, line: line)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<IntentAssignment>()).map(\.platformRaw).sorted(),
                       platforms.sorted(), file: file, line: line)
        let durable = try manifest.read(fromRoot: root).deployIntents
        XCTAssertEqual(durable.filter { $0.machineID == identity.id && $0.projectKey == nil }.map(\.platformRaw).sorted(),
                       platforms.sorted(), file: file, line: line)
        XCTAssertEqual(durable.count, unrelated.count + platforms.count, file: file, line: line)
        try assertUnrelatedIntentsUnchanged(file: file, line: line)
    }

    func assertUnrelatedIntentsUnchanged(file: StaticString = #filePath, line: UInt = #line) throws {
        func withoutHandover(_ records: [DeployIntentRecord]) -> [DeployIntentRecord] {
            records.filter {
                !($0.machineID == "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA" && $0.skillSlug == "skill" && $0.projectKey == nil)
            }.sorted { $0.machineID < $1.machineID }
        }
        let durable = try manifest.read(fromRoot: root).deployIntents
        XCTAssertEqual(withoutHandover(durable), unrelated.sorted { $0.machineID < $1.machineID }, file: file, line: line)
        let cached = try freshContext().fetch(FetchDescriptor<MachineDeployIntent>()).map {
            DeployIntentRecord(machineID: $0.machineID, skillSlug: $0.skillSlug,
                               platformRaw: $0.platformRaw, projectKey: $0.projectKey)
        }
        XCTAssertEqual(withoutHandover(cached), unrelated.sorted { $0.machineID < $1.machineID }, file: file, line: line)
    }
}

enum HandoverRead: CaseIterable { case scenario, skill, intent, assignment }

struct HandoverFailingFetcher: ReconcilerStateFetching {
    let failure: HandoverRead
    let live = ReconcilerStateFetcher()
    func scenarioAssignments(context: ModelContext) throws -> [ScenarioAssignment] {
        if failure == .scenario { throw DeployStubFailure() }
        return try live.scenarioAssignments(context: context)
    }
    func skills(context: ModelContext) throws -> [Skill] {
        if failure == .skill { throw DeployStubFailure() }
        return try live.skills(context: context)
    }
    func deployIntents(context: ModelContext) throws -> [MachineDeployIntent] {
        if failure == .intent { throw DeployStubFailure() }
        return try live.deployIntents(context: context)
    }
    func intentAssignments(context: ModelContext) throws -> [IntentAssignment] {
        if failure == .assignment { throw DeployStubFailure() }
        return try live.intentAssignments(context: context)
    }
    func categoryAssignments(context: ModelContext) throws -> [SkillProjectAssignment] {
        try live.categoryAssignments(context: context)
    }
    func projects(context: ModelContext) throws -> [Project] { try live.projects(context: context) }
}

/// Uses temp agent paths for removal and existence checks. Any attempt to create a deploy fails
/// and is counted. Rechecking transferred ownership can fail, but never repairs the artifacts.
/// Canonical admission reads are mapped to the fixture store, never the host's default store.
final class HandoverDeployments: LinkServiceProtocol, CursorCompilerProtocol {
    let root: String
    let files = FileService()
    var createCalls = 0
    var removeCalls = 0
    var allowCreation = false
    init(root: String) { self.root = root }
    var platformVM: PlatformViewModel {
        let admissions = LinkServiceCanonicalDirectoryFileService(wrapped: files,
            pathMappings: [(Constants.pensieveSkillsDir, root + "/skills")], physicalSandbox: root)
        admissions.translatesSymlinkTargets = false
        return PlatformViewModel(fileService: admissions, linkService: self, cursorCompiler: self,
                          agentDetection: DeployStubDetection(installed: [.codex, .cursor]),
                          deployStateStore: .memoryBacked)
    }
    func link(skill: Skill, platform: PlatformTarget, projectPath: String?) throws {
        createCalls += 1
        guard allowCreation else { throw DeployStubFailure() }
        try files.createSymlink(at: linkPath(skill: skill, platform: platform, projectPath: projectPath),
                                pointingTo: targetPath(skill: skill, platform: platform, projectPath: projectPath))
    }
    func unlink(skill: Skill, platform: PlatformTarget, projectPath: String?) throws -> Bool {
        removeCalls += 1
        let path = linkPath(skill: skill, platform: platform, projectPath: projectPath)
        let removed = try files.entryExistsWithoutFollowingLinks(at: path)
        try files.deleteFile(at: linkPath(skill: skill, platform: platform, projectPath: projectPath))
        return removed
    }
    func ownsArtifact(skill: Skill, platform: PlatformTarget, projectPath: String?) throws -> Bool {
        try literalLinks.ownsArtifact(skill: skill, platform: platform, projectPath: projectPath)
    }

    func isLinked(skill: Skill, platform: PlatformTarget, projectPath: String?) -> Bool {
        literalLinks.isLinked(skill: skill, platform: platform, projectPath: projectPath)
    }
    func linkPath(skill: Skill, platform: PlatformTarget, projectPath: String?) -> String {
        root + "/agents/" + platform.rawValue + "/" + skill.directoryName
    }
    func targetPath(skill: Skill, platform: PlatformTarget, projectPath: String?) -> String {
        root + "/skills/" + skill.directoryName
    }
    private var literalLinks: LinkService {
        let mappings = PlatformTarget.allCases.filter(\.usesSymlinks).map { platform in
            (logical: (DeployPaths.linkPath(directoryName: "skill", platform: platform, projectPath: nil) as NSString)
                .deletingLastPathComponent,
             physical: root + "/agents/" + platform.rawValue)
        }
        return LinkService(fileService: LinkServiceCanonicalDirectoryFileService(wrapped: files,
            pathMappings: [(Constants.pensieveSkillsDir, root + "/skills")] + mappings))
    }
    func validateAll(skills: [Skill]) -> [BrokenLink] { literalLinks.validateAll(skills: skills) }
    func compile(skill: Skill, projectPath: String?) throws {
        createCalls += 1
        guard allowCreation else { throw DeployStubFailure() }
        try files.writeFile(at: outputPath(skill: skill, projectPath: projectPath), content: "repaired")
    }
    func remove(skill: Skill, projectPath: String?) throws -> Bool {
        removeCalls += 1
        let removed = try files.entryExistsWithoutFollowingLinks(at: outputPath(skill: skill, projectPath: projectPath))
        try files.deleteFile(at: outputPath(skill: skill, projectPath: projectPath))
        return removed
    }
    func probeRulePresence(skill: Skill, projectPath: String?) throws -> Bool {
        return try files.entryTypeWithoutFollowingLinks(at: outputPath(skill: skill, projectPath: projectPath)) == .regular
    }
    func ownsArtifact(skill: Skill, projectPath: String?) throws -> Bool {
        guard let text = try? files.readFile(at: outputPath(skill: skill, projectPath: projectPath)) else { return false }
        return text == "compiled bytes" || text == "repaired"
    }
    func hasOwnershipMark(skill: Skill, projectPath: String?) throws -> Bool {
        guard let text = try? files.readFile(at: outputPath(skill: skill, projectPath: projectPath)) else { return false }
        return text == "compiled bytes" || text == "repaired"
    }

    func isUpToDate(skill: Skill, projectPath: String?) -> Bool {
        (try? files.readFile(at: outputPath(skill: skill, projectPath: projectPath))) == "compiled bytes"
    }
    func outputPath(skill: Skill, projectPath: String?) -> String { root + "/agents/cursor/" + skill.directoryName }
}
