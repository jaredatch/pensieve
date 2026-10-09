import AppKit
import Darwin
import SwiftData
import SwiftUI
import XCTest
@testable import Pensieve

extension SkillInstallServiceTests {
    @MainActor
    func testReadErrorMidCopyKeepsInstalledFolderAndReportsError() throws {
        let repository = try makeVendorFixture()
        let fetched = try service.fetch(repo: repository, ref: nil, credential: nil)
        let candidate = try XCTUnwrap(fetched.candidates.first)
        let root = tempDir + "/failure-store"
        let context = try makeInstallContext()
        let installer = makeInstallService(root: root)
        _ = try installer.install(candidate: candidate, from: fetched, context: context)
        let beforeHash = try installer.stableContentHash(at: root + "/skills/vendor")
        let origin = try XCTUnwrap(try context.fetch(FetchDescriptor<Skill>()).first?.installedOrigin)
        try fileService.writeData(at: repository + "/skills/vendor/assets/fault.bin",
                                  data: Data(repeating: 42, count: 128 * 1_024))
        try commit(repository, message: "add asset")
        let updated = try service.fetch(repo: repository, ref: nil, credential: nil)
        let updatedCandidate = try XCTUnwrap(updated.candidates.first)
        let spy = ImportPublicationFileService()
        var copiedBytes = 0
        spy.read = { descriptor, buffer, requested in
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            XCTAssertEqual(fcntl(descriptor, F_GETPATH, &path), 0)
            if String(cString: path).hasSuffix("/fault.bin") {
                if copiedBytes > 0 { errno = EIO; return -1 }
                let count = Darwin.read(descriptor, buffer, requested)
                if count > 0 { copiedBytes += count }
                return count
            }
            return Darwin.read(descriptor, buffer, requested)
        }
        let faulty = makeInstallService(root: root, using: spy)
        for updating in [false, true] {
            copiedBytes = 0
            XCTAssertThrowsError(try {
                if updating {
                    try faulty.update(existingSlug: "vendor", candidate: updatedCandidate, from: updated, context: context)
                } else {
                    _ = try faulty.install(candidate: updatedCandidate, renamedTo: "new-vendor",
                                           from: updated, context: context)
                }
            }()) {
                XCTAssertEqual(($0 as NSError).domain, NSPOSIXErrorDomain)
                XCTAssertEqual(($0 as NSError).code, Int(EIO))
            }
            XCTAssertEqual(copiedBytes, 64 * 1_024)
            XCTAssertFalse(fileService.directoryExists(at: root + "/skills/new-vendor"))
        }
        XCTAssertEqual(try installer.stableContentHash(at: root + "/skills/vendor"), beforeHash)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Skill>()).first?.installedOrigin, origin)
        XCTAssertFalse(try fileService.listDirectory(at: tempDir).contains { $0.hasPrefix("failure-store.vendor-") })
        let lock = try XCTUnwrap(SyncLock.tryAcquire(at: root + "-sync.lock"))
        lock.release()
    }

    @MainActor
    func testCancelledInstallAndUpdateJoinCopyCleanupKeepLockAndSuppressWindowCompletion() async throws {
        let repository = try makeVendorFixture()
        try fileService.writeData(at: repository + "/skills/vendor/assets/fault.bin",
                                  data: Data(repeating: 42, count: 128 * 1_024))
        try commit(repository, message: "large asset")
        let fetched = try service.fetch(repo: repository, ref: nil, credential: nil)
        let candidate = try XCTUnwrap(fetched.candidates.first)
        for updating in [false, true] {
            let root = tempDir + (updating ? "/cancel-update" : "/cancel-install")
            let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
            let context = container.mainContext
            let installer = makeInstallService(root: root)
            var beforeHash: String?
            if updating {
                _ = try installer.install(candidate: candidate, from: fetched, context: context)
                beforeHash = try installer.stableContentHash(at: root + "/skills/vendor")
            }
            let gate = TestWait.Gate(owner: self)
            let spy = ImportPublicationFileService()
            var held = false
            spy.copyCheckpoint = { path, _ in
                if path.hasSuffix("/fault.bin"), !held {
                    held = true
                    try gate.wait()
                }
            }
            let cancellable = makeInstallService(root: root, using: spy)
            if updating {
                try await assertUpdateCancellation(service: cancellable, candidate: candidate, source: fetched,
                                                   context: context, gate: gate, root: root)
            } else {
                try await assertInstallCancellation(service: cancellable, repository: repository,
                                                    context: context, gate: gate, root: root)
            }
            XCTAssertTrue(held, "Cancel must arrive after a descriptor chunk was copied")
            if let beforeHash {
                XCTAssertEqual(try installer.stableContentHash(at: root + "/skills/vendor"), beforeHash)
            } else {
                XCTAssertFalse(fileService.directoryExists(at: root + "/skills/vendor"))
                XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<Skill>()).isEmpty)
            }
            XCTAssertFalse(try fileService.listDirectory(at: tempDir).contains {
                $0.hasPrefix((root as NSString).lastPathComponent + ".vendor-")
            })
            let lock = try XCTUnwrap(SyncLock.tryAcquire(at: root + "-sync.lock"))
            lock.release()
        }
    }

    @MainActor
    private func assertInstallCancellation(service: SkillInstallService, repository: String,
                                           context: ModelContext, gate: TestWait.Gate, root: String) async throws {
        let model = SkillInstallViewModel(service: service, parser: { _ in
            .success(SkillInstallURL(repo: repository, cloneRemote: repository, ref: nil, path: nil, form: .repo))
        })
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
    private func assertUpdateCancellation(service: SkillInstallService, candidate: SkillCandidate,
                                          source: SkillFetchResult, context: ModelContext,
                                          gate: TestWait.Gate, root: String) async throws {
        let skill = try XCTUnwrap(try context.fetch(FetchDescriptor<Skill>()).first)
        let row = UpdatesRow(id: skill.id, skillName: skill.name, slug: "vendor", installedCommit: source.headCommit,
            updateDate: Date(), upstreamCommit: source.headCommit, upstreamTree: candidate.treeHash,
            repositoryDisplay: "fixture/vendor", repositoryPath: candidate.path, driftedLocally: false, compareURL: nil)
        let model = UpdatesViewModel(rowLoader: { _ in [row] }, applyOperation: { _, _, _, _, _, container in
            let worker = ModelContext(container)
            try service.update(existingSlug: "vendor", candidate: candidate, from: source, context: worker)
            let updated = try XCTUnwrap(try worker.fetch(FetchDescriptor<Skill>()).first)
            return SkillUpdateCompletion(skillID: updated.id, name: updated.name,
                skillDescription: updated.skillDescription, installedOriginData: updated.installedOriginData ?? Data(),
                updatedAt: updated.updatedAt)
        }, recheckOperation: { _, _ in throw CocoaError(.featureUnsupported) })
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
