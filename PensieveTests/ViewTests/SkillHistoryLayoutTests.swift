import AppKit
import ApplicationServices
import SwiftUI
import XCTest
@testable import Pensieve

@MainActor
final class SkillHistoryLayoutTests: XCTestCase {
    func testOwnWindowAccessibilityReadStaysOnMainThread() async throws {
        let fixture = try installedTab(rowCount: 3)
        let host = makeHost(fixture.tab, height: 480)
        defer { host.window.close() }
        let tree = try await waitForRows(in: host.window)
        XCTAssertTrue(tree.readOnMainThread, "Own-process accessibility read ran on main thread: \(tree.readOnMainThread)")
    }

    func testInstalledRowsKeep24PointGapsAtShortAndTallHeights() async throws {
        let tab = try installedTab(rowCount: 3).tab
        try await assertFixedGaps(tab)
    }

    func testAuthoredRowsKeep24PointGapsAtShortAndTallHeights() async throws {
        let base = NSTemporaryDirectory() + "SkillHistoryLayoutTests-\(UUID().uuidString)"
        let store = SkillStore(fileService: FileService(), baseDir: base)
        let git = SkillHistoryRecordingGit()
        git.commits = (0..<4).map { index in
            GitCommit(sha: "sha-\(index)", author: "Author", date: Date(), subject: subject(index))
        }
        let tab = SkillHistoryTab(
            skill: Skill(name: "Example", directoryName: "example"),
            currentBody: "# Current",
            library: SkillLibraryViewModel(skillStore: store),
            upstreamHistory: historyOwner(read: { _, _, _ in historyResult() }),
            localRevision: .initial,
            onOpenUpdates: {},
            onUpdateCheck: { _ in },
            git: git,
            store: store,
            workingDir: base
        )
        try await assertFixedGaps(AnyView(tab))
    }

    func testInstalledTimelineShowsTenNewestCommitsThenRevealsHeldRows() async throws {
        let fixture = try installedTab(rowCount: 12)
        let host = makeHost(fixture.tab, height: 1800)
        defer { host.window.close() }
        let tree = try await waitForRows(in: host.window)

        XCTAssertEqual(visibleSubjects(in: tree), (0..<10).map(subject))
        XCTAssertTrue(tree.descendants.contains {
            ["AXButton", "AXLink"].contains($0.role) && $0.label == "Show older commits"
        })
        let pressed = HistoryAccessibility.press("Show older commits", windowTitle: host.window.title)
        XCTAssertTrue(pressed)
        let revealed = try await waitForRows(in: host.window, lastSubject: subject(11))
        XCTAssertEqual(visibleSubjects(in: revealed), (0..<12).map(subject))
        XCTAssertEqual(fixture.history.currentRequest?.windowCount, 1)
        XCTAssertFalse(revealed.descendants.contains { $0.label == "Show older commits" })
    }

    func testInstalledTimelineShowsAllFewerThanTenCommitsAndKeepsOlderWindowRule() async throws {
        for hasOlder in [false, true] {
            let fixture = try installedTab(rowCount: 6, hasOlder: hasOlder)
            let host = makeHost(fixture.tab, height: 1000)
            defer { host.window.close() }
            let tree = try await waitForRows(in: host.window)

            XCTAssertEqual(visibleSubjects(in: tree), (0..<6).map(subject))
            XCTAssertEqual(tree.descendants.contains {
                ["AXButton", "AXLink"].contains($0.role) && $0.label == "Show older commits"
            }, hasOlder)
        }
    }

