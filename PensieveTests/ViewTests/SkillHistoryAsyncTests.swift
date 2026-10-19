import AppKit
import Observation
import SwiftData
import SwiftUI
import XCTest
@testable import Pensieve

@MainActor
final class SkillHistoryAsyncTests: XCTestCase {
    func testHeldLoadsRenderProgressInSheetAndTab() async throws {
        for sheet in [true, false] {
            let fixture = try fixture()
            let gate = TestWait.Gate(owner: self)
            let entered = expectation(description: "history log held")
            fixture.git.logOperation = { _ in   // held past the progress wait, so a late render can't pass as versions
                XCTAssertFalse(Thread.isMainThread)
                entered.fulfill()
                if !Thread.isMainThread { try? gate.wait(timeout: .seconds(TestWait.heldFixtureTimeoutSeconds)) }
                return [Self.commit("first"), Self.commit("second")]
            }
            fixture.git.documents["first"] = "First body"
            let root: AnyView
            if sheet {
                root = AnyView(SkillHistoryView(skill: fixture.skill, git: fixture.git,
                    store: fixture.store, workingDir: fixture.store.baseDir, library: fixture.library, onDismiss: {}))
            } else {
                root = AnyView(tab(fixture, skill: fixture.skill))
            }
            let host = makeHost(root)
            defer { host.window.close(); gate.open() }
            await fulfillment(of: [entered], timeout: TestWait.firstRenderTimeoutSeconds)
            await TestWait.until(timeout: .seconds(TestWait.firstRenderTimeoutSeconds),
                                 failureMessage: "held History must render its progress indicator", diagnostics: {
                "sheet=\(sheet) visible=\(host.window.isVisible) key=\(host.window.isKeyWindow)"
                    + " nodes=\(RenderedViewTestSupport.values(in: host.view).count) texts=\(Self.texts(in: host.view))"
            }, {
                host.view.needsLayout = true
                return Self.hasProgress(in: host.view) && Self.texts(in: host.view).contains("Loading history…")
            })
            XCTAssertFalse(Self.texts(in: host.view).contains(sheet ? "No history" : "No versions saved yet."))
            gate.open()
            await TestWait.until(failureMessage: "released History never rendered its versions") {
                Self.texts(in: host.view).contains(sheet ? "first · Author" : "first")
            }
        }
    }

    func testLaterSkillLoadReplacesHeldEarlierResult() async throws {
        let fixture = try fixture()
        let model = SkillHistoryTabPresentation()
        let second = Skill(name: "Second", directoryName: "second")
        let gate = TestWait.Gate(owner: self)
        defer { gate.open() }
        let entered = expectation(description: "old load held")
        fixture.git.logOperation = { path in
            XCTAssertFalse(Thread.isMainThread)
            if path.contains("example") {
                entered.fulfill()
                if !Thread.isMainThread { try? gate.wait() }
                return [Self.commit("old")]
            }
            return [Self.commit("new")]
        }
        let old = Task { await model.load(skill: fixture.skill, git: fixture.git, workingDir: "/repo") }
        await fulfillment(of: [entered], timeout: TestWait.timeoutSeconds)
        await model.load(skill: second, git: fixture.git, workingDir: "/repo")
        gate.open()
        await old.value
        XCTAssertEqual(model.snapshot.versions.map(\.sha), ["new"])
        XCTAssertFalse(model.isLoading)

        let oldVersion = SkillHistoryVersion(sha: "old", date: .distantPast, author: "Author", subject: "old")
        let newVersion = SkillHistoryVersion(sha: "new", date: .distantPast, author: "Author", subject: "new")
        let reading = expectation(description: "old row read held")
        let readGate = TestWait.Gate(owner: self)
        defer { readGate.open() }
        fixture.git.showOperation = { sha in
            XCTAssertFalse(Thread.isMainThread)
            if sha == "old" {
                reading.fulfill()
                if !Thread.isMainThread { try? readGate.wait() }
            }
            return sha + " body"
        }
        let oldRead = Task { await model.read(oldVersion, skill: second, git: fixture.git,
            workingDir: "/repo", asDiff: false) }
        await fulfillment(of: [reading], timeout: TestWait.timeoutSeconds)
        await model.read(newVersion, skill: second, git: fixture.git, workingDir: "/repo", asDiff: false)
        readGate.open()
        await oldRead.value
        XCTAssertEqual(model.selection?.sha, "new")
        XCTAssertEqual(model.selection?.previewBody, "new body")
    }

