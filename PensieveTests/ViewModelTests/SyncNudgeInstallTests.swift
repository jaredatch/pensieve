import SwiftData
import XCTest
@testable import Pensieve

extension SyncNudgeTests {
    func testInstallCompletionNudges() async throws {
        let container = try AppRuntime.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        var nudgeCount = 0
        let notifier: SyncStateNotifying = { nudgeCount += 1 }
        let installed = Self.installCandidate(slug: "installed")
        let echo = Self.installEchoFixture(notifier: notifier)
        echo.library.startWatching()
        let model = Self.installModel(
            service: NudgeInstallService(
                candidates: [installed],
                onInstallWrite: { slug in
                    echo.store.bodies[slug] = SkillSerializer.serialize(
                        name: slug, description: "Description", body: "Installed"
                    )
                }
            ),
            notifier: notifier,
            echoRegistrar: { echo.library.noteAppAuthoredBodies(directoryNames: $0) },
            bodyWriteRegistration: Self.bodyRegistration(for: echo.library)
        )

        await model.fetchAndReport()
        await model.installSelectedAndReport(context: context)
        echo.watcher.emit(installed.slug)
        XCTAssertEqual(nudgeCount, 1)

        nudgeCount = 0
        let colliding = Self.installCandidate(slug: "colliding")
        let partialModel = Self.installModel(
            service: NudgeInstallService(
                candidates: [installed, colliding], collisionSlugs: [colliding.slug],
                onInstallWrite: { slug in
                    echo.store.bodies[slug] = SkillSerializer.serialize(
                        name: slug, description: "Description", body: "Installed"
                    )
                }
            ),
            notifier: notifier,
            echoRegistrar: { echo.library.noteAppAuthoredBodies(directoryNames: $0) },
            bodyWriteRegistration: Self.bodyRegistration(for: echo.library)
        )
        await partialModel.fetchAndReport()
        await partialModel.installSelectedAndReport(context: context)
        XCTAssertNotNil(partialModel.pendingCollision)
        echo.watcher.emit(installed.slug)
        XCTAssertEqual(nudgeCount, 0)
        partialModel.cancel()
        XCTAssertEqual(nudgeCount, 1)
    }

    func testInstallWatcherEchoRegisteredBeforeServiceCompletion() async throws {
        let container = try AppRuntime.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        var nudgeCount = 0
        let installNudge = expectation(description: "install transaction nudged")
        let writeFinished = expectation(description: "installed body replacement finished")
        let releaseInstall = TestWait.Gate(owner: self)
        let store = InstallEchoSkillStore()
        let watcher = InstallEchoWatcher()
        let library = SkillLibraryViewModel(
            skillStore: store, fileWatchService: watcher,
            notifier: {
                nudgeCount += 1
                installNudge.fulfill()
            }
        )
        library.startWatching()
        let candidate = Self.installCandidate(slug: "write-boundary")
        let model = Self.installModel(
            service: NudgeInstallService(
                candidates: [candidate],
                beforeInstallReturn: {
                    writeFinished.fulfill()
                    try releaseInstall.wait()
                },
                onInstallWrite: { slug in
                    store.bodies[slug] = SkillSerializer.serialize(
                        name: slug, description: "Description", body: "Installed"
                    )
                }
            ),
            notifier: library.notifySyncedStateMutation,
            echoRegistrar: { library.noteAppAuthoredBodies(directoryNames: $0) },
            bodyWriteRegistration: Self.bodyRegistration(for: library)
        )

        await model.fetchAndReport()
        model.installSelected(context: context)
        await fulfillment(of: [writeFinished], timeout: TestWait.hostedActionTimeoutSeconds)
        watcher.emit(candidate.slug)
        XCTAssertEqual(nudgeCount, 0)
        releaseInstall.open()
        await fulfillment(of: [installNudge], timeout: TestWait.hostedActionTimeoutSeconds)
        XCTAssertEqual(nudgeCount, 1)
    }

    func testInstallMutationEvidenceIsIsolatedByOperationID() {
        var nudgeCount = 0
        let model = Self.installModel(
            service: NudgeInstallService(candidates: []),
            notifier: { nudgeCount += 1 }
        )
        let abandonedOperationID = UUID()
        let currentOperationID = UUID()

        model.recordCanonicalWrite(operationID: abandonedOperationID)
        model.recordCanonicalWrite(operationID: currentOperationID)
        model.emitPendingMutationIfNeeded(operationID: abandonedOperationID)
        model.emitPendingMutationIfNeeded(operationID: abandonedOperationID)
        model.emitPendingMutationIfNeeded(operationID: currentOperationID)

        XCTAssertEqual(nudgeCount, 2)
    }

