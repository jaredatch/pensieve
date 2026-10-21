import AppKit
import Darwin
import SwiftData
import SwiftUI
import XCTest
@testable import Pensieve

extension SkillInstallServiceTests {
    @MainActor
    func testReadErrorMidCopyKeepsInstalledFolderAndReportsError() throws {
        try NativeTestWork.run { [self] in try assertReadErrorMidCopyKeepsInstalledFolderAndReportsError() }
    }

    @MainActor
    private func assertReadErrorMidCopyKeepsInstalledFolderAndReportsError() throws {
        let repository = try makeVendorFixture()
        let fetched = try service.fetch(repo: repository, ref: nil, credential: nil)
        let candidate = try XCTUnwrap(fetched.candidates.first)
        let root = tempDir + "/failure-store"
        let context = try makeInstallContext()
        let installer = makeInstallService(root: root)
        let library = echoLibrary(root: root)
        let registration = echoRegistration(library)
        _ = try installer.install(candidate: candidate, from: fetched, bodyWriteRegistration: registration, context: context)
        let original = try library.skillStore.readBody(directoryName: "vendor")
        try writeSkill("skills/vendor", name: "Vendor", description: "Incoming failure", in: repository)
        let beforeHash = try installer.stableContentHash(at: root + "/skills/vendor")
        let origin = try XCTUnwrap(try context.fetch(FetchDescriptor<Skill>()).first?.installedOrigin)
        try fileService.writeData(at: repository + "/skills/vendor/assets/fault.bin",
                                  data: Data(repeating: 42, count: 128 * 1_024))
        try commit(repository, message: "add asset")
        let updated = try service.fetch(repo: repository, ref: nil, credential: nil)
        let updatedCandidate = try XCTUnwrap(updated.candidates.first)
        var copiedBytes = 0
        let spy = midCopyFailure(bytes: { copiedBytes }, copied: { copiedBytes += $0 })
        let faulty = makeInstallService(root: root, using: spy)
        for updating in [false, true] {
            copiedBytes = 0
            XCTAssertThrowsError(try {
                if updating {
                    try faulty.update(existingSlug: "vendor", candidate: updatedCandidate, from: updated,
                        bodyWriteRegistration: registration, context: context)
                } else {
                    _ = try faulty.install(candidate: updatedCandidate, renamedTo: "new-vendor",
                                           from: updated, bodyWriteRegistration: registration, context: context)
                }
            }()) {
                XCTAssertEqual(($0 as NSError).domain, NSPOSIXErrorDomain)
                XCTAssertEqual(($0 as NSError).code, Int(EIO))
            }
            XCTAssertEqual(copiedBytes, 64 * 1_024)
            XCTAssertFalse(fileService.directoryExists(at: root + "/skills/new-vendor"))
        }
        XCTAssertTrue(library.wasLastWrittenByApp(directoryName: "vendor", currentBody: original))
        XCTAssertNil(library.withFingerprintLock { library.lastWrittenBody["new-vendor"] })
        XCTAssertEqual(try installer.stableContentHash(at: root + "/skills/vendor"), beforeHash)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Skill>()).first?.installedOrigin, origin)
        try assertNoVendorTemps(root: root)
        let lock = try XCTUnwrap(SyncLock.tryAcquire(at: root + "-sync.lock"))
        lock.release()
    }

    @MainActor
    func testCancelledInstallAndUpdateJoinCopyCleanupKeepLockAndSuppressWindowCompletion() async throws {
        let repository = try makeVendorFixture()
        try fileService.writeData(at: repository + "/skills/vendor/assets/fault.bin",
                                  data: Data(repeating: 42, count: 128 * 1_024))
        try commit(repository, message: "large asset")
        let fetched = try NativeTestWork.run { [self] in try service.fetch(repo: repository, ref: nil, credential: nil) }
        for updating in [false, true] {
            try await assertCancelledCopy(updating: updating, repository: repository, fetched: fetched)
        }
    }

    @MainActor
    private func assertCancelledCopy(updating: Bool, repository: String, fetched: SkillFetchResult) async throws {
        let root = tempDir + (updating ? "/cancel-update" : "/cancel-install")
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let library = echoLibrary(root: root)
        let registration = echoRegistration(library)
        var source = fetched
        let original = updating ? try seedCancellationUpdate(root: root, source: fetched, context: context,
                                                             library: library, repository: repository) : nil
        if updating {
            source = try NativeTestWork.run { [self] in try service.fetch(repo: repository, ref: nil, credential: nil) }
        }
        let gate = TestWait.Gate(owner: self)
        let spy = ImportPublicationFileService()
        var held = false
        spy.copyCheckpoint = { path, _ in
            if path.hasSuffix("/fault.bin"), !held { held = true; try gate.wait() }
        }
        let cancellable = makeInstallService(root: root, using: spy)
        if updating {
            try await assertUpdateCancellation(service: cancellable, source: source,
                context: context, gate: gate, library: library)
        } else {
            try await assertInstallCancellation(service: cancellable, repository: repository,
                context: context, gate: gate, root: root, registration: registration)
        }
        if let original {
            XCTAssertTrue(library.wasLastWrittenByApp(directoryName: "vendor", currentBody: original.document))
            XCTAssertEqual(try makeInstallService(root: root).stableContentHash(at: root + "/skills/vendor"), original.hash)
        } else {
            XCTAssertNil(library.withFingerprintLock { library.lastWrittenBody["vendor"] })
            XCTAssertFalse(fileService.directoryExists(at: root + "/skills/vendor"))
            XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<Skill>()).isEmpty)
        }
        XCTAssertTrue(held, "Cancel must arrive after a descriptor chunk was copied")
        try assertNoVendorTemps(root: root)
        let lock = try XCTUnwrap(SyncLock.tryAcquire(at: root + "-sync.lock"))
        lock.release()
    }

    @MainActor
    private func seedCancellationUpdate(root: String, source: SkillFetchResult, context: ModelContext,
                                        library: SkillLibraryViewModel, repository: String) throws
        -> (document: String, hash: String) {
        let installer = makeInstallService(root: root)
        let registration = echoRegistration(library)
        _ = try NativeTestWork.run(container: context.container) { [self] jobContext in
            try installer.install(candidate: XCTUnwrap(source.candidates.first), from: source,
                bodyWriteRegistration: registration, context: jobContext)
        }
        let original = try library.skillStore.readBody(directoryName: "vendor")
        let hash = try installer.stableContentHash(at: root + "/skills/vendor")
        try NativeTestWork.run { [self] in
            try writeSkill("skills/vendor", name: "Vendor", description: "Incoming cancellation", in: repository)
            try commit(repository)
        }
        return (original, hash)
    }

    private func midCopyFailure(bytes: @escaping () -> Int, copied: @escaping (Int) -> Void) -> ImportPublicationFileService {
        let spy = ImportPublicationFileService()
        spy.read = { descriptor, buffer, requested in
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            XCTAssertEqual(fcntl(descriptor, F_GETPATH, &path), 0)
            if String(cString: path).hasSuffix("/fault.bin") {
                if bytes() > 0 { errno = EIO; return -1 }
                let count = Darwin.read(descriptor, buffer, requested)
                if count > 0 { copied(count) }
                return count
            }
            return Darwin.read(descriptor, buffer, requested)
        }
        return spy
    }

    private func echoLibrary(root: String) -> SkillLibraryViewModel {
        SkillLibraryViewModel(skillStore: SkillStore(fileService: fileService, baseDir: root + "/skills", storeRoot: root),
            fileWatchService: RecordingWatcher(), manifestRoot: root)
    }

    private func echoRegistration(_ library: SkillLibraryViewModel) -> SyncBodyWriteRegistration {
        SyncBodyWriteRegistration(begin: library.beginAppAuthoredBodyWrite,
            end: { library.finishAppAuthoredBodyWrite(directoryName: $0, succeeded: $1) })
    }

    @MainActor
    private func assertInstallCancellation(service: SkillInstallService, repository: String,
                                           context: ModelContext, gate: TestWait.Gate, root: String,
                                           registration: SyncBodyWriteRegistration) async throws {
        let model = SkillInstallViewModel(service: service, parser: { _ in
            .success(SkillInstallURL(repo: repository, cloneRemote: repository, ref: nil, path: nil, form: .repo))
        }, bodyWriteRegistration: registration)
        model.urlText = "fixture"
        await model.fetchAndReport()
        XCTAssertEqual(model.state, .picking)
        let host = NSHostingView(rootView: AnyView(AddFromGitHubSheet(model: model).environment(\.modelContext, context)))
        model.installSelected(context: context)
        let task = try XCTUnwrap(model.operationTask)
        defer { gate.open() }
        await TestWait.until(failureMessage: "Install did not reach the mid-copy gate") { gate.waiterCount == 1 }
        model.cancel()
        XCTAssertNil(SyncLock.tryAcquire(at: root + "-sync.lock"), "Cancel cannot release a copying worker's lock")
        gate.open()
        await TestWait.forTask(task, failureMessage: "Cancelled install did not finish cleanup")
        XCTAssertEqual(model.state, .idle)
        XCTAssertTrue(model.reports.isEmpty)
        await assertNoCompletionRendered(host, expected: "Add Skills from GitHub", forbidden: ["Install Results"])
    }

    @MainActor
    private func assertUpdateCancellation(service: SkillInstallService, source: SkillFetchResult,
                                          context: ModelContext, gate: TestWait.Gate,
                                          library: SkillLibraryViewModel) async throws {
        let root = library.manifestRoot
        let registration = echoRegistration(library)
        let candidate = try XCTUnwrap(source.candidates.first)
        let skill = try XCTUnwrap(try context.fetch(FetchDescriptor<Skill>()).first)
        let row = UpdatesRow(id: skill.id, skillName: skill.name, slug: "vendor", installedCommit: source.headCommit,
            updateDate: Date(), upstreamCommit: source.headCommit, upstreamTree: candidate.treeHash,
            repositoryDisplay: "fixture/vendor", repositoryPath: candidate.path, driftedLocally: false, compareURL: nil)
        let model = UpdatesViewModel(rowLoader: { _ in [row] }, applyOperation: { _, _, _, _, writeRegistration, container in
            let worker = ModelContext(container)
            try NativeTestWork.run(container: worker.container) { [self] jobContext in
                try service.update(existingSlug: "vendor", candidate: candidate, from: source,
                    bodyWriteRegistration: writeRegistration, context: jobContext)
            }
            let updated = try XCTUnwrap(try worker.fetch(FetchDescriptor<Skill>()).first)
            return SkillUpdateCompletion(skillID: updated.id, name: updated.name,
                skillDescription: updated.skillDescription, installedOriginData: updated.installedOriginData ?? Data(),
                updatedAt: updated.updatedAt)
        }, recheckOperation: { _, _ in throw CocoaError(.featureUnsupported) }, bodyWriteRegistration: registration)
        await model.loadAndReport(context: context)
        let host = NSHostingView(rootView: AnyView(UpdatesView(model: model, onViewChanges: { _ in })
            .environment(\.modelContext, context)))
        model.applySelected(context: context)
        let task = try XCTUnwrap(model.operationTask)
        defer { gate.open() }
        await TestWait.until(failureMessage: "Update did not reach the mid-copy gate") { gate.waiterCount == 1 }
        model.cancel()
        XCTAssertNil(SyncLock.tryAcquire(at: root + "-sync.lock"))
        gate.open()
        await TestWait.forTask(task, failureMessage: "Cancelled update did not finish cleanup")
        XCTAssertFalse(model.isApplying)
        XCTAssertEqual(model.status(for: row), .updating, "A cancelled completion cannot become updated or failed")
        await assertNoCompletionRendered(host, expected: "Vendor", forbidden: ["Updated", "Input/output error"])
    }

    @MainActor
    private func assertNoCompletionRendered(_ host: NSHostingView<AnyView>, expected: String,
                                            forbidden: [String]) async {
        host.frame = NSRect(x: 0, y: 0, width: 680, height: 520)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = host
        defer { window.close() }
        await TestWait.until(failureMessage: "The cancelled window must still render its current state") {
            RenderedViewTestSupport.values(in: host).compactMap { $0 as? Text }
                .flatMap { RenderedViewTestSupport.strings(in: $0) }.contains(expected)
        }
        let strings = RenderedViewTestSupport.values(in: host).compactMap { $0 as? Text }
            .flatMap { RenderedViewTestSupport.strings(in: $0) }
        for value in forbidden { XCTAssertFalse(strings.contains(value)) }
    }
}
