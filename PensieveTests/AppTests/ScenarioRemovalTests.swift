import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Pensieve

final class ScenarioRemovalTests: XCTestCase {
    @MainActor
    func testRetiredFeatureHasNoAppSourceOrNavigationEntry() async throws {
        try assertRetiredSourcesAndRoutes()
        for deferred in [false, true] { try await assertLaunchedWindowSelectsSkills(deferred: deferred) }
    }

    private func assertRetiredSourcesAndRoutes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let retired = try NSRegularExpression(
            pattern: #"\b(?:ScenarioStore(?:Protocol)?|ScenarioReconciler(?:Protocol)?|"#
                + #"ScenarioDetailView|ScenarioDetailModel|ScenarioListView|ScenarioRecord)\b"#
        )
        var scanned = 0
        for folder in ["Pensieve", "PensieveDaemon"] {
            let files = try XCTUnwrap(FileManager.default.enumerator(
                at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil
            ))
            var folderCount = 0
            for case let path as URL in files where path.pathExtension == "swift" {
                let source = try String(contentsOf: path, encoding: .utf8)
                XCTAssertNil(retired.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)), path.path)
                folderCount += 1
            }
            XCTAssertGreaterThan(folderCount, 0, folder)
            scanned += folderCount
        }
        XCTAssertGreaterThan(scanned, 100)
        XCTAssertEqual(SidebarSection.allCases, [.skills, .projects, .categories, .tags, .machines])
        XCTAssertNil(SidebarSection(rawValue: "scenarios"))
        XCTAssertNil(AddSheet(rawValue: "scenario"))
        XCTAssertNotNil(AddSheet(rawValue: "project"))
        XCTAssertNotNil(AddSheet(rawValue: "category"))
    }

    @MainActor
    private func assertLaunchedWindowSelectsSkills(deferred: Bool) async throws {
        let paths = try AppRuntimePaths.temporary(named: "ScenarioRemovalLaunch")
        let temporaryRoot = (paths.storeRoot as NSString).deletingLastPathComponent
        defer { try? FileService().deleteDirectory(at: temporaryRoot) }
        let defaults = try isolatedDefaults()
        defaults.set(false, forKey: AppRuntime.backgroundSyncEnabledKey)
        defaults.set(true, forKey: AppRuntime.migrationDefaultsKey)
        defaults.set(true, forKey: ScenarioHandover.doneKey)
        let launchLock: SyncLock? = deferred ? try XCTUnwrap(SyncLock.tryAcquire(at: paths.syncLockPath)) : nil
        defer { launchLock?.release() }
        let runtime = try AppRuntime(defaults: defaults, launchIngestRetryNanoseconds: 10_000_000,
                                     paths: paths, gitUsabilityProbe: { .usable })
        let skill = Skill(name: "Launch skill", skillDescription: "Description", directoryName: "launch")
        runtime.container.mainContext.insert(skill)
        try runtime.container.mainContext.save()
        try FileService().writeFile(at: paths.skillsDir + "/launch/SKILL.md",
                                    content: "---\nname: Launch skill\ndescription: Description\n---\nBody")
        var launchRendered = false
        let host = makeHost(runtime: runtime, paths: paths) { launchRendered = true }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 700),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        await runtime.bootstrapTask.value
        await TestWait.until(failureMessage: "main window did not run its launch callbacks") {
            host.layoutSubtreeIfNeeded()
            return runtime.launchWorkInvocationCount == 1 && self.sidebar(in: host) != nil
        }
        await runtime.mainWindowAppeared()
        XCTAssertEqual(runtime.storeQuarantined, deferred)
        XCTAssertEqual(runtime.launchWorkCompleted, !deferred)
        launchLock?.release()
        await TestWait.until(failureMessage: "launch work did not finish and render",
                             diagnostics: { "completed=\(runtime.launchWorkCompleted), rendered=\(launchRendered)" }, {

            host.layoutSubtreeIfNeeded()
            return runtime.launchWorkCompleted && launchRendered
        })
        host.layoutSubtreeIfNeeded()
        let outline = try XCTUnwrap(sidebar(in: host))
        let selected = try XCTUnwrap(outline.item(atRow: outline.selectedRow) as? SidebarOutlineItem)
        XCTAssertEqual(selected.section, .skills)
    }

    @MainActor
    private func makeHost(runtime: AppRuntime, paths: AppRuntimePaths,
                          onLaunchRendered: @escaping () -> Void) -> NSHostingView<AnyView> {
        let content = ContentView(
            installService: runtime.updatesViewModelOperations.skillInstallService,
            notifier: runtime.syncStateNotifier,
            echoRegistrar: runtime.syncWriteEchoRegistrar, bodyWriteRegistration: runtime.syncBodyWriteRegistration,
            updatesModel: runtime.updates,
            machineDependencies: MachineObservabilityDependencies(
                stateService: MachineStateService(), identity: MachineIdentity(appSupportDir: paths.appSupportDir),
                root: paths.storeRoot, now: Date.init))
        let rendered = LaunchRenderFence(content: content, onRendered: onLaunchRendered)
            .environment(runtime).modelContainer(runtime.container)
        return NSHostingView(rootView: AnyView(rendered))
    }

    @MainActor
    private func sidebar(in view: NSView) -> NSOutlineView? {
        if let outline = view as? NSOutlineView, outline.accessibilityLabel() == "Sidebar" { return outline }
        return view.subviews.lazy.compactMap { self.sidebar(in: $0) }.first
    }
}

/// Observes completed launch work inside a SwiftUI body before inspecting sidebar selection.
private struct LaunchRenderFence: View {
    let content: ContentView
    let onRendered: () -> Void
    @Environment(AppRuntime.self) private var runtime

    var body: some View {
        content.overlay {
            if runtime.launchWorkCompleted {
                Color.clear.onAppear(perform: onRendered)
            }
        }
    }
}
