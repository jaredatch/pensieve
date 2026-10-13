import AppKit
import SwiftUI
import XCTest
@testable import Pensieve

final class ImportResultsViewTests: XCTestCase {
    @MainActor
    func testBothPickersRenderSingularAndPluralFoundTitles() async {
        let importModel = ImportViewModel(
            scanner: EmptyImportScanner(),
            skillStore: SkillStore(fileService: FileService(), baseDir: TestPaths.skillsDir, storeRoot: TestPaths.storeRoot),
            lockPath: TestTemporaryDirectory.path + "import-lock-" + UUID().uuidString,
            manifestRoot: TestPaths.storeRoot
        )
        for (count, expected) in [(1, "Found 1 Skill"), (2, "Found 2 Skills"), (5, "Found 5 Skills")] {
            importModel.discoveredSkills = (0..<count).map {
                DiscoveredSkill(name: "Skill \($0)", body: "Body", sourcePlatform: "folder",
                                sourcePath: "/fixture/skill-\($0)/SKILL.md")
            }
            let candidates = (0..<count).map {
                SkillCandidate(path: "skills/skill-\($0)", slug: "skill-\($0)", name: "Skill \($0)",
                               skillDescription: "Description", treeHash: "tree", containsSymlink: false,
                               unavailableReason: nil)
            }
            let installModel = SkillInstallViewModel(
                service: SkillInstallViewModelTests.ScriptedInstallService(candidates: candidates)
            )
            installModel.urlText = "https://github.com/example/skills"
            await installModel.fetchAndReport()

            await assertFoundTitle(expected, in: AnyView(ImportResultsView(importVM: importModel, onImport: {})),
                                   picker: "Import from Folder")
            await assertFoundTitle(expected, in: AnyView(InstallPickerView(model: installModel)),
                                   picker: "Add Skill from GitHub")
        }
    }

    @MainActor
    private func assertFoundTitle(_ expected: String, in view: AnyView, picker: String) async {
        var environment = EnvironmentValues()
        environment.locale = Locale(identifier: "en_US")
        let host = NSHostingView(rootView: view.environment(\.locale, environment.locale))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = host
        defer {
            window.close()
            window.contentView = nil
        }
        func titles() -> [String] {
            // SwiftUI's debug storage keeps format keys. Its SDK resolver expands the actual rendered Text.
            RenderedViewTestSupport.values(in: host).compactMap { $0 as? Text }
                .map { $0._resolveText(in: environment) }.filter { $0.hasPrefix("Found ") }
        }
        await TestWait.until(timeout: .seconds(TestWait.firstRenderTimeoutSeconds),
                             failureMessage: "\(picker) must render its found-count title") {
            !titles().isEmpty
        }
        XCTAssertEqual(titles(), [expected], picker)
    }

    func testPlatformDisplayNameTitlesFolder() {
        let view = ImportResultsView(
            importVM: ImportViewModel(
                scanner: EmptyImportScanner(),
                skillStore: SkillStore(fileService: FileService(), baseDir: TestPaths.skillsDir, storeRoot: TestPaths.storeRoot),
                lockPath: TestTemporaryDirectory.path + "import-lock-" + UUID().uuidString,
            manifestRoot: TestPaths.storeRoot
            ),
            onImport: {}
        )

        XCTAssertEqual(view.platformDisplayName("grok"), "Grok")
        XCTAssertEqual(view.platformDisplayName("claude-code"), "Claude Code")
        XCTAssertEqual(view.platformDisplayName("cursor"), "Cursor")
        XCTAssertEqual(view.platformDisplayName("codex"), "Codex")
        XCTAssertEqual(view.platformDisplayName("folder"), "Folder")
        XCTAssertEqual(view.platformDisplayName("future-platform"), "future-platform")
    }
}

private struct EmptyImportScanner: ImportScannerProtocol {
    func scan() -> [DiscoveredSkill] { [] }
    func scanFolder(_ path: String) -> [DiscoveredSkill] { [] }
    func isInsideStore(_ path: String) -> Bool { false }
}
