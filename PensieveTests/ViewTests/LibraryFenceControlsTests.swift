import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Pensieve

@MainActor
final class LibraryFenceControlsTests: XCTestCase {
    func testAddControlsExplainLaunchUnreadableAndUnavailableAndRecover() async throws {
        let fixture = try LibraryFenceFixture(defaults: isolatedDefaults())
        addTeardownBlock { @MainActor in await fixture.close() }
        await fixture.runtime.bootstrapTask.value
        for section in [SidebarSection.skills, .projects, .categories] {
            for content in [false, true] {
                fixture.mount(section: section, content: content)
                for state in FenceState.allCases {
                    fixture.apply(state)
                    let expected = section == .skills ? (content ? [] : state.unreadable ? ["Add Skill"]
                        : ["Add Skill", "Find Skills on This Mac", "Import from Folder…", "Create Skill"])
                        : [section == .projects ? "Add Project" : "Add Category"]
                    if expected.isEmpty { continue }
                    await TestWait.until(failureMessage: "\(section) \(content) \(state) must explain its add controls",
                        diagnostics: { fixture.diagnostics }, {
                        expected.allSatisfy { title in
                            fixture.controls.contains { $0.title == title && $0.enabled == (state == .readable)
                                && (state.reason == nil || $0.help == state.reason) }
                        }
                    })
                    if content, section != .skills {
                        let usual = section == .projects ? "Add a project to organize and deploy skills by workspace."
                            : "Add a category to assign skills across projects."
                        XCTAssertTrue(fixture.strings.contains(state == .launch || state == .readable ? usual : state.reason!),
                            fixture.diagnostics)
                    }
                }
            }
        }
    }

    func testCategoryRenameMembershipAndContextMenuFollowTheReadableFence() async throws {
        let fixture = try LibraryFenceFixture(defaults: isolatedDefaults())
        addTeardownBlock { @MainActor in await fixture.close() }
        await fixture.runtime.bootstrapTask.value
        let context = fixture.runtime.container.mainContext
        let category = Pensieve.Category(name: "Writing")
        let project = Project(name: "Agent Recap", path: fixture.runtime.paths.homeDirectory + "/project")
        project.identityKey = "project-key"
        let assigned = Skill(name: "Assigned", directoryName: "assigned")
        let available = Skill(name: "Available", directoryName: "available")
        category.projectKeys = ["project-key"]
        category.skillSlugs = ["assigned"]
        context.insert(category)
        context.insert(project)
        context.insert(assigned)
        context.insert(available)
        try context.save()
        for content in [false, true] {
            fixture.mount(section: .categories, content: content, entity: .category(category.id))
            for state in FenceState.allCases {
                fixture.apply(state)
                let enabled = state == .launch || state == .readable
                let titles = content ? ["Rename", "Remove"] : ["Rename", "Agent Recap", "Assigned", "Available"]
                await TestWait.until(failureMessage: "\(state) category controls must follow the edit fence",
                    diagnostics: { fixture.diagnostics }, {
                    titles.allSatisfy { title in
                        fixture.controls.contains { $0.title == title
                            && $0.kind == (content || title == "Rename" ? .button : .toggle) && $0.enabled == enabled
                            && (content ? $0.help == nil : enabled || $0.help == state.reason) }
                    }
                })
                guard titles.allSatisfy({ title in fixture.controls.contains { $0.title == title } }) else { return }
                if !content {
                    XCTAssertEqual(fixture.strings.contains(state.reason ?? "__no_reason__"), !enabled,
                        fixture.diagnostics)
                }
            }
        }
        XCTAssertEqual(category.name, "Writing")
        XCTAssertEqual(category.projectKeys, ["project-key"])
        XCTAssertEqual(category.skillSlugs, ["assigned"])
    }

