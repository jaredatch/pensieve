import XCTest
@testable import Pensieve

private struct SnapshotFileService: FileServiceProtocol {
    let document: String

    func readFile(at path: String) throws -> String { document }
    func writeFile(at path: String, content: String) throws {}
    func deleteFile(at path: String) throws {}
    func fileExists(at path: String) -> Bool { false }
    func isExecutableFile(at path: String) -> Bool { false }
    func directoryExists(at path: String) -> Bool { true }
    func createDirectory(at path: String) throws {}
    func deleteDirectory(at path: String) throws {}
    func createSymlink(at linkPath: String, pointingTo targetPath: String) throws {}
    func symlinkTarget(at path: String) throws -> String { "" }
    func isSymlink(at path: String) -> Bool { false }
    func isRegularFile(at path: String) -> Bool { path.hasSuffix("/SKILL.md") }
    func listDirectory(at path: String) throws -> [String] { [] }
    func contentsHash(at path: String) throws -> String { "hash" }
}

/// A skill directory of named text files, for the inventory that rides the snapshot: the root lists them,
/// each is a regular file holding `document`, nothing is a directory but the root.
private struct InventoryFileService: FileServiceProtocol {
    let document: String
    let entries: [String]

    private func isEntry(_ path: String) -> Bool { entries.contains { path.hasSuffix("/" + $0) } }
    func readFile(at path: String) throws -> String { document }
    func readData(at path: String) throws -> Data {
        guard isEntry(path), let data = document.data(using: .utf8) else { throw CocoaError(.fileReadNoSuchFile) }
        return data
    }
    func writeFile(at path: String, content: String) throws {}
    func deleteFile(at path: String) throws {}
    func fileExists(at path: String) -> Bool { isEntry(path) }
    func isExecutableFile(at path: String) -> Bool { false }
    func directoryExists(at path: String) -> Bool { !isEntry(path) }
    func createDirectory(at path: String) throws {}
    func deleteDirectory(at path: String) throws {}
    func createSymlink(at linkPath: String, pointingTo targetPath: String) throws {}
    func symlinkTarget(at path: String) throws -> String { "" }
    func isSymlink(at path: String) -> Bool { false }
    func isRegularFile(at path: String) -> Bool { isEntry(path) }
    func listDirectory(at path: String) throws -> [String] { entries }
    func contentsHash(at path: String) throws -> String { "hash" }
}

private final class SnapshotLinkService: LinkServiceProtocol {
    let linkedPlatforms: Set<PlatformTarget>
    var linkedByProjectPath: [String: Set<PlatformTarget>] = [:]
    private(set) var isLinkedProjectPaths: [String?] = []

    init(linkedPlatforms: Set<PlatformTarget>) {
        self.linkedPlatforms = linkedPlatforms
    }

    func link(skill: Skill, platform: PlatformTarget, projectPath: String?) throws {}
    func unlink(skill: Skill, platform: PlatformTarget, projectPath: String?) throws -> Bool { false }
    func ownsArtifact(skill: Skill, platform: PlatformTarget, projectPath: String?) throws -> Bool {
        if let projectPath, let linked = linkedByProjectPath[projectPath] { return linked.contains(platform) }
        return linkedPlatforms.contains(platform)
    }

    func isLinked(skill: Skill, platform: PlatformTarget, projectPath: String?) -> Bool {
        isLinkedProjectPaths.append(projectPath)
        if let projectPath, let linked = linkedByProjectPath[projectPath] { return linked.contains(platform) }
        return linkedPlatforms.contains(platform)
    }

    func linkPath(skill: Skill, platform: PlatformTarget, projectPath: String?) -> String {
        (projectPath ?? "/tmp/user-wide") + "/" + platform.rawValue + "/" + skill.directoryName
    }

    func targetPath(skill: Skill, platform: PlatformTarget, projectPath: String?) -> String {
        Constants.pensieveSkillsDir + "/" + skill.directoryName
    }

    func validateAll(skills: [Skill]) -> [BrokenLink] { [] }
}

private struct SnapshotCursorCompiler: CursorCompilerProtocol {
    var upToDate = false

    func compile(skill: Skill, projectPath: String?) throws {}
    func remove(skill: Skill, projectPath: String?) throws -> Bool { false }
    func probeRulePresence(skill: Skill, projectPath: String?) throws -> Bool {
        return upToDate
    }
    func ownsArtifact(skill: Skill, projectPath: String?) throws -> Bool { upToDate }
    func hasOwnershipMark(skill: Skill, projectPath: String?) throws -> Bool { upToDate }