    func testHeldDiffAndRestoreKeepMainActorRunningAndRetainRawRestore() async throws {
        let fixture = try fixture()
        let model = SkillHistoryTabPresentation()
        fixture.git.commits = [Self.commit("version")]
        await model.load(skill: fixture.skill, git: fixture.git, workingDir: "/repo")
        let version = try XCTUnwrap(model.snapshot.versions.first)
        let document = "---\nname: Historical\ndescription: Original\n---\nHistorical body\n"
        for restore in [false, true] {
            let gate = TestWait.Gate(owner: self)
            defer { gate.open() }
            let entered = expectation(description: "show held")
            fixture.git.showOperation = { _ in
                XCTAssertFalse(Thread.isMainThread)
                entered.fulfill()
                if !Thread.isMainThread { try? gate.wait() }
                return document
            }
            let action = Task {
                if restore {
                    return await model.restore(version, skill: fixture.skill, git: fixture.git, workingDir: "/repo",
                        store: fixture.store, library: fixture.library, notifier: {}).value
                }
                await model.read(version, skill: fixture.skill, git: fixture.git, workingDir: "/repo", asDiff: true)
                return true
            }
            await fulfillment(of: [entered], timeout: TestWait.timeoutSeconds)
            XCTAssertEqual(restore ? model.restoringVersion : model.readingVersion, "version")
            XCTAssertEqual(try fixture.store.readBody(directoryName: "example"), "Current")
            gate.open()
            let succeeded = await action.value
            XCTAssertTrue(succeeded)
            if restore {
                XCTAssertEqual(fixture.store.bodies["example"], document)
                XCTAssertEqual(fixture.counter.value, 1)
            } else {
                XCTAssertEqual(model.diff?.body, "Historical body")
            }
        }
    }

    func testHeldRestoreWritesNothingAfterDeletionEditSelectionOrClose() async throws {
        try await assertLaterReadExplainsRetiredRestore()
        let invalidations = ["delete", "file edit", "draft edit", "edit then undo",
                             "immediate edit", "raw bytes", "selection", "close"]
        for invalidation in invalidations {
            let fixture = try fixture()
            let model = SkillHistoryTabPresentation()
            fixture.git.commits = [Self.commit("version")]
            await model.load(skill: fixture.skill, git: fixture.git, workingDir: "/repo")
            let version = try XCTUnwrap(model.snapshot.versions.first)
            let gate = TestWait.Gate(owner: self)
            defer { gate.open() }
            let entered = expectation(description: invalidation)
            fixture.git.showOperation = { _ in
                entered.fulfill()
                if !Thread.isMainThread { try? gate.wait() }
                return "Restored"
            }
            let restore = model.restore(version, skill: fixture.skill, git: fixture.git, workingDir: "/repo",
                store: fixture.store, library: fixture.library, notifier: {})
            if invalidation == "immediate edit" { fixture.library.noteEditorChanged(fixture.skill, body: "New edit") }
            await fulfillment(of: [entered], timeout: TestWait.timeoutSeconds)
            try await invalidateRestore(invalidation, fixture: fixture, model: model)
            let bodyBeforeRelease = fixture.store.bodies["example"]
            gate.open()
            let restored = await restore.value
            XCTAssertFalse(restored, invalidation)
            let message: String
            switch invalidation {
            case "selection": message = "Nothing was restored. You selected another skill before Restore finished."
            case "close": message = "Nothing was restored. History was closed before Restore finished."
            default: message = SkillHistoryTabPresentation.changedRestoreMessage
            }
            if invalidation == "selection" || invalidation == "close" {
                XCTAssertNil(model.errorMessage, "A departed Restore has no message in another skill's History")
                XCTAssertEqual(fixture.library.error, message, "Leaving History must report outside the departed view")
            } else { XCTAssertEqual(model.errorMessage, message, invalidation) }
            XCTAssertEqual(fixture.store.bodies["example"], bodyBeforeRelease, invalidation)
            XCTAssertEqual(fixture.counter.value, 0, invalidation)
            if invalidation == "selection" || invalidation == "close" {
                fixture.git.showOperation = { _ in "Historical" }
                let reopened = SkillHistoryTabPresentation()
                await reopened.load(skill: fixture.skill, git: fixture.git, workingDir: "/repo")
                let fresh = reopened.restore(version, skill: fixture.skill, git: fixture.git, workingDir: "/repo",
                    store: fixture.store, library: fixture.library, notifier: {})
                XCTAssertNil(fixture.library.error, "A new Restore clears its earlier departure warning")
                let restored = await fresh.value
                XCTAssertTrue(restored, invalidation)
            }
        }
        try await assertMissingSkillRefusesRestoreBeforeReading()
    }