    func testInstallThrowAfterBodyWriteNudgesButPureFailureDoesNot() async throws {
        let container = try AppRuntime.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let candidate = Self.installCandidate(slug: "partial-install")
        var nudgeCount = 0
        let partialModel = Self.installModel(
            service: NudgeInstallService(
                candidates: [candidate],
                installErrorAfterWrite: NudgeFailure.afterCanonicalWrite
            ),
            notifier: { nudgeCount += 1 }
        )
        await partialModel.fetchAndReport()
        await partialModel.installSelectedAndReport(context: context)
        XCTAssertEqual(nudgeCount, 1)

        nudgeCount = 0
        let pureFailureModel = Self.installModel(
            service: NudgeInstallService(
                candidates: [candidate],
                installErrorBeforeWrite: NudgeFailure.beforeCanonicalWrite
            ),
            notifier: { nudgeCount += 1 }
        )
        await pureFailureModel.fetchAndReport()
        await pureFailureModel.installSelectedAndReport(context: context)
        XCTAssertEqual(nudgeCount, 0)
    }

    func testAdoptThrowAfterManifestWriteNudges() async throws {
        let container = try AppRuntime.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let target = Skill(name: "Target", skillDescription: "Description", directoryName: "target")
        context.insert(target)
        try context.save()
        let candidate = Self.installCandidate(slug: "target")
        var nudgeCount = 0
        let model = Self.installModel(
            service: NudgeInstallService(
                candidates: [candidate],
                adoptErrorAfterWrite: NudgeFailure.afterCanonicalWrite
            ),
            notifier: { nudgeCount += 1 }
        )
        model.prepareAdoption(of: target)
        model.urlText = "https://github.com/example/fixture"
        await model.fetchAndReport()
        await model.confirmAndReport(context: context)
        XCTAssertEqual(nudgeCount, 1)
    }

    func testCanceledInstallStillNudgesOnAtomicCompletion() async throws {
        let container = try AppRuntime.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        var nudgeCount = 0
        let installed = Self.installCandidate(slug: "installed")
        let started = expectation(description: "install entered atomic service call")
        let lateNudge = expectation(description: "completed canceled install nudged")
        let release = TestWait.Gate(owner: self)
        let lateModel = Self.installModel(
            service: NudgeInstallService(candidates: [installed], beforeInstallReturn: {
                started.fulfill()
                try release.wait()
            }),
            notifier: {
                nudgeCount += 1
                lateNudge.fulfill()
            }
        )
        await lateModel.fetchAndReport()
        lateModel.installSelected(context: context)
        await fulfillment(of: [started], timeout: TestWait.hostedActionTimeoutSeconds)
        lateModel.cancel()
        release.open()
        await fulfillment(of: [lateNudge], timeout: TestWait.hostedActionTimeoutSeconds)
        XCTAssertEqual(nudgeCount, 1)
    }

    func testCanceledAdoptionStillNudgesOnAtomicCompletion() async throws {
        let container = try AppRuntime.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        var nudgeCount = 0
        let installed = Self.installCandidate(slug: "installed")
        let target = Skill(name: "Target", skillDescription: "Description", directoryName: "target")
        target.installedOriginData = Data("old-origin".utf8)
        context.insert(target)
        try context.save()
        let adoptionStarted = expectation(description: "targeted adoption entered atomic service call")
        let adoptionNudge = expectation(description: "completed canceled targeted adoption nudged")
        let adoptionRelease = TestWait.Gate(owner: self)
        let adoptionModel = Self.installModel(
            service: NudgeInstallService(candidates: [installed], beforeAdoptReturn: {
                adoptionStarted.fulfill()
                try adoptionRelease.wait()
            }),
            notifier: {
                nudgeCount += 1
                adoptionNudge.fulfill()
            }
        )
        adoptionModel.prepareAdoption(of: target)
        adoptionModel.urlText = "https://github.com/example/fixture"
        await adoptionModel.fetchAndReport()
        adoptionModel.confirm(context: context)
        await fulfillment(of: [adoptionStarted], timeout: TestWait.hostedActionTimeoutSeconds)
        adoptionModel.cancel()
        adoptionRelease.open()
        await fulfillment(of: [adoptionNudge], timeout: TestWait.hostedActionTimeoutSeconds)
        XCTAssertEqual(nudgeCount, 1)
    }