    func isUpToDate(skill: Skill, projectPath: String?) -> Bool { upToDate }
    func outputPath(skill: Skill, projectPath: String?) -> String {
        (projectPath ?? "/tmp/user-wide") + "/" + skill.directoryName + ".mdc"
    }
}

private struct SnapshotDetection: AgentDetectionServiceProtocol {
    let installed: [PlatformTarget]

    func isInstalled(_ platform: PlatformTarget) -> Bool { installed.contains(platform) }
    func installedPlatforms() -> [PlatformTarget] { installed }
}

final class DetailContentSnapshotTests: XCTestCase {
    private let document = """
    ---
    name: Snapshot Skill
    description: Snapshot fixture
    ---

    # Body

    Snapshot text.
    """

    private func makePlatformVM(fileService: FileServiceProtocol, linked: Set<PlatformTarget>,
                                installed: [PlatformTarget],
                                cursorUpToDate: Bool = false) -> (PlatformViewModel, SnapshotLinkService) {
        let linkService = SnapshotLinkService(linkedPlatforms: linked)
        let platformVM = PlatformViewModel(
            fileService: fileService,
            linkService: linkService,
            cursorCompiler: SnapshotCursorCompiler(upToDate: cursorUpToDate),
            agentDetection: SnapshotDetection(installed: installed), deployStateStore: .memoryBacked
        )
        return (platformVM, linkService)
    }

    @MainActor
    func testLoadReadsBodyAndTokens() async {
        let fileService = SnapshotFileService(document: document)
        let skill = Skill(name: "Snapshot Skill", directoryName: "snapshot-skill")
        let library = SkillLibraryViewModel(
            skillStore: SkillStore(fileService: fileService),
            fileService: fileService
        )
        let (platformVM, _) = makePlatformVM(fileService: fileService, linked: [], installed: [])

        let snapshot = DetailContentSnapshot.load(skill: skill, projects: [], library: library, platformVM: platformVM)

        XCTAssertEqual(snapshot.body, "# Body\n\nSnapshot text.")
        XCTAssertEqual(snapshot.tokenCount, skill.estimatedTokens(using: fileService))

        let revisionBefore = library.appWriteRevision
        library.noteAppAuthoredBody(skill, body: snapshot.body)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(library.appWriteRevision, revisionBefore + 1)
    }

    func testMacStatusCoversEveryInstalledPlatform() {
        let fileService = SnapshotFileService(document: document)
        let skill = Skill(name: "Snapshot Skill", directoryName: "snapshot-skill")
        let library = SkillLibraryViewModel(skillStore: SkillStore(fileService: fileService), fileService: fileService)
        let (platformVM, linkService) = makePlatformVM(fileService: fileService, linked: [.claudeCode],
                                                       installed: [.claudeCode, .cursor])

        let snapshot = DetailContentSnapshot.load(skill: skill, projects: [], library: library, platformVM: platformVM)

        XCTAssertEqual(snapshot.macStatus, [.claudeCode: true, .cursor: false])
        XCTAssertEqual(snapshot.deployedOnThisMac, 1)
        XCTAssertTrue(snapshot.projectStatus.isEmpty)
        XCTAssertEqual(linkService.isLinkedProjectPaths, [nil])
    }

    func testTheCompilersAnswerReachesTheMacStatus() {
        let fileService = SnapshotFileService(document: document)
        let skill = Skill(name: "Snapshot Skill", directoryName: "snapshot-skill")
        let library = SkillLibraryViewModel(skillStore: SkillStore(fileService: fileService), fileService: fileService)
        let (platformVM, _) = makePlatformVM(fileService: fileService, linked: [],
                                             installed: [.claudeCode, .cursor], cursorUpToDate: true)

        let snapshot = DetailContentSnapshot.load(skill: skill, projects: [], library: library, platformVM: platformVM)

        XCTAssertEqual(snapshot.macStatus, [.claudeCode: false, .cursor: true])
        XCTAssertEqual(snapshot.deployedOnThisMac, 1)
    }

