import AppKit
import Observation
import SwiftData
import SwiftUI
import XCTest
@testable import Pensieve

@MainActor
final class SkillDetailTabResetTests: XCTestCase {
    func testChangingHistorySkillsThroughLinkedSkillResetsAuthoredPresentation() {
        let first = Skill(name: "First", directoryName: "first")
        let model = SkillDetailTabResetModel(skill: first)
        let presentation = SkillHistoryTabPresentation()
        let thirdCommit = GitCommit(
            sha: "third", author: "Third Author", date: Date(), subject: "Third version"
        )
        let git = SkillDetailTabResetGit(thirdCommit: thirdCommit)
        let base = TestTemporaryDirectory.path + "SkillDetailTabResetTests-\(UUID().uuidString)"
        let library = SkillLibraryViewModel(
            skillStore: SkillStore(fileService: FileService(), baseDir: base + "/skills", storeRoot: base),
            fileWatchService: FileWatchService(rootDir: base + "/skills"), manifestRoot: base
        )
        let history = UpstreamHistoryViewModel(
            readOperation: { _, _, _ in historyResult() },
            localEditsOperation: { _, _, _ in .none },
            localDirectory: { _ in base }
        )
        let host = NSHostingView(rootView: SkillHistoryTabResetHarness(
            model: model,
            library: library,
            history: history,
            presentation: presentation,
            workingDir: base,
            git: git
        ))
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))

        let version = SkillHistoryVersion(
            sha: "old", date: Date(), author: "Author", subject: "Old version"
        )
        presentation.snapshot = SkillHistorySnapshot(versions: [version])
        presentation.errorMessage = "Couldn't load that version."
        presentation.showAll = true
        presentation.diff = SkillHistoryTabPresentation.Diff(version: version, body: "Old body")
        presentation.restoring = version
        model.skill = installedHistorySkill(name: "Linked")
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        host.layoutSubtreeIfNeeded()
        model.skill = Skill(name: "Third", directoryName: "third")
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(git.logPaths.last, "skills/third/SKILL.md")
        XCTAssertEqual(presentation.snapshot, SkillHistorySnapshot(versions: [historyVersion(thirdCommit)]))
        XCTAssertNil(presentation.errorMessage)
        XCTAssertFalse(presentation.showAll)
        XCTAssertNil(presentation.diff)
        XCTAssertNil(presentation.restoring)
        XCTAssertFalse(git.logPaths.isEmpty)
    }

    func testChangingSkillsCollapsesProjectsAndClearsDeploymentAlert() throws {
        let base = TestTemporaryDirectory.path + "SkillDetailTabResetTests-\(UUID().uuidString)"
        let fileService = DeployRecordingFileService()
        let platformVM = PlatformViewModel(
            fileService: fileService,
            linkService: TestPaths.linkService(fileService: fileService),
            cursorCompiler: TestPaths.cursorCompiler(fileService: fileService),
            agentDetection: EmptyMachineDetection(),
            deployStateStore: DeployStateStore(fileService: fileService, appSupportDir: base),
            skillsDirectory: TestPaths.skillsDir
        )
        let dependencies = DeployIntentDependencies(
            identity: InertMachineIdentity(),
            stateService: InertMachineStateService(),
            root: base,
            writeManifest: { _ in },
            notifier: {},
            lockPath: base + "/sync.lock",
            lockProvider: { _ in nil }
        )
        let intentModel = DeployIntentModel(platformVM: platformVM, dependencies: dependencies)
        let presentation = SkillDeploymentsTabPresentation()
        let model = SkillDetailTabResetModel(skill: Skill(name: "First", directoryName: "first"))
        let container = try AppRuntime.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let host = NSHostingView(rootView: SkillDeploymentsTabResetHarness(
            model: model,
            platformVM: platformVM,
            dependencies: dependencies,
            intentModel: intentModel,
            presentation: presentation
        ).modelContainer(container))
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))

        presentation.expandedProjects.insert(.local(UUID()))
        intentModel.error = "Previous skill failed"
        model.skill = Skill(name: "Second", directoryName: "second")
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        host.layoutSubtreeIfNeeded()

        XCTAssertTrue(presentation.expandedProjects.isEmpty)
        XCTAssertNil(intentModel.error)
    }
}

