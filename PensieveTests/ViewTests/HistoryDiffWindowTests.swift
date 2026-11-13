import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Pensieve

/// Button wiring and the auxiliary window's rendered contract own these regressions.
@MainActor
final class HistoryDiffWindowTests: XCTestCase {
    func testViewDiffOnASkillYouWroteOpensTheChangesWindow() async throws {
        let host = try HistoryDiffHost(installed: false)
        defer { host.close() }
        try await host.pressHistory()
        await host.expectLines(old: "Historical body", new: "Current body")
        host.expectHeading(sides: "Author → Current")
        XCTAssertEqual(host.opened, [WindowPolicy.changesWindowID])
        XCTAssertNil(host.main.attachedSheet)
    }

    func testViewDiffOnAnInstalledVersionOpensTheChangesWindow() async throws {
        let host = try HistoryDiffHost(installed: true)
        defer { host.close() }
        try await host.pressHistory()
        await host.expectLines(old: "# Demo", new: "Current body")
        host.expectHeading(sides: "bbbbbbb → This copy")
        XCTAssertEqual(host.opened, [WindowPolicy.changesWindowID])
        XCTAssertNil(host.main.attachedSheet)
    }

    func testViewEditsOpensTheChangesWindowWithEachEditedFile() async throws {
        let edits: UpstreamHistoryLocalEdits = .changed([
            .init(path: "SKILL.md", linesAdded: 1, linesRemoved: 1,
                  installedText: "---\nname: Installed\n---\nBody\n", currentText: "---\nname: Edited\n---\nBody\n"),
            .init(path: "notes.txt", linesAdded: 1, linesRemoved: 1,
                  installedText: "# Notes\nOld notes\n", currentText: "# Notes\nNew notes\n")
        ])
        let host = try HistoryDiffHost(installed: true, edits: edits)
        defer { host.close() }
        try await host.pressHistory(titled: "View Edits")
        await host.expectLines(old: "name: Installed", new: "name: Edited")
        host.expectHeading(sides: "Installed → This copy")
        XCTAssertTrue(host.texts.contains("notes.txt"))
        try await host.selectFile("notes.txt")
        await host.expectLines(old: "Old notes", new: "New notes", path: "notes.txt")
        XCTAssertEqual(host.opened, [WindowPolicy.changesWindowID])
        XCTAssertNil(host.main.attachedSheet)
    }

    func testAHistoryDiffOfASkillWithNoUpdateStaysReadableAndOffersNoUpdate() async throws {
        let host = try HistoryDiffHost(installed: false)
        defer { host.close() }
        try await host.pressHistory()
        host.validate()
        await host.expectLines(old: "Historical body", new: "Current body")
        host.expectHeading(sides: "Author → Current")
        XCTAssertFalse(host.buttons.contains("Update"))
        XCTAssertFalse(host.buttons.contains("View on GitHub"))
        XCTAssertFalse(host.buttons.contains("Re-check"))
    }

    func testViewChangesAndViewDiffOnTheSameSkillEachReplaceTheOther() async throws {
        let host = try HistoryDiffHost(installed: true, update: true)
        defer { host.close() }
        try await host.pressHistory()
        await host.expectLines(old: "# Demo", new: "Current body")
        host.expectHeading(sides: "bbbbbbb → This copy")
        try await host.pressHistory(titled: "View Changes")
        await host.expectLines(old: "old", new: "new")
        host.expectHeading(sides: "example/repository")
        XCTAssertTrue(host.buttons.contains("Update"))
        try await host.pressHistory()
        await host.expectLines(old: "# Demo", new: "Current body")
        host.expectHeading(sides: "bbbbbbb → This copy")
        XCTAssertFalse(host.buttons.contains("Update"))
    }