    func testProjectStatusCoversProjectCapablePlatformsPerProject() {
        let fileService = SnapshotFileService(document: document)
        let skill = Skill(name: "Snapshot Skill", directoryName: "snapshot-skill")
        let alpha = Project(name: "Alpha", path: "/tmp/alpha")
        let beta = Project(name: "Beta", path: "/tmp/beta")
        let library = SkillLibraryViewModel(skillStore: SkillStore(fileService: fileService), fileService: fileService)
        let (platformVM, linkService) = makePlatformVM(fileService: fileService, linked: [],
                                                       installed: [.claudeCode, .codex, .openClaw, .hermes])
        linkService.linkedByProjectPath = ["/tmp/alpha": [.claudeCode]]

        let snapshot = DetailContentSnapshot.load(skill: skill, projects: [alpha, beta], library: library, platformVM: platformVM)

        XCTAssertEqual(snapshot.projectStatus[alpha.id], [.claudeCode: true, .codex: false])
        XCTAssertEqual(snapshot.projectStatus[beta.id], [.claudeCode: false, .codex: false])
        XCTAssertEqual(Set(snapshot.macStatus.keys), [.claudeCode, .codex, .openClaw, .hermes])
        let projectPaths = linkService.isLinkedProjectPaths.compactMap { $0 }
        XCTAssertEqual(projectPaths.count, 4)
        XCTAssertEqual(Set(projectPaths), ["/tmp/alpha", "/tmp/beta"])
    }

    func testAnUndetectedPlatformIsAbsentFromBothMaps() {
        let fileService = SnapshotFileService(document: document)
        let skill = Skill(name: "Snapshot Skill", directoryName: "snapshot-skill")
        let project = Project(name: "Alpha", path: "/tmp/alpha")
        let library = SkillLibraryViewModel(skillStore: SkillStore(fileService: fileService), fileService: fileService)
        let (platformVM, _) = makePlatformVM(fileService: fileService, linked: [.claudeCode], installed: [])

        let snapshot = DetailContentSnapshot.load(skill: skill, projects: [project], library: library, platformVM: platformVM)

        XCTAssertEqual(snapshot.macStatus, [:])
        XCTAssertEqual(snapshot.projectStatus[project.id], [:])
        XCTAssertEqual(snapshot.deployedOnThisMac, 0)
    }

    func testInventoryRidesTheSnapshot() {
        let fileService = InventoryFileService(document: document, entries: ["SKILL.md", "notes.md"])
        let skill = Skill(name: "Snapshot Skill", directoryName: "snapshot-skill")
        let library = SkillLibraryViewModel(skillStore: SkillStore(fileService: fileService), fileService: fileService)
        let (platformVM, _) = makePlatformVM(fileService: fileService, linked: [], installed: [])

        let snapshot = DetailContentSnapshot.load(skill: skill, projects: [], library: library, platformVM: platformVM)

        XCTAssertEqual(snapshot.inventory.files.map(\.relativePath), ["SKILL.md", "notes.md"])
        XCTAssertEqual(snapshot.inventory.textFiles.count, 2)
        XCTAssertEqual(snapshot.inventory.totalBytes, 2 * document.utf8.count)
        XCTAssertEqual(snapshot.body, "# Body\n\nSnapshot text.")
    }

    func testDeployedOnThisMacCountsTheMacSwitches() {
        var snapshot = DetailContentSnapshot()
        snapshot.macStatus = [.claudeCode: true, .codex: true, .cursor: false]
        snapshot.projectStatus = [UUID(): [.claudeCode: true]]

        XCTAssertEqual(snapshot.deployedOnThisMac, 2)
    }

    @MainActor
    func testAppWriteRevisionCoalescesQueuedPublishes() {
        let fileService = SnapshotFileService(document: document)
        let library = SkillLibraryViewModel(
            skillStore: SkillStore(fileService: fileService),
            fileService: fileService
        )
        let before = library.appWriteRevision

        // Three publishes before the main queue drains (the bracketed end + the echo registrar,
        // or an N-skill import) must bump the revision once, and only after the drain.
        library.publishAppWriteRevision()
        library.publishAppWriteRevision()
        library.publishAppWriteRevision()
        XCTAssertEqual(library.appWriteRevision, before)

        let firstDrain = expectation(description: "main queue drained")
        DispatchQueue.main.async { firstDrain.fulfill() }
        wait(for: [firstDrain], timeout: TestWait.hostedActionTimeoutSeconds)
        XCTAssertEqual(library.appWriteRevision, before + 1)

        // A publish after the drain is a new logical write: it bumps again.
        library.publishAppWriteRevision()
        let secondDrain = expectation(description: "main queue drained again")
        DispatchQueue.main.async { secondDrain.fulfill() }
        wait(for: [secondDrain], timeout: TestWait.hostedActionTimeoutSeconds)
        XCTAssertEqual(library.appWriteRevision, before + 2)
    }
}