private func historyVersion(_ commit: GitCommit) -> SkillHistoryVersion {
    SkillHistoryVersion(sha: commit.sha, date: commit.date, author: commit.author, subject: commit.subject)
}

@MainActor
@Observable
private final class SkillDetailTabResetModel {
    var skill: Skill

    init(skill: Skill) {
        self.skill = skill
    }
}

@MainActor
private struct SkillHistoryTabResetHarness: View {
    @Bindable var model: SkillDetailTabResetModel
    @Bindable var library: SkillLibraryViewModel
    @Bindable var history: UpstreamHistoryViewModel
    let presentation: SkillHistoryTabPresentation
    let workingDir: String
    let git: GitServiceProtocol

    var body: some View {
        SkillHistoryTab(
            skill: model.skill,
            currentBody: "",
            library: library,
            upstreamHistory: history,
            localRevision: .initial,
            onOpenUpdates: {},
            onUpdateCheck: { _ in },
            git: git,
            store: library.skillStore,
            workingDir: workingDir,
            hostedPresentation: presentation
        )
    }
}

private final class SkillDetailTabResetGit: GitServiceProtocol {
    let thirdCommit: GitCommit
    private(set) var logPaths: [String] = []

    init(thirdCommit: GitCommit) {
        self.thirdCommit = thirdCommit
    }

    func log(forPath path: String, at workingDir: String, limit: Int) -> [GitCommit] {
        logPaths.append(path)
        return path == "skills/third/SKILL.md" ? [thirdCommit] : []
    }

    func show(sha: String, path: String, at workingDir: String) -> String? { nil }
    func remoteURL(at path: String) -> String? { nil }
    func initRepository(at path: String) throws {}
    func setRemote(_ url: String, at path: String) throws {}
    func removeRemote(at path: String) throws {}
    func configuredRemoteURL(at path: String) throws -> String? { nil }
    func clone(remote: String, into path: String, credential: GitCredential?) throws {}
    func remoteHasCommits(remote: String, credential: GitCredential?) -> Bool { false }
    @discardableResult func stageAllAndCommit(at path: String, message: String) throws -> Bool { false }
    func preflightStoreUpdate(at path: String, credential: GitCredential?) -> FetchedStoreRevision? { nil }
    func pullRebase(at path: String, fetchedRevision: FetchedStoreRevision) throws -> PullResult {
        try pullRebase(at: path, credential: nil)
    }
    func pullRebase(at path: String, credential: GitCredential?) throws -> PullResult { .upToDate }
    func push(at path: String, credential: GitCredential?) throws {}
    func abortRebase(at path: String) throws {}
    func conflictedFiles(at path: String) -> [String] { [] }
    func blob(atStage stage: Int, path: String, in workingDir: String) -> Data? { nil }
    func continueRebase(at path: String) throws -> PullResult { .upToDate }
    func skipRebase(at path: String) throws -> PullResult { .upToDate }
    func stagePath(_ path: String, at root: String) throws {}
    func collapseToSingleCommit(at root: String, message: String, credential: GitCredential?,
                                fetchedRevision: FetchedStoreRevision?) throws -> Bool { false }
    func hasCommitsToPush(at path: String) -> Bool { false }
}

@MainActor
private struct SkillDeploymentsTabResetHarness: View {
    @Bindable var model: SkillDetailTabResetModel
    @Bindable var platformVM: PlatformViewModel
    let dependencies: DeployIntentDependencies
    let intentModel: DeployIntentModel
    let presentation: SkillDeploymentsTabPresentation

    var body: some View {
        SkillDeploymentsTab(
            skill: model.skill,
            snapshot: DetailContentSnapshot(),
            statusIsCurrent: true,
            projects: [],
            platformVM: platformVM,
            addsFenced: false,
            intentDependencies: dependencies,
            machineStates: [],
            localMachineID: InertMachineIdentity.value,
            hostedIntentModel: intentModel,
            hostedPresentation: presentation,
            homeDirectory: TestPaths.homeDirectory,
            onAddProject: {}
        )
    }
}
