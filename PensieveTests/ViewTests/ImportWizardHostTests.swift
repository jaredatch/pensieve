import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Pensieve

@MainActor
final class ImportWizardHostTests: XCTestCase {
    func testRefusedImportKeepsSelectionAndAllowsRetry() async throws {
        let root = TestTemporaryDirectory.path + "ImportWizardRetry-" + UUID().uuidString
        let files = FileService()
        defer { try? files.deleteDirectory(at: root) }
        for name in ["Chosen", "Unselected"] {
            try files.writeFile(at: root + "/source/\(name)/SKILL.md",
                                content: "---\nname: \(name)\ndescription: Description\n---\n\nBody")
        }
        let lockPath = root + "/support/sync.lock"
        let model = retryModel(root: root, files: files, lockPath: lockPath)
        let selection = model.selectedSkills
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let fixture = hostWizard(model: model, context: container.mainContext)
        defer { fixture.window.close() }

        // An existing directory at the lock path makes the real open fail even for a privileged test host.
        try files.createDirectory(at: lockPath)
        let unopenablePressed = pressImport(in: fixture.host)
        XCTAssertTrue(unopenablePressed)
        guard unopenablePressed else { return }
        await TestWait.until(failureMessage: "An unopenable lock must report its error") { model.error != nil }
        assertLockAccessAdvice(model.error)
        XCTAssertEqual(model.selectedSkills, selection)
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<Skill>()).isEmpty)
        XCTAssertFalse(files.directoryExists(at: root + "/store"))
        try await assertSelectionRendered(model: model, in: fixture.host)

        try files.deleteDirectory(at: lockPath)
        let held = try XCTUnwrap(SyncLock.tryAcquire(at: lockPath))
        defer { held.release() }
        let busyPressed = pressImport(in: fixture.host)
        XCTAssertTrue(busyPressed)
        guard busyPressed else { return }
        await TestWait.until(failureMessage: "The busy lock must report its refusal") {
            model.error == "Pensieve is busy syncing or finishing another task. Try importing again in a moment."
        }
        XCTAssertEqual(model.selectedSkills, selection)
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<Skill>()).isEmpty)
        XCTAssertFalse(files.directoryExists(at: root + "/store"))
        try await assertSelectionRendered(model: model, in: fixture.host)

        held.release()
        let retryPressed = pressImport(in: fixture.host)
        XCTAssertTrue(retryPressed)
        await TestWait.until(failureMessage: "Retry must import the preserved selection") { model.importedSkillCount == 1 }
        XCTAssertNil(model.error)
        XCTAssertEqual(model.selectedSkills, selection)
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<Skill>()).map(\.directoryName), ["chosen"])
        XCTAssertEqual(try files.listDirectory(at: root + "/store/skills"), ["chosen"])
        await assertDoneRendered(in: fixture.host)
        XCTAssertTrue(pressImport(in: fixture.host))
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<Skill>()).count, 1,
                       "The completed wizard's Return action must not import a second time")
    }

    func testResultsAndDoneSummaryCountsReasonsAndReplacesLaterScan() {
        let scanner = ReportScanner()
        let model = ImportViewModel(
            scanner: scanner,
            skillStore: SkillStore(fileService: FileService(), baseDir: TestPaths.skillsDir, storeRoot: TestPaths.storeRoot),
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
            skillStore: SkillStore(fileService: files, baseDir: root + "/store/skills", storeRoot: root + "/store"),
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

    private func hostWizard(model: ImportViewModel, context: ModelContext)
        -> (host: NSHostingView<AnyView>, window: NSWindow) {
        let fixture = host(AnyView(ImportWizardView(importVM: model, writesAllowed: true, startsAtResults: true)
            .environment(\.modelContext, context).background(Color(nsColor: .windowBackgroundColor))))
        fixture.window.styleMask = [.titled, .closable]
        fixture.host.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
        return fixture
    }

    private func retryModel(root: String, files: FileService, lockPath: String) -> ImportViewModel {
        let model = ImportViewModel(scanner: ImportScanner(fileService: files,
            claudeSkillsDir: root + "/source", grokSkillsDir: root + "/grok", cursorRulesDir: root + "/cursor",
            codexSkillsDir: root + "/codex", storeRoot: root + "/store"),
            skillStore: SkillStore(fileService: files, baseDir: root + "/store/skills", storeRoot: root + "/store"),
            lockPath: lockPath, manifestRoot: root + "/store")
        model.scan()
        model.selectedSkills = Set(model.discoveredSkills.filter { $0.name == "Chosen" }.map(\.sourcePath))
        return model
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

    private func assertLockAccessAdvice(_ error: String?) {
        XCTAssertEqual(error, "Pensieve couldn't open its lock file, so nothing was imported. "
            + "Check that you can write to Pensieve's Application Support folder, then try again.")
        XCTAssertFalse(error?.contains(POSIXError(.EISDIR).localizedDescription) == true,
                       "The advice uses plain sentences; the native cause belongs in the log")
    }

    private func assertDoneRendered(in host: NSHostingView<AnyView>) async {
        await TestWait.until(timeout: .seconds(TestWait.firstRenderTimeoutSeconds),
                             failureMessage: "Successful retry must render Done") {
            self.renderedValues(in: host).compactMap { $0 as? Text }
                .flatMap(self.renderedStrings).contains("Done")
        }
        XCTAssertFalse(renderedValues(in: host).compactMap { $0 as? Text }
            .flatMap(renderedStrings).contains("Import Selected"))
    }

    private func assertSelectionRendered(model: ImportViewModel, in host: NSHostingView<AnyView>) async throws {
        let error = try XCTUnwrap(model.error)
        await TestWait.until(timeout: .seconds(TestWait.firstRenderTimeoutSeconds),
                             failureMessage: "Refusal must render its message on the retained selection", diagnostics: {
            let values = self.renderedValues(in: host)
            return values.compactMap { $0 as? Text }.flatMap(self.renderedStrings).description
        }, {
            let values = self.renderedValues(in: host)
            let strings = values.compactMap { $0 as? Text }.flatMap(self.renderedStrings)
            return strings.contains("Import Selected") && strings.contains(error)
        })
        let values = renderedValues(in: host)
        XCTAssertFalse(values.compactMap { $0 as? Text }.flatMap(renderedStrings).contains("Done"))
        let texts = values.compactMap { $0 as? Text }
        let strings = texts.flatMap(renderedStrings)
        XCTAssertTrue(strings.contains("Chosen"))
        XCTAssertTrue(strings.contains("Unselected"))
        XCTAssertTrue(texts.contains { String(reflecting: $0).contains("\"1 selected\"") },
                      "The rendered selection count must retain the chosen skill")
    }

    private func renderedStrings(in text: Text) -> [String] {
        RenderedViewTestSupport.strings(in: text)
    }

    private func renderedValues(in host: NSHostingView<AnyView>) -> [Any] {
        RenderedViewTestSupport.values(in: host)
    }

    private func pressImport(in root: NSView) -> Bool {
        guard let window = root.window,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: 36) else { return false }
        root.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        return root.performKeyEquivalent(with: event) || window.performKeyEquivalent(with: event)
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