    func testRenderedDiffAndSheetRestoreShowSpinnersAndComplete() async throws {
        for sheet in [false, true] {
            let fixture = try fixture()
            fixture.git.commits = [Self.commit("first"), Self.commit("second")]
            fixture.git.documents = ["first": "First body", "second": "Second body"]
            let initialPreview = sheet ? expectation(description: "sheet's initial preview read") : nil
            if let initialPreview {
                fixture.git.showOperation = { sha in
                    initialPreview.fulfill()
                    return sha + " body"
                }
            }
            let state = HistoryAsyncHostState(skill: fixture.skill)
            let host = makeHost(AnyView(HistoryAsyncHarness(state: state, fixture: fixture, sheet: sheet)))
            defer { host.window.close() }
            if let initialPreview { await fulfillment(of: [initialPreview], timeout: TestWait.firstRenderTimeoutSeconds) }
            await TestWait.until(failureMessage: "History did not render its versions") {
                Self.texts(in: host.view).contains(sheet ? "first · Author" : "second")
            }
            let gate = TestWait.Gate(owner: self)
            defer { gate.open() }
            let entered = expectation(description: "rendered action's show held")
            fixture.git.showOperation = { _ in
                XCTAssertFalse(Thread.isMainThread)
                entered.fulfill()
                if !Thread.isMainThread { try? gate.wait() }
                return "Historical body"
            }
            let pressed = await clickRenderedAction(in: host.window, sheet: sheet) {
                gate.waiterCount == 1
            }
            XCTAssertTrue(pressed, "The rendered History action must start its read")
            guard pressed else { return }
            await fulfillment(of: [entered], timeout: TestWait.hostedActionTimeoutSeconds)
            await TestWait.until(failureMessage: "held action's button did not render a spinner") {
                RenderedViewTestSupport.hasButtonProgress(in: host.view)
            }
            gate.open()
            if sheet {
                await TestWait.until(failureMessage: "successful Restore did not close History") {
                    Self.texts(in: host.view).contains("Closed")
                }
                XCTAssertEqual(fixture.store.bodies["example"], "Historical body")
                XCTAssertEqual(fixture.counter.value, 1)
            } else {
                try await dismissDiff(in: host.window, presentation: state.presentation)
            }
        }
    }

}

extension SkillHistoryAsyncTests {
    private func dismissDiff(in window: NSWindow, presentation: SkillHistoryTabPresentation) async throws {
        await TestWait.until(failureMessage: "Diff did not open after its read") {
            window.attachedSheet != nil
        }
        try XCTUnwrap(window.attachedSheet).animationBehavior = .none
        presentation.diff = nil
        await TestWait.until(failureMessage: "Diff did not detach during host cleanup") {
            window.attachedSheet == nil
        }
    }

    private func assertMissingSkillRefusesRestoreBeforeReading() async throws {
        let fixture = try fixture()
        let model = SkillHistoryTabPresentation()
        fixture.git.commits = [Self.commit("version")]
        await model.load(skill: fixture.skill, git: fixture.git, workingDir: "/repo")
        let version = try XCTUnwrap(model.snapshot.versions.first)
        let root = TestTemporaryDirectory.path + "MissingHistorySkill-\(UUID().uuidString)"
        let store = SkillStore(fileService: FileService(), baseDir: root + "/skills", storeRoot: root)
        let reads = Counter()
        fixture.git.showOperation = { _ in
            reads.increment()
            return "Restored"
        }
        let restored = await model.restore(version, skill: fixture.skill, git: fixture.git, workingDir: "/repo",
            store: store, library: fixture.library, notifier: fixture.counter.notify).value
        XCTAssertFalse(restored)
        XCTAssertEqual(model.errorMessage, SkillHistoryTabPresentation.unreadableRestoreMessage)
        XCTAssertEqual(reads.value, 0)
        XCTAssertEqual(fixture.counter.value, 0)
    }

    private func invalidateRestore(_ invalidation: String, fixture: LibraryFixtureWithGit,
                                   model: SkillHistoryTabPresentation) async throws {
        switch invalidation {
        case "delete": fixture.context.delete(fixture.skill); try fixture.context.save()
        case "file edit": fixture.store.bodies["example"] = "Edited"
        case "draft edit": fixture.library.noteEditorChanged(fixture.skill, body: "Draft")
        case "edit then undo":
            fixture.library.noteEditorChanged(fixture.skill, body: "Draft")
            fixture.library.noteEditorChanged(fixture.skill, body: "Current")
            fixture.library.discardDraft(fixture.skill)
        case "raw bytes": fixture.store.savedData["example"] = Data("\u{FEFF}Current".utf8)
        case "immediate edit": break
        case "selection":
            await model.load(skill: Skill(name: "Other", directoryName: "other"), git: fixture.git, workingDir: "/repo")
        default: model.close()
        }
    }

