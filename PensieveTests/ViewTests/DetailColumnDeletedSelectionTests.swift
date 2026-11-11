import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Pensieve

@MainActor
final class DetailColumnDeletedSelectionTests: XCTestCase {
    func testListDeleteClearsTheDisplayedSelectionBeforeRedrawing() async throws {
        try await assertDeletion(from: .list)
    }

    func testDetailDeleteClearsTheDisplayedSelectionBeforeRedrawing() async throws {
        try await assertDeletion(from: .detail)
    }

    private func assertDeletion(from route: DeletedSelectionFixture.Route) async throws {
        // Native performClick pumps a run loop, allowing the list's pruning backstop to
        // hide a missing synchronous clear. Also invoke its exact function without a flush.
        // The detail route has no mounted list, so only its deletion callback can clear selection.
        for throughButton in route == .list ? [true, false] : [true] {
            let fixture = try await fixture(showList: route == .list)
            try await fixture.assertDisplayed()
            if throughButton {
                try await fixture.confirmDelete(from: route)
            } else {
                try fixture.listDeletionAction()()
            }
            XCTAssertTrue(fixture.selection.skills.isEmpty,
                "\(route), button=\(throughButton): Delete must clear selection before the next graph flush")
            try await fixture.assertPrompt()
        }
    }

    func testStaleSelectionDrawsThePromptWithoutReadingTheDeletedSkill() async throws {
        let fixture = try await fixture(showList: false)
        try await fixture.assertDisplayed()
        fixture.context.delete(fixture.skill)
        try fixture.context.save()
        XCTAssertNil(fixture.skill.modelContext)
        XCTAssertEqual(fixture.selection.skills.count, 1, "Exercise the guard independently of selection cleanup")
        try await fixture.assertPrompt()
    }

    func testListDeletePreservesTheOtherSelectedSkill() async throws {
        let fixture = try await fixture()
        try await fixture.assertDisplayed()
        fixture.selection.skills.insert(fixture.other)
        try await fixture.confirmDelete(from: .list)
        XCTAssertEqual(fixture.selection.skills, [fixture.other], "Delete removes only its own skill")
        await TestWait.until(failureMessage: "The surviving selection must draw its own detail") {
            fixture.strings.contains("Remaining Skill")
        }
    }

    func testRefusedDeletesKeepSelectionAndRecoverTheDisplayedSkill() async throws {
        // Pair refusal with a successful retry so an action that always refuses cannot pass.
        for route in DeletedSelectionFixture.Route.allCases {
            let fixture = try await fixture(showList: route == .list)
            try await fixture.assertDisplayed()
            let delete = try await fixture.confirmationAction(from: route)
            fixture.runtime.library.refreshQuarantine(context: fixture.context, fetch: { _ in
                throw CocoaError(.fileReadUnknown)
            })
            delete()
            XCTAssertTrue(fixture.runtime.library.libraryUnavailable)
            XCTAssertEqual(fixture.runtime.library.deletionNotice?.title, "Couldn't delete skill")
            XCTAssertEqual(fixture.selection.skills, [fixture.skill])
            XCTAssertNotNil(fixture.skill.modelContext)
            fixture.runtime.library.refreshQuarantine(context: fixture.context)
            try await fixture.assertDisplayed()
            try await fixture.confirmDelete(from: route)
            XCTAssertTrue(fixture.selection.skills.isEmpty)
            try await fixture.assertPrompt()
        }
    }

    private func fixture(showList: Bool = true) async throws -> DeletedSelectionFixture {
        let fixture = try DeletedSelectionFixture(defaults: isolatedDefaults())
        addTeardownBlock { @MainActor in await fixture.close() }
        await fixture.runtime.bootstrapTask.value
        try fixture.seedAndMount(showList: showList)
        return fixture
    }
}

@MainActor @Observable
private final class DeletedSelection {
    var skills: Set<Skill> = []
    var binding: Binding<Set<Skill>> { Binding(get: { self.skills }, set: { self.skills = $0 }) }
}

