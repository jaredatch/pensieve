import AppKit
import SwiftData
import SwiftUI
import XCTest
import Vision
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
        let unopenablePressed = await pressImport(in: fixture.host)
        XCTAssertTrue(unopenablePressed)
        guard unopenablePressed else { return }
        await TestWait.until(failureMessage: "An unopenable lock must report its error") { model.error != nil }
        XCTAssertFalse(model.error?.localizedCaseInsensitiveContains("sync is running") == true)
        XCTAssertTrue(model.error?.localizedCaseInsensitiveContains("lock file") == true)
        XCTAssertEqual(model.selectedSkills, selection)
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<Skill>()).isEmpty)
        XCTAssertFalse(files.directoryExists(at: root + "/store"))
        XCTAssertTrue(try renderedText(in: fixture.host).map(\.text).joined(separator: " ").contains("lock"))

        try files.deleteDirectory(at: lockPath)
        let held = try XCTUnwrap(SyncLock.tryAcquire(at: lockPath))
        defer { held.release() }
        let busyPressed = await pressImport(in: fixture.host)
        XCTAssertTrue(busyPressed)
        guard busyPressed else { return }
        await TestWait.until(failureMessage: "The busy lock must report its refusal") {
            model.error?.localizedCaseInsensitiveContains("sync is running") == true
        }
        XCTAssertEqual(model.selectedSkills, selection)
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<Skill>()).isEmpty)
        XCTAssertFalse(files.directoryExists(at: root + "/store"))
        let busyText = try renderedText(in: fixture.host).map(\.text).joined(separator: " ")
        XCTAssertTrue(busyText.localizedCaseInsensitiveContains("sync"))

        held.release()
        let retryPressed = await pressImport(in: fixture.host)
        XCTAssertTrue(retryPressed)
        await TestWait.until(failureMessage: "Retry must import the preserved selection") { model.importedSkillCount == 1 }
        XCTAssertNil(model.error)
        XCTAssertEqual(model.selectedSkills, selection)
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<Skill>()).map(\.directoryName), ["chosen"])
        XCTAssertEqual(try files.listDirectory(at: root + "/store/skills"), ["chosen"])
        await TestWait.until(failureMessage: "Successful retry must reach Done") {
            (try? self.renderedText(in: fixture.host).contains { $0.text == "Done" }) == true
        }
    }

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

    private func hostWizard(model: ImportViewModel, context: ModelContext)
        -> (host: NSHostingView<AnyView>, window: NSWindow) {
        let fixture = host(AnyView(ImportWizardView(importVM: model, writesAllowed: true, startsAtResults: true)
            .environment(\.modelContext, context).background(Color(nsColor: .windowBackgroundColor))))
        fixture.window.styleMask = [.titled, .closable]
        fixture.host.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
        NSApp.activate(ignoringOtherApps: true)
        fixture.window.makeKeyAndOrderFront(nil)
        return fixture
    }

    private func retryModel(root: String, files: FileService, lockPath: String) -> ImportViewModel {
        let model = ImportViewModel(scanner: ImportScanner(fileService: files,
            claudeSkillsDir: root + "/source", grokSkillsDir: root + "/grok", cursorRulesDir: root + "/cursor",
            codexSkillsDir: root + "/codex", storeRoot: root + "/store"),
            skillStore: SkillStore(fileService: files, baseDir: root + "/store/skills"),
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

    private func pressImport(in root: NSView) async -> Bool {
        var target: CGRect?
        await TestWait.until(timeout: .seconds(TestWait.firstRenderTimeoutSeconds),
                             failureMessage: "The selection must retain its Import Selected button", diagnostics: {
            ((try? self.renderedText(in: root)) ?? []).map(\.text).joined(separator: " | ")
        }, {
            target = try? self.renderedText(in: root).first { $0.text.contains("Import Selected") }?.bounds
            return target != nil
        })
        guard let target, let window = root.window else { return false }
        let y = root.isFlipped ? 1 - target.midY : target.midY
        let point = root.convert(NSPoint(x: target.midX * root.bounds.width, y: y * root.bounds.height), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return false }
            window.sendEvent(event)
        }
        return true
    }

    // SwiftUI omits virtual accessibility controls in this host. Read the real 2x render,
    // as AddProjectSheetHostTests does, and click the recognized footer caption.
    private func renderedText(in root: NSView) throws -> [(text: String, bounds: CGRect)] {
        root.layoutSubtreeIfNeeded()
        let bounds = root.bounds
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = bounds.size
        root.cacheDisplay(in: bounds, to: bitmap)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage)).perform([request])
        return (request.results ?? []).compactMap {
            guard let candidate = $0.topCandidates(1).first else { return nil }
            return (candidate.string, $0.boundingBox)
        }
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