    func testAHistoryDiffNeverShowsOldTextAsCurrent() async throws {
        let host = try HistoryDiffHost(installed: false)
        defer { host.close() }
        // The tab still holds text loaded at revision zero.
        try await host.moveCurrentCopy()
        try await host.pressHistory()
        await host.expectText("Preview No Longer Current")
        XCTAssertFalse(host.texts.contains("Current body"))
        XCTAssertFalse(host.buttons.contains("Re-check"))
        let fresh = try HistoryDiffHost(installed: false)
        defer { fresh.close() }
        try await fresh.pressHistory()
        await fresh.expectLines(old: "Historical body", new: "Current body")
        try await fresh.moveCurrentCopy()
        fresh.validate()
        await fresh.expectText("Preview No Longer Current")
        XCTAssertFalse(fresh.texts.contains("Current body"))

        let reading = try HistoryDiffHost(installed: false)
        defer { reading.close() }
        let gate = TestWait.Gate(owner: self)
        defer { gate.open() }
        reading.git.showOperation = { _ in try? gate.wait(); return "# Example\nHistorical body" }
        let action = Task { try await reading.pressHistory() }
        await TestWait.until(failureMessage: "Version read must be held") { gate.waiterCount == 1 }
        try await reading.moveCurrentCopy()
        gate.open()
        try await action.value
        await reading.expectText("Preview No Longer Current")
        XCTAssertFalse(reading.texts.contains("Current body"))

        let edits = try HistoryDiffHost(installed: true, edits: .changed([
            .init(path: "SKILL.md", linesAdded: 1, linesRemoved: 1,
                  installedText: "# Example\nInstalled", currentText: "# Example\nEdited")
        ]))
        defer { edits.close() }
        await edits.waitForAction(titled: "View Edits")
        try await edits.moveCurrentCopy()
        try await edits.pressHistory(titled: "View Edits")
        await edits.expectText("Preview No Longer Current")
        XCTAssertFalse(edits.texts.contains("Edited"))
    }

    func testAHistoryDiffsFallbackStatesNameNoUpdateAndNoGitHub() async throws {
        for (old, current, expected) in [
            ("Same", "Same", "No File Changes"),
            (String(repeating: "x\n", count: 5_000), String(repeating: "y\n", count: 5_000), "Diff Unavailable")
        ] {
            let host = try HistoryDiffHost(installed: false, old: old, current: current)
            defer { host.close() }
            try await host.pressHistory()
            await host.expectText(expected)
            host.expectHeading(sides: "Author → Current")
            XCTAssertFalse(host.texts.contains { $0.localizedCaseInsensitiveContains("github") })
            XCTAssertFalse(host.texts.contains { $0.localizedCaseInsensitiveContains("update") })
            XCTAssertFalse(host.buttons.contains("View on GitHub"))
        }
    }
}

@MainActor
private final class HistoryDiffHost {
    let fixture: UpdateReviewFixture
    let skill: Skill
    let preview: ViewChangesViewModel
    let updates: UpdatesViewModel
    let history: UpstreamHistoryViewModel
    let git: SkillHistoryRecordingGit
    let main: NSWindow
    let changes: NSWindow
    let historyHost: NSHostingView<AnyView>
    private(set) var opened: [String] = []
    private var routing: UpdateReviewRouting!