@MainActor
private final class DeletedSelectionFixture {
    enum Route: CaseIterable { case list, detail }
    let base: LibraryFenceFixture
    let selection = DeletedSelection()
    let listHost = NSHostingView(rootView: AnyView(EmptyView()))
    let skill = Skill(name: "Displayed Skill", directoryName: "displayed-skill")
    let other = Skill(name: "Remaining Skill", directoryName: "remaining-skill")
    var runtime: AppRuntime { base.runtime }
    var context: ModelContext { runtime.container.mainContext }
    var strings: [String] { base.strings }

    init(defaults: UserDefaults) throws {
        base = try LibraryFenceFixture(defaults: defaults)
    }

    func seedAndMount(showList: Bool) throws {
        for skill in [skill, other] {
            _ = try runtime.library.skillStore.createSkill(name: skill.name, description: "A test skill", body: "Body")
            context.insert(skill)
        }
        try context.save()
        selection.skills = [skill]
        base.window.contentView = NSStackView(views: [listHost, base.host])
        if showList {
            listHost.rootView = AnyView(NavigationStack {
                SkillListView(searchText: .constant(""), platformVM: runtime.platformVM, syncModel: runtime.syncModel,
                    selectedSkills: selection.binding, library: runtime.library, filter: .constant(SkillListFilter()),
                    updateNoticeCount: 0, onOpenUpdates: {})
            }.environment(runtime).modelContainer(runtime.container))
        }
        base.host.rootView = AnyView(NavigationStack {
            DeletedSelectionPane(selection: selection, runtime: runtime)
        }.environment(runtime).modelContainer(runtime.container))
    }

    func assertDisplayed() async throws {
        await TestWait.until(failureMessage: "Show the selected skill before deleting it",
            diagnostics: { self.base.diagnostics }, {
            self.strings.contains("Displayed Skill")
        })
        _ = try XCTUnwrap(strings.first { $0 == "Displayed Skill" }, base.diagnostics)
        XCTAssertFalse(strings.contains("No Skill Selected"), base.diagnostics)
    }