    private func installedTab(
        rowCount: Int,
        hasOlder: Bool = false
    ) throws -> (tab: AnyView, history: UpstreamHistoryViewModel) {
        let skill = installedHistorySkill()
        let origin = try XCTUnwrap(skill.installedOrigin)
        let rows = (0..<rowCount).map { index in
            UpstreamHistoryRow(
                sha: String(format: "%040x", index + 1),
                author: "Author",
                date: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 - index)),
                subject: subject(index),
                filesChanged: 1,
                linesAdded: 2,
                linesRemoved: 1,
                skillMarkdown: index == 1 ? nil : .text("# Version \(index)")
            )
        }
        let result = UpstreamHistoryResult(
            headCommit: rows[0].sha,
            rows: rows,
            installedPosition: .at(sha: rows[0].sha),
            hasOlderHistory: hasOlder,
            installedBaseline: .files([]),
            localEdits: .none,
            windowCount: 1
        )
        let history = historyOwner(read: { _, _, _ in result })
        let tab = InstalledSkillHistoryView(
            skill: skill,
            currentBody: "# Current",
            origin: origin,
            updateAvailable: false,
            localRevision: .initial,
            onOpenUpdates: {},
            onUpdateCheck: { _ in },
            history: history
        )
        return (AnyView(tab), history)
    }

    private func assertFixedGaps(
        _ tab: AnyView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        var measured: [[CGFloat]] = []
        for height: CGFloat in [480, 1000] {
            let host = makeHost(tab, height: height)
            defer { host.window.close() }
            let tree = try await waitForRows(in: host.window)
            let bounds = try (0..<3).map { index in
                try rowContentBounds(subject: subject(index), in: tree)
            }
            let gaps = (0..<2).map { bounds[$0 + 1].minY - bounds[$0].maxY }
            measured.append(gaps)
            for (index, gap) in gaps.enumerated() {
                XCTAssertEqual(gap, 24, accuracy: 1,
                               "row \(index) bottom gap at height \(height)", file: file, line: line)
            }
        }
        for index in 0..<2 {
            XCTAssertEqual(measured[0][index], measured[1][index], accuracy: 1,
                           "row \(index) gap must survive resizing", file: file, line: line)
        }
    }

    private func makeHost(_ tab: AnyView, height: CGFloat) -> (view: NSView, window: NSWindow) {
        let layout = SkillDetailScrollLayout(skillID: UUID(), contentOwnsScroller: false) {
            EmptyView()
        } tabContent: {
            tab
        }
        let controller = NSHostingController(rootView: AnyView(layout.frame(width: 640, height: height)))
        let view = controller.view
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.title = "History layout " + UUID().uuidString
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        view.layoutSubtreeIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return (view, window)
    }

    private func waitForRows(in window: NSWindow, lastSubject: String? = nil) async throws -> HistoryAccessibility.Node {
        let expected = lastSubject ?? subject(2)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        var last: HistoryAccessibility.Node?
        var previous: HistoryAccessibility.Node?
        repeat {
            window.contentView?.layoutSubtreeIfNeeded()
            last = await HistoryAccessibility.snapshot(windowTitle: window.title)
            // SwiftUI can expose the labels before their screen positions have settled.
            if let last, last == previous,
               last.descendants.contains(where: { $0.label == expected }) { return last }
            previous = last
            try await Task.sleep(for: .milliseconds(10))
        } while clock.now < deadline
        XCTFail("History rows did not load: \(last?.descendants.map(\.label) ?? [])")
        throw LayoutFailure.rowsUnavailable
    }

    /// Accessibility positions use screen coordinates with Y increasing downward. The row's text
    /// and controls give its content bounds independently of the dot column and bottom padding.
    private func rowContentBounds(subject: String, in tree: HistoryAccessibility.Node) throws -> CGRect {
        let row = try XCTUnwrap(tree.descendants.first { element in
            guard element.role == "AXGroup" else { return false }
            let labels = element.descendants.map(\.label)
            return labels.contains(subject) && labels.filter { $0.hasPrefix("Version ") }.count == 1
        }, "No accessibility row containing \(subject)")
        let content = row.descendants.filter { !$0.label.isEmpty && $0.children.isEmpty && !$0.frame.isEmpty }
        XCTAssertFalse(content.isEmpty)
        return content.map(\.frame).reduce(CGRect.null) { $0.union($1) }
    }

    private func visibleSubjects(in tree: HistoryAccessibility.Node) -> [String] {
        tree.descendants.filter { $0.label.hasPrefix("Version ") && !$0.frame.isEmpty }
            .sorted { $0.frame.minY < $1.frame.minY }.map(\.label)
    }

    private enum LayoutFailure: Error { case rowsUnavailable }

    private func subject(_ index: Int) -> String {
        index == 1 ? "Version 11\nA second subject line" : "Version \(12 - index)"
    }
}

/// Queries our own process's exported accessibility tree, including SwiftUI text nodes omitted by
/// direct NSView queries. Reads and presses stay on the main actor with the AppKit window and callbacks.
@MainActor
private enum HistoryAccessibility {
    struct Node: Equatable {
        let role: String
        let label: String
        let frame: CGRect
        let children: [Node]
        let readOnMainThread = Thread.isMainThread
        var descendants: [Node] { children.flatMap { [$0] + $0.descendants } }
    }

    static func snapshot(windowTitle: String) async -> Node? {
        guard let window = window(titled: windowTitle) else { return nil }
        return node(window)
    }

    static func press(_ title: String, windowTitle: String) -> Bool {
        guard let window = window(titled: windowTitle) else { return false }
        var pending = [window]
        while let element = pending.popLast() {
            if label(element) == title, ["AXButton", "AXLink"].contains(string(.role, of: element)) {
                return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
            }
            pending.append(contentsOf: children(element))
        }
        return false
    }

    private static func window(titled title: String) -> AXUIElement? {
        let app = AXUIElementCreateApplication(getpid())
        return (attribute(.windows, of: app) as? [AXUIElement])?.first { string(.title, of: $0) == title }
    }

    private static func node(_ element: AXUIElement) -> Node {
        var position = CGPoint.zero
        var size = CGSize.zero
        // The Core Foundation type ID proves these references are AXValues before the pointer casts.
        if let value = attribute(.position, of: element), CFGetTypeID(value) == AXValueGetTypeID() {
            AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgPoint, &position)
        }
        if let value = attribute(.size, of: element), CFGetTypeID(value) == AXValueGetTypeID() {
            AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgSize, &size)
        }
        return Node(role: string(.role, of: element), label: label(element),
                    frame: CGRect(origin: position, size: size), children: children(element).map(node))
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(.children, of: element) as? [AXUIElement] ?? []
    }

    private static func label(_ element: AXUIElement) -> String {
        [.value, .title, .description].map { string($0, of: element) }.first { !$0.isEmpty } ?? ""
    }

    private static func string(_ name: NSAccessibility.Attribute, of element: AXUIElement) -> String {
        attribute(name, of: element) as? String ?? ""
    }

    private static func attribute(_ name: NSAccessibility.Attribute, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name.rawValue as CFString, &value) == .success else { return nil }
        return value
    }
}