    init(installed: Bool, update: Bool = false, edits: UpstreamHistoryLocalEdits = .none,
         old: String = "Historical body", current: String = "Current body") throws {
        fixture = try UpdateReviewFixture()
        skill = try fixture.skill("demo")
        if !installed { skill.installedOrigin = nil }
        skill.updateAvailable = update
        try fixture.context.save()
        try fixture.files.writeFile(at: fixture.root + "/skills/demo/SKILL.md", content: "# Example\n" + current)
        let rows = update ? [try UpdatesViewModel.makeRow(skill: skill, driftedLocally: false)] : []
        (updates, preview) = fixture.review(rows: rows, diff: { _, _ in
            try PinnedSkillDiff.build(comparison: FileTreeComparison(changes: [
                FileTreeChange(path: "SKILL.md", kind: .modified,
                               content: .text(old: "# Example\nold\n", new: "# Example\nnew\nextra\n"))
            ], unreadFileCount: 0, bytesRead: 0))
        })
        let result = Self.result(edits: edits)
        history = historyOwner(read: { _, _, _ in result })
        main = Self.window()
        changes = Self.window()
        historyHost = NSHostingView(rootView: AnyView(EmptyView()))
        git = SkillHistoryRecordingGit()
        routing = UpdateReviewRouting(preview: preview, updates: updates, library: fixture.library,
            context: fixture.context, windows: { [weak self] in self.map { [$0.main, $0.changes] } ?? [] },
            openWindow: { [weak self] in self?.opened.append($0); self?.changes.makeKeyAndOrderFront(nil) })
        git.commits = [
            GitCommit(sha: "head", author: "Author", date: Date(timeIntervalSince1970: 2), subject: "Current"),
            GitCommit(sha: "old", author: "Author", date: Date(timeIntervalSince1970: 1), subject: "Older")
        ]
        git.documents = ["old": "---\nname: Old\n---\n# Example\n" + old]
        let routing = routing!
        historyHost.rootView = AnyView(VStack {
            routing.banner(for: skill)
            SkillHistoryTab(skill: skill, currentBody: "# Example\n" + current, library: fixture.library,
                upstreamHistory: history, localRevision: .initial,
                onOpenUpdates: {}, onUpdateCheck: { _ in }, git: git,
                store: fixture.library.skillStore, workingDir: fixture.root,
                currentRevision: .initial, onViewComparison: { routing.presentHistory($0) })
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .modelContainer(fixture.container))
        main.contentView = historyHost
        changes.contentView = NSHostingView(rootView: AnyView(routing.window.modelContainer(fixture.container)))
        NSApp.activate(ignoringOtherApps: true)
        main.makeKeyAndOrderFront(nil)
    }

    var texts: [String] {
        roots.flatMap { RenderedViewTestSupport.values(in: $0) }
            .compactMap { $0 as? Text }.flatMap(RenderedViewTestSupport.strings)
    }

    var buttons: [String] {
        roots.flatMap { RenderedControlInputs.controls(in: $0) }.filter { $0.kind == .button }.map(\.title)
    }

    private var roots: [NSView] {
        [changes.contentView].compactMap { $0 } + (changes.toolbar?.items.compactMap(\.view) ?? [])
    }

    func pressHistory(titled title: String = "View Diff") async throws {
        main.makeKeyAndOrderFront(nil)
        var pressed = false
        await waitForAction(titled: title)
        pressed = HistoryAccessibility.pressButtonIfFound(titled: title, in: historyHost)
        if !pressed { pressed = try await clickRenderedAction(titled: title) }
        _ = try XCTUnwrap(pressed ? true : nil, "The rendered \(title) action must open its comparison: \(texts)")
        await TestWait.until(failureMessage: "The History action must open the comparison window") { !self.opened.isEmpty }
        _ = try XCTUnwrap(opened.last)
        validate()
    }

    func waitForAction(titled title: String) async {
        await TestWait.until(failureMessage: "History action \(title) must render") {
            let texts = RenderedViewTestSupport.values(in: self.historyHost).compactMap { $0 as? Text }
                .flatMap(RenderedViewTestSupport.strings)
            return texts.contains(title)
        }
    }

    /// History's hosted buttons expose no AX nodes on this SDK. As in the existing History
    /// hosts, dispatch real pointer events within the action column. Diff/Edits are its first
    /// button; Restore and Update are outside this column. The window's rendered sides confirm
    /// which action ran. No presenter, captured action or model method replaces the click.
    private func clickRenderedAction(titled title: String) async throws -> Bool {
        let expected = title == "View Changes" ? "example/repository"
            : title == "View Edits" ? "Installed → This copy"
            : skill.hasLinkedOrigin ? "bbbbbbb → This copy" : "Author → Current"
        let xs = title == "View Changes"
            ? stride(from: historyHost.bounds.maxX - 260, through: historyHost.bounds.maxX - 160, by: 8)
            : stride(from: 60.0, through: 116.0, by: 8)
        for xPosition in xs {
            for yPosition in stride(from: historyHost.bounds.maxY - 8, through: 8, by: -8) {
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = try XCTUnwrap(NSEvent.mouseEvent(with: type,
                        location: NSPoint(x: xPosition, y: yPosition), modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: main.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                    main.sendEvent(event)
                }
                try await Task.sleep(for: .milliseconds(2))
                if texts.contains(where: { $0.contains(expected) }) { return true }
                if title == "View Diff", RenderedViewTestSupport.hasButtonProgress(in: historyHost) { return true }
            }
        }
        return false
    }

    func validate() {
        preview.validate(skills: [skill], folderRevisions: fixture.library.folderChangeRevisions, context: fixture.context)
    }

    func expectText(_ text: String) async {
        await TestWait.until(failureMessage: "Missing rendered text: \(text)",
                             diagnostics: { self.texts.joined(separator: " | ") }, {
            self.texts.contains(text)
        })
    }

    func expectHeading(sides: String) {
        XCTAssertTrue(texts.contains("Changes to Demo"), "\(texts)")
        XCTAssertTrue(texts.contains { $0.contains(sides) }, "\(texts)")
    }

    func expectLines(old: String, new: String, path: String = "SKILL.md") async {
        await TestWait.until(failureMessage: "Both comparison sides must render",
                             diagnostics: { self.texts.joined(separator: " | ") }, {
            self.texts.contains(old) && self.texts.contains(new)
        })
        XCTAssertTrue(texts.contains(path), "\(texts)")
        // Read the live row containers so direction cannot pass with two swapped text sides.
        let rows = roots.flatMap { RenderedViewTestSupport.values(in: $0) }.filter {
            String(reflecting: type(of: $0)).hasPrefix("SwiftUI.HStack<")
        }
        func strings(_ value: Any, depth: Int) -> [String] {
            if let text = value as? Text { return RenderedViewTestSupport.strings(in: text) }
            guard depth > 0, Mirror(reflecting: value).displayStyle != .class else { return [] }
            return Mirror(reflecting: value).children.flatMap { strings($0.value, depth: depth - 1) }
        }
        XCTAssertTrue(rows.contains { let labels = strings($0, depth: 20); return labels.contains("−") && labels.contains(old) })
        XCTAssertTrue(rows.contains { let labels = strings($0, depth: 20); return labels.contains("+") && labels.contains(new) })
    }

    func selectFile(_ path: String) async throws {
        // Native sidebar selection, not the model's selection helper.
        func table(in view: NSView) -> NSTableView? {
            (view as? NSTableView) ?? view.subviews.lazy.compactMap { table(in: $0) }.first
        }
        let table = try XCTUnwrap(table(in: XCTUnwrap(changes.contentView)))
        let row = (0..<table.numberOfRows).first { index in
            guard let view = table.view(atColumn: 0, row: index, makeIfNecessary: false) else { return false }
            return RenderedViewTestSupport.values(in: view).compactMap { $0 as? Text }
                .flatMap(RenderedViewTestSupport.strings).contains(path)
        }
        table.selectRowIndexes(IndexSet(integer: try XCTUnwrap(row)), byExtendingSelection: false)
    }

    func moveCurrentCopy() async throws {
        try fixture.files.writeFile(at: fixture.root + "/skills/demo/SKILL.md", content: "A newer copy\n")
        let revision = fixture.library.appWriteRevision
        fixture.library.publishAppWriteRevision()
        await TestWait.until(failureMessage: "App write did not publish") {
            self.fixture.library.appWriteRevision > revision
        }
    }
    func close() { main.close(); changes.close(); try? fixture.cleanup() }

    private static func result(edits: UpstreamHistoryLocalEdits) -> UpstreamHistoryResult {
        let base = historyResult(localEdits: edits)
        let row = UpstreamHistoryRow(sha: base.headCommit, author: "Author", date: .distantPast, subject: "Older",
                                     filesChanged: 1, linesAdded: 1, linesRemoved: 1,
                                     skillMarkdown: .text("---\nname: Upstream\n---\n# Example\n# Demo"))
        return UpstreamHistoryResult(headCommit: base.headCommit, rows: [row],
            installedPosition: .olderThanRowsRead, hasOlderHistory: false, installedBaseline: base.installedBaseline,
            localEdits: edits, windowCount: 1)
    }

    private static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        return window
    }
}
