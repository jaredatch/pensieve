import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Pensieve

@MainActor
final class ImportWizardHostTests: XCTestCase {
    func testResultsAndDoneSummaryCountsReasonsAndReplacesLaterScan() {
        let scanner = ReportScanner()
        let model = ImportViewModel(
            scanner: scanner,
            skillStore: SkillStore(fileService: FileService(), baseDir: TestPaths.skillsDir),
            lockPath: TestTemporaryDirectory.path + "import-lock-" + UUID().uuidString,
            manifestRoot: TestPaths.storeRoot
        )
        model.scan()
        let expected = "Skipped 5 entries: 2 symlinks or special files; 1 file larger than 4 MiB; "
            + "1 unreadable file or folder; 1 file that isn't UTF-8 text."

        XCTAssertEqual(model.scanSummary, expected)
        XCTAssertEqual(ImportScanSummary(summary: model.scanSummary).summary, expected)

        scanner.skipped = [.init(path: "/fixture/later", reason: .tooLarge)]
        XCTAssertEqual(model.scanFolder("/fixture/folder"), .nothingFound)
        XCTAssertEqual(model.scanSummary, "Skipped 1 entry: 1 file larger than 4 MiB.")
        scanner.skipped = []
        model.scan()
        XCTAssertNil(model.scanSummary)
    }

    func testImportedFallbackNamesHaveSeparateRowsAndScrollWithinSheet() throws {
        let root = TestTemporaryDirectory.path + "ImportWizardHostTests-\(UUID().uuidString)"
        let files = FileService()
        defer { try? files.deleteDirectory(at: root) }
        let names = (0..<30).map { "Skill \($0) with a long descriptive name" }
        for name in names {
            try files.writeFile(
                at: root + "/source/\(name)/SKILL.md",
                content: "---\nname: \(name)\ndescription: Original\nmetadata: [unclosed\n---\nBody"
            )
        }
        try files.writeData(at: root + "/source/invalid/SKILL.md", data: Data([0xFF]))
        let scanner = ImportScanner(
            fileService: files, claudeSkillsDir: root + "/none-claude", grokSkillsDir: root + "/none-grok",
            cursorRulesDir: root + "/none-cursor", codexSkillsDir: root + "/none-codex", storeRoot: root + "/store"
        )
        let model = ImportViewModel(
            scanner: scanner,
            skillStore: SkillStore(fileService: files, baseDir: root + "/store/skills"),
            lockPath: TestTemporaryDirectory.path + "import-lock-" + UUID().uuidString,
            manifestRoot: TestPaths.storeRoot
        )
        XCTAssertEqual(model.scanFolder(root + "/source"), .found(30))
        XCTAssertEqual(model.scanSummary, "Skipped 1 entry: 1 file that isn't UTF-8 text.")
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        model.importSelected(context: container.mainContext)
        XCTAssertNil(model.error)
        // This is the exact row array that the done view iterates. Malformed YAML uses the folder name.
        XCTAssertEqual(model.importNotices.count, 30)
        XCTAssertEqual(Set(model.importNotices), Set(names.map { "\($0): frontmatter was kept as text." }))
        for notice in model.importNotices {
            XCTAssertFalse(notice.contains("\n"))
        }
        let fixture = host(AnyView(ImportDoneView(importVM: model, onDone: {})))
        defer { fixture.window.close() }
        let fittingSize = fixture.host.fittingSize
        XCTAssertEqual(fittingSize.width, 600, accuracy: 0.5)
        XCTAssertGreaterThan(fittingSize.height, 0)
        XCTAssertLessThanOrEqual(fittingSize.height, 500.5, "The entire done step, including Done, must fit")
        XCTAssertEqual(scrollViews(in: fixture.host).count, 1)
        let scroller = try XCTUnwrap(scrollViews(in: fixture.host).first)
        XCTAssertLessThanOrEqual(scroller.frame.height, 100.5)
        XCTAssertGreaterThan(scroller.contentView.bounds.height, 0)
        let document = try XCTUnwrap(scroller.documentView)
        XCTAssertGreaterThan(document.bounds.height, scroller.contentView.bounds.height)
        let firstOrigin = scroller.contentView.bounds.origin
        let range = document.bounds.height - scroller.contentView.bounds.height
        scroller.contentView.scroll(to: NSPoint(x: firstOrigin.x, y: firstOrigin.y + range))
        scroller.reflectScrolledClipView(scroller.contentView)
        fixture.host.layoutSubtreeIfNeeded()
        XCTAssertNotEqual(scroller.contentView.bounds.origin.y, firstOrigin.y)
        XCTAssertEqual(fixture.host.fittingSize, fittingSize)
    }

    private func host(_ view: AnyView) -> (host: NSHostingView<AnyView>, window: NSWindow) {
        // Constrain width only: a fixed 500-point root height would hide overflowing sheet content.
        let host = NSHostingView(rootView: AnyView(view.frame(width: 600)))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        return (host, window)
    }

    private func scrollViews(in root: NSView) -> [NSScrollView] {
        [root].compactMap { $0 as? NSScrollView } + root.subviews.flatMap(scrollViews(in:))
    }
}

private final class ReportScanner: ImportScannerProtocol {
    var skipped: [ImportScanSkip] = [
        .init(path: "/fixture/one", reason: .notRegular),
        .init(path: "/fixture/two", reason: .notRegular),
        .init(path: "/fixture/three", reason: .tooLarge),
        .init(path: "/fixture/four", reason: .unreadable),
        .init(path: "/fixture/five", reason: .invalidUTF8)
    ]

    func scan() -> [DiscoveredSkill] { [] }
    func scanFolder(_ path: String) -> [DiscoveredSkill] { [] }
    func isInsideStore(_ path: String) -> Bool { false }
    func scanWithReport() -> ImportScanReport { ImportScanReport(skipped: skipped) }
    func scanFolderWithReport(_ path: String) -> ImportScanReport { ImportScanReport(skipped: skipped) }
}
