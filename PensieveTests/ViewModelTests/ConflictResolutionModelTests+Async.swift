import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Pensieve

extension ConflictResolutionModelTests {
    func testHeldLoadCancelFinishesRepositoryAndClearedRuntimeAfterDismissal() async throws {
        for cleared in [false, true] {
            let fixture = try NativeTestWork.run {
                try SyncConflictByteFixture(name: "load.txt", this: Data("this\n".utf8), other: Data("other\n".utf8))
            }
            defer { try? fixture.files.deleteDirectory(at: fixture.root) }
            if cleared { try clearConflict(fixture) }
            let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
            let convergence = ConflictConvergenceSpy()
            let runtime = try AppRuntime(container: container,
                scheduler: SyncScheduler(startAutomatically: false, backgroundSyncEnabled: { false }),
                defaults: isolatedDefaults("held-conflict-\(cleared)"), postSyncConvergence: convergence,
                paths: AppRuntimePaths(storeRoot: fixture.storeB, appSupportDir: fixture.root + "/support"),
                gitUsabilityProbe: { .usable })
            await runtime.bootstrapTask.value
            runtime.library.setLaunchIngestPending(false)
            runtime.library.applySyncCycleOutcome(.storeUnreadable("held load"))
            runtime.syncModel.apply(.conflicted([fixture.path]))
            let block = try GitBlockingFixture()
            defer { block.release(); try? block.cleanup() }
            let engine = HeldConflictEngine(engine: fixture.engine, block: block, holdLoad: true,
                                            windowContext: container.mainContext)
            let model = ConflictResolutionModel(engine: engine, git: fixture.git,
                credentials: InMemoryCredentialStore(), root: fixture.storeB, steps: runtime.paths.syncSteps,
                onResolutionStarted: runtime.beginConflictResolution)
            var dismissed = false
            let host = conflictHost(model: model, container: container, runtime: runtime) { dismissed = true }
            defer { host.window.close(); runtime.library.stopWatching() }
            await TestWait.until(failureMessage: "Conflict load did not enter native git") { block.isBlocked }
            await TestWait.until(failureMessage: "Held load did not render progress") {
                Self.conflictHasProgress(in: host.view)
            }
            XCTAssertEqual(runtime.paths.syncSteps.pendingCount, 1)
            XCTAssertTrue(conflictKey("\u{1b}", code: 53, in: host.view))
            await TestWait.until(failureMessage: "Cancel did not dismiss the held load") { dismissed }
            host.window.close()
            XCTAssertEqual(runtime.paths.syncSteps.pendingCount, 1, "Closing must not cancel the writing load")
            block.release()
            await runtime.paths.syncSteps.waitUntilIdle()
            XCTAssertEqual(model.phase, .loading, "A dismissed presentation must drop its sheet result")
            try NativeTestWork.run {
                XCTAssertFalse(fixture.git.isRebaseInProgress(at: fixture.storeB))
                XCTAssertTrue(try fixture.git.isWorktreeClean(at: fixture.storeB))
                XCTAssertEqual(try fixture.git.runOrThrow(["branch", "--show-current"], in: fixture.storeB).stdout,
                               "main\n")
            }
            XCTAssertEqual(convergence.results.count, cleared ? 1 : 0)
            XCTAssertEqual(runtime.library.addsFenced, !cleared)
            XCTAssertEqual(runtime.syncModel.isConflicted, !cleared)
        }
    }

