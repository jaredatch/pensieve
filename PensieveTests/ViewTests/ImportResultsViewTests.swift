import XCTest
@testable import Pensieve

final class ImportResultsViewTests: XCTestCase {
    func testPlatformDisplayNameTitlesFolder() {
        let view = ImportResultsView(
            importVM: ImportViewModel(
                scanner: EmptyImportScanner(),
                skillStore: SkillStore(fileService: FileService(), baseDir: TestPaths.skillsDir),
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
