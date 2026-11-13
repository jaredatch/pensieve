import AppKit
import SwiftUI
import XCTest
@testable import Pensieve

@MainActor
final class DetectedAgentMentionTests: XCTestCase {
    func testDeleteAlertNamesCursorOnlyWhenCursorIsDetected() async throws {
        for route in DeletedSelectionFixture.Route.allCases {
            for detected: [PlatformTarget] in [[], [.cursor]] {
                for unsaved in [false, true] {
                    let fixture = try DeletedSelectionFixture(defaults: isolatedDefaults(), detectedAgents: detected)
                    addTeardownBlock { @MainActor in await fixture.close() }
                    await fixture.runtime.bootstrapTask.value
                    try fixture.seedAndMount(showList: route == .list)
                    try await fixture.assertDisplayed()
                    if unsaved {
                        _ = fixture.runtime.library.editorBody(for: fixture.skill)
                        fixture.runtime.library.noteEditorChanged(fixture.skill, body: "An unsaved draft")
                    }
                    await TestWait.until(failureMessage: "The production Delete action must render") {
                        fixture.deletionRequest(from: route) != nil
                    }
                    try XCTUnwrap(fixture.deletionRequest(from: route))()
                    await TestWait.until(failureMessage: "The delete question must attach before reading its message") {
                        fixture.base.window.attachedSheet?.contentView.map(Self.text)?
                            .contains("Delete “Displayed Skill”?") == true
                    }
                    let sheet = try XCTUnwrap(fixture.base.window.attachedSheet)
                    sheet.animationBehavior = .none
                    let text = try XCTUnwrap(sheet.contentView.map(Self.text))
                    let message = try XCTUnwrap(Self.labels(in: XCTUnwrap(sheet.contentView))
                        .first { $0.contains("This removes the skill") })
                    XCTAssertEqual(text.contains("Cursor"), detected.contains(.cursor), "\(route): \(text)")
                    XCTAssertFalse(message.contains("left in place"), message)
                    if detected.contains(.cursor) {
                        let base = "This removes the skill from your library, unlinks it from the agents Pensieve linked it to "
                            + "on this Mac (the agents found at launch, in your registered projects), "
                            + "removes the Cursor rules Pensieve deployed from this Mac, and retracts it from every machine."
                        XCTAssertEqual(message, base + (unsaved ? " Unsaved changes to SKILL.md will be lost." : ""))
                    }
                    XCTAssertEqual(message.hasSuffix("Unsaved changes to SKILL.md will be lost."), unsaved, message)
                    try Self.press("Cancel", in: XCTUnwrap(sheet.contentView))
                    await TestWait.until(failureMessage: "Cancel must detach the question") {
                        fixture.base.window.attachedSheet == nil
                    }
                    await fixture.close()
                }
            }
        }
    }

    func testImportWindowNamesOnlyDetectedAgents() async throws {
        let cases: [([PlatformTarget], String)] = [
            ([.claudeCode], "Let's find your existing AI skills across Claude Code."),
            ([.cursor, .claudeCode], "Let's find your existing AI skills across Claude Code and Cursor."),
            ([.openClaw, .hermes], "Let's find your existing AI skills."),
            ([], "Let's find your existing AI skills.")
        ]
        for (detected, expected) in cases {
            let fixture = try await fixture(detected)
            let scanner = MentionScanHold()
            let paths = fixture.runtime.paths
            let model = ImportViewModel(scanner: scanner, skillStore: fixture.runtime.library.skillStore,
                lockPath: paths.syncLockPath, manifestRoot: paths.storeRoot)
            let runtime = fixture.runtime
            fixture.host.rootView = AnyView(ContentView(
                installService: runtime.updatesViewModelOperations.skillInstallService,
                updatesModel: runtime.updates, machineDependencies: runtime.machineObservability, importModel: model
            ).environment(runtime).modelContainer(runtime.container))
            await TestWait.until(failureMessage: "An empty library must open the production welcome window") {
                fixture.window.attachedSheet?.contentView.map(Self.renderedStrings)?.contains("Welcome to Pensieve") == true
            }
            let sheet = try XCTUnwrap(fixture.window.attachedSheet)
            sheet.animationBehavior = .none
            let root = try XCTUnwrap(sheet.contentView)
            let welcome = Self.renderedStrings(in: root).filter { $0.hasPrefix("Let's find") }
            XCTAssertEqual(welcome, [expected])
            var scanningText: [String] = []
            scanner.whileScanning = {
                scanningText = Self.renderedStrings(in: root)
                return scanningText.contains("Scanning for existing skills...")
            }
            try Self.pressReturn(in: sheet)
            await TestWait.until(failureMessage: "The held scanner must finish after capturing the mounted scanning step") {
                scanner.finished
            }
            XCTAssertTrue(scanningText.contains("Scanning for existing skills..."), scanningText.description)
            XCTAssertTrue(scanningText.contains("Checking for skills on this Mac."), scanningText.description)
            for forbidden in ["Claude", "Grok", "Cursor", "Codex", "OpenClaw", "Hermes", "~/", "/skills", "/rules"] {
                XCTAssertFalse(scanningText.joined().contains(forbidden), scanningText.description)
            }
            await TestWait.until(failureMessage: "The scan must reach its done screen") {
                Self.renderedStrings(in: root).contains("Done")
            }
            try Self.pressReturn(in: sheet)
            await TestWait.until(failureMessage: "Done must dismiss the import window") { fixture.window.attachedSheet == nil }
            await fixture.close()
        }
    }