    func testReopenedRuntimeConflictSheetJoinsHeldLoad() async throws {
        let fixture = try NativeTestWork.run {
            try SyncConflictByteFixture(name: "reopen.txt", this: Data("this\n".utf8), other: Data("other\n".utf8))
        }
        defer { try? fixture.files.deleteDirectory(at: fixture.root) }
        let block = try GitBlockingFixture()
        defer { block.release(); try? block.cleanup() }
        // Git's SSH transport executes a local upload-pack, so the production runtime and engine
        // inspect the real repository without either a network connection or a model injection seam.
        let ssh = fixture.root + "/local-ssh"
        try fixture.files.writeExecutableFile(at: ssh, content: """
            #!/bin/bash
            '\(block.root)/git' >/dev/null || exit 1
            exec /usr/bin/git-upload-pack '\(fixture.remote)'
            """ + "\n")
        try NativeTestWork.run {
            try fixture.git.setRemote("ssh://fixture.invalid/library", at: fixture.storeB)
            try fixture.git.runOrThrow(["config", "core.sshCommand", ssh], in: fixture.storeB)
            try fixture.git.runOrThrow(["config", "ssh.variant", "ssh"], in: fixture.storeB)
        }
        let runtime = try AppRuntime(container: fixture.contextB.container,
            scheduler: SyncScheduler(startAutomatically: false, backgroundSyncEnabled: { false }),
            defaults: isolatedDefaults("reopened-conflict"),
            paths: AppRuntimePaths(storeRoot: fixture.storeB, appSupportDir: fixture.root + "/runtime-support"),
            gitUsabilityProbe: { .usable })
        await runtime.bootstrapTask.value
        runtime.syncModel.apply(.conflicted([fixture.path]))
        let first = conflictHost(model: runtime.conflictResolution, container: runtime.container, runtime: runtime) {}
        defer { first.window.close(); runtime.library.stopWatching() }
        await TestWait.until(failureMessage: "Initial conflict inspection never reached SSH") { block.isBlocked }
        runtime.conflictResolution.dismiss()
        first.window.close()
        let reopened = conflictHost(model: runtime.conflictResolution, container: runtime.container, runtime: runtime) {}
        defer { reopened.window.close() }
        await TestWait.until(failureMessage: "Reopened sheet did not show its held load") {
            Self.conflictHasProgress(in: reopened.view)
        }
        XCTAssertEqual(runtime.paths.syncSteps.pendingCount, 1, "Reopening joins the original inspection")
        block.release()
        await runtime.paths.syncSteps.waitUntilIdle()
        let groups = try readyGroups(from: runtime.conflictResolution.phase)
        XCTAssertEqual(groups.flatMap(\.items).map(\.path), [fixture.path])
        await TestWait.until(failureMessage: "Reopened sheet never rendered the original load's choices") {
            RenderedViewTestSupport.values(in: reopened.view).compactMap { $0 as? Text }
                .flatMap(RenderedViewTestSupport.strings).contains("Keep This Mac")
        }
        try NativeTestWork.run {
            XCTAssertFalse(fixture.git.isRebaseInProgress(at: fixture.storeB))
            XCTAssertTrue(try fixture.git.isWorktreeClean(at: fixture.storeB))
        }
    }

    func testHeldApplyRendersButtonProgressDisablesCancelAndPreservesSelectedBytes() async throws {
        let cases: [(name: String, bytes: (this: Data?, other: Data?))] = [
            ("text.txt", (Data("this text\n".utf8), Data("other text\n".utf8))),
            ("binary.bin", (Data([0, 255, 128]), Data([0, 254, 129]))),
            ("deleted.txt", (nil, Data("other survives\n".utf8)))
        ]
        for (name, bytes) in cases {
            let (this, other) = bytes
            let fixture = try NativeTestWork.run { try SyncConflictByteFixture(name: name, this: this, other: other) }
            defer { try? fixture.files.deleteDirectory(at: fixture.root) }
            let history = try ConflictHistoryFixture(test: self)
            defer { try? history.remove() }
            await history.runtime.bootstrapTask.value
            let block = try GitBlockingFixture()
            defer { block.release(); try? block.cleanup() }
            let steps = SyncStepModel()
            let engine = HeldConflictEngine(engine: fixture.engine, block: block, holdLoad: false,
                                            windowContext: fixture.contextB)
            let model = ConflictResolutionModel(engine: engine, git: fixture.git,
                credentials: InMemoryCredentialStore(), root: fixture.storeB, steps: steps)
            var dismissed = false
            let host = conflictHost(model: model, container: fixture.contextB.container, runtime: history.runtime) {
                dismissed = true
            }
            defer { host.window.close() }
            await TestWait.until(failureMessage: "Conflict load did not finish") { model.canCancel && model.phase != .loading }
            for group in try readyGroups(from: model.phase) { model.choose(group.id, .thisMachine) }
            await TestWait.until(failureMessage: "Keep selected shortcut did not become enabled") {
                self.conflictKey("\r", code: 36, in: host.view)
            }
            await TestWait.until(failureMessage: "Conflict apply did not enter native git") { block.isBlocked }
            await TestWait.until(failureMessage: "Keep selected did not render its button spinner") {
                RenderedViewTestSupport.hasButtonProgress(in: host.view)
            }
            XCTAssertFalse(model.canCancel)
            XCTAssertFalse(conflictKey("\u{1b}", code: 53, in: host.view))
            XCTAssertFalse(dismissed)
            XCTAssertEqual(steps.pendingCount, 1)
            block.release()
            await steps.waitUntilIdle()
            XCTAssertEqual(model.phase, .done)
            try NativeTestWork.run { try fixture.assertPublished(this) }
        }
    }