    func assertPrompt() async throws {
        await TestWait.until(failureMessage: "The same mounted pane must show the no-selection prompt",
            diagnostics: { self.base.diagnostics }, {
            self.strings.contains("No Skill Selected") && !self.strings.contains("Displayed Skill")
        })
        _ = try XCTUnwrap(strings.first { $0 == "No Skill Selected" }, base.diagnostics)
        XCTAssertFalse(strings.contains("Displayed Skill"), base.diagnostics)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Skill>()).count, 1, "Keep the nonempty-library prompt distinct")
    }

    func confirmDelete(from route: Route) async throws {
        let action = try await confirmationAction(from: route)
        action()
    }

    func confirmationAction(from route: Route) async throws -> () -> Void {
        let host = route == .list ? listHost : base.host
        let request = route == .list ? base.renderedAction("Delete", in: host)
            : renderedView(SkillMoreMenu.self, in: host)?.onDelete
        if let request {
            request()
            await TestWait.until(failureMessage: "The Delete confirmation must attach") {
                self.base.window.attachedSheet != nil
            }
            if let root = base.window.attachedSheet?.contentView,
               let confirm = sheetAction("Delete", in: root) {
                return confirm
            }
            if let root = base.window.attachedSheet?.contentView {
                sheetAction("Cancel", in: root)?()
                await TestWait.until(failureMessage: "Dismiss the confirmation before invoking its action") {
                    self.base.window.attachedSheet == nil
                }
            }
        }
        // The list's exact confirmation function also allows a synchronous assertion
        // before native performClick gives the pruning backstop a graph flush.
        XCTAssertEqual(route, .list, "The mounted detail toolbar must expose its production Delete action")
        return try listDeletionAction()
    }

    func listDeletionAction() throws -> () -> Void {
        let view = try XCTUnwrap(renderedView(SkillListView.self, in: listHost))
        return { view.deleteConfirmed(self.skill, projects: [], context: self.context) }
    }

    private func renderedView<T>(_ type: T.Type, in host: NSView) -> T? {
        // Inspect existing SwiftUI composition without evaluating another body.
        func find(_ value: Any, depth: Int = 24) -> T? {
            if let view = value as? T { return view }
            guard depth > 0 else { return nil }
            let mirror = Mirror(reflecting: value)
            guard mirror.displayStyle != .class,
                  String(reflecting: Swift.type(of: value)).hasPrefix("SwiftUI.")
                    || [.tuple, .enum, .optional].contains(mirror.displayStyle) else { return nil }
            return mirror.children.lazy.compactMap { find($0.value, depth: depth - 1) }.first
        }
        return RenderedViewTestSupport.values(in: host).lazy.compactMap { find($0) }.first
    }

    private func sheetAction(_ title: String, in root: NSView) -> (() -> Void)? {
        if let action = base.renderedAction(title, in: root) { return action }
        func buttons(in view: NSView) -> [NSButton] {
            [view].compactMap { $0 as? NSButton } + view.subviews.flatMap(buttons)
        }
        if let button = buttons(in: root).first(where: { $0.title == title }) {
            return { button.performClick(nil) }
        }
        print("Delete confirmation exposes no \(title) action; native buttons: \(buttons(in: root).map(\.title))")
        return nil
    }

    func close() async {
        if let sheet = base.window.attachedSheet, let root = sheet.contentView {
            if let cancel = sheetAction("Cancel", in: root) {
                cancel()
            } else {
                base.window.endSheet(sheet, returnCode: .cancel)
            }
            await TestWait.until(failureMessage: "Dismiss Delete before unmounting its presenter") {
                self.base.window.attachedSheet == nil
            }
        }
        await runtime.library.manifestSaves?.waitUntilIdle()
        listHost.rootView = AnyView(EmptyView())
        await TestWait.until(failureMessage: "Unmount the list before releasing its container") {
            RenderedViewTestSupport.values(in: self.listHost).allSatisfy { !($0 is SkillListView) }
        }
        listHost.removeFromSuperview()
        base.window.contentView = base.host
        await base.close()
    }
}

private struct DeletedSelectionPane: View {
    let selection: DeletedSelection
    let runtime: AppRuntime
    @Query(sort: \Skill.name) private var skills: [Skill]

    var body: some View {
        let dependencies = DeployIntentDependencies(identity: InertMachineIdentity(), stateService: InertMachineStateService(),
            root: runtime.paths.storeRoot, writeManifest: { _ in }, notifier: {},
            lockPath: runtime.paths.syncLockPath, lockProvider: { _ in nil })
        DetailColumnView(section: .skills, entitySelection: nil, selectedSkills: selection.skills,
            skills: skills, skillsEmpty: skills.isEmpty, projects: [], platformVM: runtime.platformVM,
            syncModel: runtime.syncModel, library: runtime.library, provenance: runtime.provenanceVM,
            upstreamHistory: runtime.upstreamHistory, machineStates: [], remoteProjects: [], localMachineID: nil,
            notifier: {}, intentService: DeployMutationService(platformVM: runtime.platformVM, dependencies: dependencies),
            now: Date.init, onResolve: {}, onConnectToRepository: { _ in }, onBulkDeploy: {}, onOpenUpdates: {},
            updateRouting: UpdateReviewRouting(preview: runtime.viewChanges, updates: runtime.updates,
                library: runtime.library, context: runtime.container.mainContext, openWindow: { _ in }),
            onImport: {}, onImportFolder: {}, onCreate: {}, onAddFromGitHub: {}, onAdd: { _ in }, onReveal: { _ in },
            onDeleted: { selection.skills.remove($0) })
    }
}