    func fixture() throws -> LibraryFixtureWithGit {
        let context = ModelContext(try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true)))
        let skill = Skill(name: "Example", directoryName: "example")
        context.insert(skill)
        try context.save()
        let store = MemorySkillStore()
        store.bodies["example"] = "Current"
        let counter = Counter()
        let library = SkillLibraryViewModel(skillStore: store, fileWatchService: RecordingWatcher(),
            manifestRoot: TestPaths.storeRoot, notifier: counter.notify)
        _ = library.editorBody(for: skill)
        return LibraryFixtureWithGit(context: context, skill: skill, store: store, library: library,
            git: SkillHistoryRecordingGit(), counter: counter)
    }

    private func tab(_ fixture: LibraryFixtureWithGit, skill: Skill) -> SkillHistoryTab {
        SkillHistoryTab(skill: skill, currentBody: "Current", library: fixture.library,
            upstreamHistory: historyOwner(read: { _, _, _ in historyResult() }), localRevision: .initial,
            onOpenUpdates: {}, onUpdateCheck: { _ in }, git: fixture.git, store: fixture.store, workingDir: "/repo")
    }

    private func makeHost(_ root: AnyView) -> (view: NSHostingView<AnyView>, window: NSWindow) {
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = host
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return (host, window)
    }

    nonisolated static func commit(_ sha: String) -> GitCommit {
        GitCommit(sha: sha, author: "Author", date: Date(timeIntervalSince1970: 1), subject: sha)
    }

    private static func hasProgress(in host: NSHostingView<AnyView>) -> Bool {
        RenderedViewTestSupport.values(in: host).contains { String(reflecting: type(of: $0)).hasPrefix("SwiftUI.ProgressView<") }
    }

    /// The host exposes rendered SwiftUI text but no AX button nodes here. Follow the existing
    /// History host's native-click fallback, within the action column and live content bounds.
    /// A click counts only once the native read is held; rendered progress and final outcomes identify
    /// Diff versus Restore. No fresh body or reflected action is evaluated.
    private func clickRenderedAction(in window: NSWindow, sheet: Bool,
                                     activated: () -> Bool) async -> Bool {
        let bounds = window.contentView?.bounds ?? .zero
        let xs = sheet ? stride(from: max(bounds.maxX - 180, 0), through: bounds.maxX - 16, by: 8)
            : stride(from: 44.0, through: 116.0, by: 8)
        for xPosition in xs {
            for yPosition in stride(from: 8.0, through: sheet ? 100 : bounds.maxY, by: 8) {
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    guard let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: xPosition, y: yPosition),
                        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                        clickCount: 1, pressure: 1) else { return false }
                    window.sendEvent(event)
                }
                try? await Task.sleep(for: .milliseconds(10))
                if activated() { return true }
            }
        }
        return false
    }

    private static func texts(in host: NSHostingView<AnyView>) -> [String] {
        RenderedViewTestSupport.values(in: host).compactMap { $0 as? Text }.flatMap(RenderedViewTestSupport.strings)
    }
}

struct LibraryFixtureWithGit {
    let context: ModelContext
    let skill: Skill
    let store: MemorySkillStore
    let library: SkillLibraryViewModel
    let git: SkillHistoryRecordingGit
    let counter: Counter
}

@MainActor
@Observable
private final class HistoryAsyncHostState {
    var skill: Skill
    var showsHistory = true
    let presentation = SkillHistoryTabPresentation()
    init(skill: Skill) { self.skill = skill }
}

private struct HistoryAsyncHarness: View {
    @Bindable var state: HistoryAsyncHostState
    let fixture: LibraryFixtureWithGit
    let sheet: Bool

    var body: some View {
        Group {
            if !state.showsHistory {
                Text("Closed")
            } else if sheet {
                SkillHistoryView(skill: state.skill, git: fixture.git, store: fixture.store,
                    workingDir: "/repo", library: fixture.library, onDismiss: { state.showsHistory = false })
            } else {
                SkillHistoryTab(skill: state.skill, currentBody: "Current", library: fixture.library,
                    upstreamHistory: historyOwner(read: { _, _, _ in historyResult() }), localRevision: .initial,
                    onOpenUpdates: {}, onUpdateCheck: { _ in }, git: fixture.git, store: fixture.store,
                    workingDir: "/repo", hostedPresentation: state.presentation)
            }
        }
    }
}