    func testQuitWaitsForHeldConflictLoadAndApplyOrAcceptsQuitAnyway() async throws {
        for load in [true, false] {
            for quitAnyway in [false, true] {
                let block = try GitBlockingFixture()
                defer { block.release(); try? block.cleanup() }
                let stub = StubResolutionEngine()
                stub.inspections = [.conflicts(ConflictSet(items: [bodyItem(slug: "quit")]))]
                let context = try makeContext()
                let steps = SyncStepModel()
                let engine = HeldConflictEngine(engine: stub, block: block, holdLoad: load, windowContext: context)
                let model = ConflictResolutionModel(engine: engine, git: TestPaths.git,
                    credentials: InMemoryCredentialStore(), root: block.root, steps: steps)
                if load { model.load(container: context.container) } else {
                    await model.loadAndReport(container: context.container)
                    model.choose("skill:quit", .thisMachine)
                    model.apply(container: context.container)
                }
                XCTAssertEqual(steps.pendingCount, 1, "Quit registration must precede task scheduling")
                await TestWait.until(failureMessage: "Conflict work did not block") { block.isBlocked }
                var question: ((Bool) -> Void)?
                let quit = PendingSaveTermination(delay: 0.02, present: { _, resolve in
                    question = resolve
                    return .init(update: { _ in true }, dismiss: {})
                })
                var answers: [Bool] = []
                let reply = PensieveAppDelegate.terminationReply(hasUnsavedChanges: false, questionOpen: false,
                    confirm: { _ in XCTFail("No draft") }, reply: { answers.append($0) },
                    saveTermination: quit, steps: steps)
                XCTAssertEqual(reply, .terminateLater)
                await TestWait.until(failureMessage: "Held conflict work did not show the quit question") { question != nil }
                XCTAssertTrue(answers.isEmpty)
                try XCTUnwrap(question)(quitAnyway)
                XCTAssertEqual(answers, quitAnyway ? [true] : [])
                XCTAssertEqual(steps.pendingCount, 1)
                block.release()
                await steps.waitUntilIdle()
                await TestWait.until(failureMessage: "Quit did not finish after conflict work") { answers == [true] }
            }
        }
    }

    private func clearConflict(_ fixture: SyncConflictByteFixture) throws {
        try NativeTestWork.run {
            let items = try fixture.inspectAll()
            let picks = Dictionary(uniqueKeysWithValues: items.map {
                ($0.path, ResolutionPick(side: .otherMachine, expectedThis: $0.thisMachine,
                                        expectedOther: $0.otherMachine))
            })
            _ = try fixture.engine.resolveConflicts(root: fixture.storeB, picks: picks, credential: nil,
                context: ModelContext(fixture.contextB.container))
        }
    }

    private func conflictHost(model: ConflictResolutionModel, container: ModelContainer, runtime: AppRuntime,
                              dismiss: @escaping () -> Void) -> (view: NSHostingView<AnyView>, window: NSWindow) {
        let view = NSHostingView(rootView: AnyView(ConflictResolutionView(model: model, onDismiss: dismiss)
            .environment(runtime).modelContainer(container)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        return (view, window)
    }

    private static func conflictHasProgress(in host: NSHostingView<AnyView>) -> Bool {
        RenderedViewTestSupport.values(in: host).contains {
            String(reflecting: type(of: $0)).hasPrefix("SwiftUI.ProgressView<")
        }
    }

    private func conflictKey(_ key: String, code: UInt16, in root: NSView) -> Bool {
        guard let window = root.window,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: key,
                charactersIgnoringModifiers: key, isARepeat: false, keyCode: code) else { return false }
        root.layoutSubtreeIfNeeded()
        return root.performKeyEquivalent(with: event) || window.performKeyEquivalent(with: event)
    }
}

private final class HeldConflictEngine: SyncEngineProtocol {
    let engine: SyncEngineProtocol
    let block: GitBlockingFixture
    let holdLoad: Bool
    let windowContext: ModelContext
    init(engine: SyncEngineProtocol, block: GitBlockingFixture, holdLoad: Bool, windowContext: ModelContext) {
        self.engine = engine; self.block = block; self.holdLoad = holdLoad; self.windowContext = windowContext
    }
    func sync(root: String, message: String, credential: GitCredential?, context: ModelContext,
              prepare: ((ModelContext) throws -> Void)?) throws -> SyncOutcome {
        try engine.sync(root: root, message: message, credential: credential, context: context, prepare: prepare)
    }
    func inspectConflicts(root: String, credential: GitCredential?, context: ModelContext) throws -> ConflictInspection {
        XCTAssertFalse(Thread.isMainThread)
        XCTAssertFalse(context === windowContext, "The native job must own a new context")
        if holdLoad { try block.run() }
        return try engine.inspectConflicts(root: root, credential: credential, context: context)
    }
    func resolveConflicts(root: String, picks: [String: ResolutionPick], credential: GitCredential?,
                          context: ModelContext) throws -> SyncOutcome {
        XCTAssertFalse(Thread.isMainThread)
        XCTAssertFalse(context === windowContext)
        if !holdLoad { try block.run() }
        return try engine.resolveConflicts(root: root, picks: picks, credential: credential, context: context)
    }
}

@MainActor
private final class ConflictConvergenceSpy: PostSyncConverging {
    var results: [SyncCycleResult] = []
    func run(after result: SyncCycleResult) { results.append(result) }
    func runAfterLaunchIngest() {}
}
