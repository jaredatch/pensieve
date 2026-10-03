import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Pensieve

final class ScenarioRemovalTests: XCTestCase {
    @MainActor
    func testRetiredFeatureHasNoAppSourceOrNavigationEntry() async throws {
        try assertRetiredSourcesAndRoutes()
        try await assertLaunchedWindowSelectsSkills()
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
    private func assertLaunchedWindowSelectsSkills() async throws {
        let paths = try AppRuntimePaths.temporary(named: "ScenarioRemovalLaunch")
        let temporaryRoot = (paths.storeRoot as NSString).deletingLastPathComponent
        defer { try? FileService().deleteDirectory(at: temporaryRoot) }
        let defaults = try isolatedDefaults()
        defaults.set(false, forKey: AppRuntime.backgroundSyncEnabledKey)
        defaults.set(true, forKey: AppRuntime.migrationDefaultsKey)
        defaults.set(true, forKey: ScenarioHandover.doneKey)
        let runtime = try AppRuntime(defaults: defaults, paths: paths, gitUsabilityProbe: { .usable })
        let skill = Skill(name: "Launch skill", skillDescription: "Description", directoryName: "launch")
        runtime.container.mainContext.insert(skill)
        try runtime.container.mainContext.save()
        try FileService().writeFile(at: paths.skillsDir + "/launch/SKILL.md",
                                    content: "---\nname: Launch skill\ndescription: Description\n---\nBody")
        let content = ContentView(
            installService: runtime.updatesViewModelOperations.skillInstallService,
            updatesOperations: runtime.updatesViewModelOperations, notifier: runtime.syncStateNotifier,
            echoRegistrar: runtime.syncWriteEchoRegistrar, bodyWriteRegistration: runtime.syncBodyWriteRegistration,
            machineDependencies: MachineObservabilityDependencies(
                stateService: MachineStateService(), identity: MachineIdentity(appSupportDir: paths.appSupportDir),
                root: paths.storeRoot, now: Date.init))
        let host = NSHostingView(rootView: content
            .environment(runtime).modelContainer(runtime.container))
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
        // Drain the view update after launch and configuration callbacks before inspecting its real selection.
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let outline = try XCTUnwrap(sidebar(in: host))
        let selected = try XCTUnwrap(outline.item(atRow: outline.selectedRow) as? SidebarOutlineItem)
        XCTAssertEqual(selected.section, .skills)
    }

    @MainActor
    private func sidebar(in view: NSView) -> NSOutlineView? {
        if let outline = view as? NSOutlineView, outline.accessibilityLabel() == "Sidebar" { return outline }
        return view.subviews.lazy.compactMap { self.sidebar(in: $0) }.first
    }
}