    func testDeploymentsFooterExplainsLaunchUnreadableUnavailableAndRecovery() async throws {
        let fixture = try LibraryFenceFixture(defaults: isolatedDefaults())
        addTeardownBlock { @MainActor in await fixture.close() }
        await fixture.runtime.bootstrapTask.value
        let skill = Skill(name: "Example", directoryName: "example")
        fixture.runtime.container.mainContext.insert(skill)
        try fixture.runtime.container.mainContext.save()
        fixture.mountDeployments(skill: skill)
        for state in FenceState.allCases {
            fixture.apply(state)
            await TestWait.until(failureMessage: "The Deployments footer must explain \(state)",
                diagnostics: { fixture.diagnostics }, {
                fixture.controls.contains { $0.title == "Add Project" && $0.enabled == (state == .readable)
                    && (state.reason == nil || $0.help == state.reason) }
            })
        }
    }

    func testNormalLaunchKeepsTheUsualSkillsDescriptions() async throws {
        let gate = TestWait.Gate(owner: self)
        defer { gate.open() }
        let entered = expectation(description: "launch ingestion held")
        let fixture = try LibraryFenceFixture(defaults: isolatedDefaults(), launchReconcile: { _, _ in
            entered.fulfill()
            try? gate.wait()
            return LaunchReconcileOutcome(rebuild: RebuildResult(), migrationRan: false)
        })
        addTeardownBlock { @MainActor in await fixture.close() }
        await fixture.runtime.bootstrapTask.value
        let launch = Task { await fixture.runtime.performLaunchWorkIfNeeded(context: fixture.runtime.container.mainContext) }
        await fulfillment(of: [entered], timeout: TestWait.timeoutSeconds)
        for pending in [true, false] {
            if !pending { gate.open(); await launch.value }
            for section in [SidebarSection.skills, .projects, .categories] {
                for content in [false, true] {
                    fixture.mount(section: section, content: content)
                    let usual: String
                    switch section {
                    case .skills: usual = content ? "Create a new skill or import existing ones."
                        : "Import existing skills or create your first one."
                    case .projects: usual = "Add a project to organize and deploy skills by workspace."
                    default: usual = "Add a category to assign skills across projects."
                    }
                    if content || section == .skills {
                        await TestWait.until(failureMessage: "Normal launch must retain the usual description") {
                            fixture.strings.contains(usual)
                        }
                    }
                    XCTAssertFalse(fixture.strings.contains(FenceState.launch.reason!), fixture.diagnostics)
                    XCTAssertEqual(fixture.runtime.library.addsFenced, pending)
                }
            }
        }
    }

}

private enum FenceState: CaseIterable {
    case launch, unreadable, unavailable, readable
    case unreadableDuringLaunch, unavailableAndUnreadableDuringLaunch

    var launching: Bool {
        self == .launch || self == .unreadableDuringLaunch || self == .unavailableAndUnreadableDuringLaunch
    }
    var unreadable: Bool {
        self == .unreadable || self == .unreadableDuringLaunch || self == .unavailableAndUnreadableDuringLaunch
    }
    var unavailable: Bool { self == .unavailable || self == .unavailableAndUnreadableDuringLaunch }

    var reason: String? {
        switch self {
        case .launch: return "Pensieve is still reading this library."
        case .unreadable, .unreadableDuringLaunch:
            return "Pensieve can't change this library until it can read it. Update Pensieve, then relaunch."
        case .unavailable, .unavailableAndUnreadableDuringLaunch:
            return "Pensieve couldn't open this library. Relaunch to try again."
        case .readable: return nil
        }
    }
}

@MainActor
private final class LibraryFenceFixture {
    let runtime: AppRuntime
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    let window: NSWindow