    func testCompletedCanceledUpdateNudges() async throws {
        let container = try AppRuntime.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let skill = Skill(name: "Updated", skillDescription: "Description", directoryName: "updated")
        skill.installedOriginData = Data("origin".utf8)
        context.insert(skill)
        try context.save()
        let row = UpdatesRow(
            id: skill.id, skillName: "Updated", slug: "updated",
            installedDate: Date(timeIntervalSince1970: 1), installedCommit: "1111111",
            updateDate: Date(timeIntervalSince1970: 2), upstreamCommit: "2222222",
            upstreamTree: "tree", repositoryDisplay: "example/repo",
            repositoryPath: "skills/updated", driftedLocally: false, compareURL: nil
        )
        let started = expectation(description: "update entered atomic service call")
        let lateNudge = expectation(description: "completed canceled update nudged")
        let release = TestWait.Gate(owner: self)
        var nudgeCount = 0
        let model = UpdatesViewModel(
            rowLoader: { _ in [row] },
            applyOperation: { id, _, _, _, _, _ in
                started.fulfill()
                try release.wait()
                return SkillUpdateCompletion(
                    skillID: id, name: "Updated", skillDescription: "Canceled description",
                    installedOriginData: Data("canceled-origin".utf8), updatedAt: Date()
                )
            },
            diffOperation: { _, _, _, _ in throw SkillUpdateFlowError.skillNotFound },
            recheckOperation: { _, _ in throw SkillUpdateFlowError.skillNotFound },
            notifier: {
                nudgeCount += 1
                lateNudge.fulfill()
            }
        )
        await model.loadAndReport(context: context)
        model.applySelected(context: context)
        await fulfillment(of: [started], timeout: TestWait.hostedActionTimeoutSeconds)
        model.cancel()
        release.open()
        await fulfillment(of: [lateNudge], timeout: TestWait.hostedActionTimeoutSeconds)
        XCTAssertEqual(nudgeCount, 1)
    }

    private static func installCandidate(slug: String) -> SkillCandidate {
        SkillCandidate(
            path: "skills/" + slug, slug: slug, name: slug.capitalized,
            skillDescription: "Description", treeHash: slug + "-tree", containsSymlink: false,
            unavailableReason: nil
        )
    }

    private static func installModel(
        service: SkillInstallServiceProtocol,
        notifier: @escaping SyncStateNotifying,
        echoRegistrar: @escaping SyncWriteEchoRegistering = SyncWriteEchoRegistrar.suppressed,
        bodyWriteRegistration: SyncBodyWriteRegistration = .suppressed
    ) -> SkillInstallViewModel {
        let model = SkillInstallViewModel(
            service: service,
            parser: { _ in .success(SkillInstallURL(
                // A github.com repo shape: beginTargetedAdoption requires a non-nil
                // repositoryIdentity, which only that host produces.
                repo: "https://github.com/example/fixture",
                cloneRemote: "https://github.com/example/fixture",
                ref: nil, path: nil, form: .repo
            )) },
            notifier: notifier,
            echoRegistrar: echoRegistrar,
            bodyWriteRegistration: bodyWriteRegistration
        )
        model.urlText = "https://github.com/example/fixture"
        return model
    }

    private static func bodyRegistration(
        for library: SkillLibraryViewModel
    ) -> SyncBodyWriteRegistration {
        SyncBodyWriteRegistration(
            begin: { library.beginAppAuthoredBodyWrite(directoryName: $0, expectedBody: $1) },
            end: { library.finishAppAuthoredBodyWrite(directoryName: $0, succeeded: $1) }
        )
    }

    private static func installEchoFixture(
        notifier: @escaping SyncStateNotifying
    ) -> InstallEchoFixture {
        let store = InstallEchoSkillStore()
        let watcher = InstallEchoWatcher()
        let library = SkillLibraryViewModel(
            skillStore: store, fileWatchService: watcher, notifier: notifier
        )
        return InstallEchoFixture(store: store, watcher: watcher, library: library)
    }
}