    func testCategoryHeaderNamesOnlyDetectedProjectAgents() async throws {
        let cases: [([PlatformTarget], [String])] = [
            ([.claudeCode, .codex], ["Claude Code", "Codex"]),
            ([.cursor], ["Cursor"]),
            ([.openClaw, .hermes], [])
        ]
        for (detected, expected) in cases {
            let fixture = try await fixture(detected)
            let category = Pensieve.Category(name: "Writing")
            fixture.runtime.container.mainContext.insert(category)
            try fixture.runtime.container.mainContext.save()
            fixture.mountCategoryNames("detail", category: category)
            await TestWait.until(failureMessage: "The production category header must render",
                                 diagnostics: { fixture.diagnostics }, {
                fixture.strings.contains { $0.contains("project-capable") }
            })
            let header = try XCTUnwrap(RenderedViewTestSupport.values(in: fixture.host).compactMap { $0 as? Text }
                .first { RenderedViewTestSupport.strings(in: $0).contains { $0.contains("project-capable") } })
            // A localized Text keeps its interpolated agent list in its rendered storage, separate
            // from the format string. Read that storage, as the hosted selection-count tests do.
            let rendered = String(reflecting: header)
            for name in ["Claude Code", "Grok", "Cursor", "Codex", "OpenClaw", "Hermes"] {
                XCTAssertEqual(rendered.contains(name), expected.contains(name), rendered)
            }
            if expected.isEmpty {
                XCTAssertTrue(RenderedViewTestSupport.strings(in: header)
                    .contains("No project-capable agents were found on this Mac."), rendered)
                XCTAssertFalse(rendered.contains("()"), rendered)
            }
            await fixture.close()
        }
    }

    func testPlatformPathsListOnlyDetectedAgents() async throws {
        for detected: [PlatformTarget] in [[.claudeCode], [.cursor], [.grok], [.codex, .openClaw, .hermes], []] {
            let fixture = try await fixture(detected)
            fixture.host.rootView = AnyView(PlatformSettingsView(defaults: try isolatedDefaults())
                .environment(fixture.runtime))
            await TestWait.until(failureMessage: "Settings must render its shared budget before reading paths") {
                fixture.strings.contains("Skill Size")
            }
            let strings = fixture.strings
            let expectedRows = detected.filter { [.claudeCode, .grok, .cursor].contains($0) }
            XCTAssertEqual(strings.contains("Platform Paths"), !expectedRows.isEmpty, strings.description)
            for (agent, label) in [(PlatformTarget.claudeCode, "Claude Code Skills"), (.grok, "Grok Skills"),
                                   (.cursor, "Cursor Rules")] {
                XCTAssertEqual(strings.contains(label), expectedRows.contains(agent), strings.description)
            }
            if detected == [.cursor] {
                XCTAssertTrue(strings.contains(fixture.runtime.paths.deployPaths.cursorUserRulesDirectory), strings.description)
            }
            await fixture.close()
        }
    }

    private func fixture(_ detected: [PlatformTarget]) async throws -> LibraryFenceFixture {
        let fixture = try LibraryFenceFixture(defaults: isolatedDefaults(), detectedAgents: detected)
        addTeardownBlock { @MainActor in
            fixture.runtime.library.stopWatching()
            fixture.runtime.commandServer?.stop()
            await fixture.close()
        }
        await fixture.runtime.bootstrapTask.value
        _ = await fixture.runtime.performLaunchWorkIfNeeded(context: fixture.runtime.container.mainContext)
        return fixture
    }

    private static func renderedStrings(in root: NSView) -> [String] {
        RenderedViewTestSupport.values(in: root).compactMap { $0 as? Text }.flatMap(RenderedViewTestSupport.strings)
    }

    private static func labels(in root: NSView) -> [String] {
        [root].compactMap { ($0 as? NSTextField)?.stringValue } + root.subviews.flatMap(labels)
    }

    private static func text(in root: NSView) -> String { labels(in: root).joined(separator: "\n") }

    private static func pressReturn(in window: NSWindow) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36))
        XCTAssertTrue(window.performKeyEquivalent(with: event))
    }

    private static func press(_ title: String, in root: NSView) throws {
        func buttons(_ view: NSView) -> [NSButton] {
            [view].compactMap { $0 as? NSButton } + view.subviews.flatMap(buttons)
        }
        try XCTUnwrap(buttons(root).first { $0.title == title }).performClick(nil)
    }
}

/// Holds only the injected synchronous import scan, pumping the main run loop until the test has
/// read the mounted scanning screen or the shared UI deadline expires. No host filesystem is read.
private final class MentionScanHold: ImportScannerProtocol {
    var whileScanning: () -> Bool = { false }
    var finished = false
    func scan() -> [DiscoveredSkill] {
        let deadline = Date().addingTimeInterval(TestWait.hostedActionTimeoutSeconds)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            if whileScanning() { break }
        } while Date() < deadline
        finished = true
        return []
    }
    func scanFolder(_ path: String) -> [DiscoveredSkill] { [] }
    func isInsideStore(_ path: String) -> Bool { false }
}