    init(defaults: UserDefaults, launchReconcile: @escaping AppRuntime.LaunchReconcile = { _, _ in
        LaunchReconcileOutcome(rebuild: RebuildResult(), migrationRan: false)
    }) throws {
        // Temporary runtime paths select inert deployment services; launch work is driven by the test.
        runtime = try AppRuntime(
            container: AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true)),
            defaults: defaults,
            launchReconcile: launchReconcile,
            launchBackfill: { _ in }, hasRemoteConfigured: { false },
            paths: AppRuntimePaths.temporary(named: "LibraryFenceControlsTests"), gitUsabilityProbe: { .usable })
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 850),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
    }

    func apply(_ state: FenceState) {
        runtime.library.setLaunchIngestPending(state.launching)
        runtime.library.setStoreUnreadable(state.unreadable)
        runtime.library.refreshQuarantine(context: runtime.container.mainContext, fetch: { _ in
            if state.unavailable { throw CocoaError(.fileReadUnknown) }
            return []
        })
    }

    func mount(section: SidebarSection, content: Bool = false, entity: EntitySelection? = nil) {
        let runtime = runtime
        let dependencies = DeployIntentDependencies(identity: InertMachineIdentity(), stateService: InertMachineStateService(),
            root: runtime.paths.storeRoot, writeManifest: { _ in }, notifier: {},
            lockPath: runtime.paths.syncLockPath, lockProvider: { _ in nil })
        host.rootView = AnyView(NavigationStack {
            if content {
                ContentColumnView(section: section, entitySelection: .constant(entity), selectedSkills: .constant([]),
                searchText: .constant(""), platformVM: runtime.platformVM, syncModel: runtime.syncModel,
                library: runtime.library, skillFilter: .constant(SkillListFilter()), machineStates: [],
                remoteProjects: [], localMachineID: nil, notifier: {}, now: Date.init, onAdd: { _ in },
                updateNoticeCount: 0, onOpenUpdates: {})
            } else {
                DetailColumnView(section: section, entitySelection: entity, selectedSkills: [], skills: [], skillsEmpty: true,
                projects: [], platformVM: runtime.platformVM, syncModel: runtime.syncModel, library: runtime.library,
                provenance: runtime.provenanceVM, upstreamHistory: runtime.upstreamHistory, machineStates: [],
                remoteProjects: [], localMachineID: nil, notifier: {}, intentDependencies: dependencies,
                now: Date.init, onResolve: {}, onConnectToRepository: { _ in }, onBulkDeploy: {}, onOpenUpdates: {},
                updateRouting: UpdateReviewRouting(preview: runtime.viewChanges, updates: runtime.updates,
                    library: runtime.library, context: runtime.container.mainContext, openWindow: { _ in }),
                onImport: {}, onImportFolder: {}, onCreate: {},
                onAddFromGitHub: {}, onAdd: { _ in }, onReveal: { _ in })
            }
        }.toggleStyle(FenceToggleProbeStyle()).environment(runtime).modelContainer(runtime.container))
        host.layoutSubtreeIfNeeded()
    }

    func mountDeployments(skill: Skill) {
        let dependencies = DeployIntentDependencies(identity: InertMachineIdentity(), stateService: InertMachineStateService(),
            root: runtime.paths.storeRoot, writeManifest: { _ in }, notifier: {},
            lockPath: runtime.paths.syncLockPath, lockProvider: { _ in nil })
        host.rootView = AnyView(SkillDeploymentsTab(skill: skill, snapshot: DetailContentSnapshot(), statusIsCurrent: true,
            projects: [], platformVM: runtime.platformVM, library: runtime.library, intentDependencies: dependencies,
            machineStates: [], localMachineID: nil, homeDirectory: runtime.paths.homeDirectory, onAddProject: {})
            .modelContainer(runtime.container))
        host.layoutSubtreeIfNeeded()
    }

    var controls: [RenderedControlInputs.Control] { RenderedControlInputs.controls(in: host) }
    var strings: [String] {
        RenderedViewTestSupport.values(in: host).compactMap { $0 as? Text }
            .flatMap(RenderedViewTestSupport.strings).map(RenderedControlInputs.unescape)
    }
    var diagnostics: String { "controls=\(controls) text=\(strings)" }

    func close() async {
        host.rootView = AnyView(EmptyView())
        await TestWait.until(failureMessage: "The hosted queries must unmount before their container is released") {
            RenderedViewTestSupport.values(in: self.host).allSatisfy { !String(reflecting: type(of: $0)).hasPrefix("Pensieve.") }
        }
        window.contentView = nil
        window.close()
        do {
            let next = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
            next.mainContext.insert(Pensieve.Category(name: "After closing the hosts"))
            try next.mainContext.save()
        } catch { XCTFail("A save after host teardown failed: \(error)") }
    }
}

private struct FenceToggleProbeStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        DefaultToggleStyle().makeBody(configuration: configuration)
            .background(HStack {
                configuration.label
                Text(enabled ? "__enabled_toggle__" : "__disabled_toggle__")
            }.hidden())
    }
}
