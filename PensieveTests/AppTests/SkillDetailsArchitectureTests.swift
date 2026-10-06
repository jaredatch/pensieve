import XCTest
@testable import Pensieve

/// The review explicitly requires one owner for these two rules. Behavioral tests cannot detect
/// identical copies; these guards count owners while the hosted and navigation tests check behavior.
final class SkillDetailsArchitectureTests: XCTestCase {
    func testTimelineVerticalSizingHasOneOwner() throws {
        let sources = try readSources([
            "Views/SkillViews/Detail/SkillHistoryTab.swift",
            "Views/SkillViews/Detail/InstalledSkillHistoryView.swift",
            "Views/SkillViews/Detail/SkillHistoryTimelineRow.swift"
        ])
        let owners = sources.filter { $0.contains(".fixedSize(horizontal: false, vertical: true)") }.count
        XCTAssertEqual(owners, 1, "Authored and installed timelines must share their vertical sizing owner")
    }

    func testWebSchemeAllowlistHasOneOwner() throws {
        let sources = try readSources([
            "Views/SkillViews/Editor/EditorNavigationPolicy.swift",
            "Views/SkillViews/SkillPreviewLinkPolicy.swift",
            "Utilities/WebLinkPolicy.swift"
        ])
        let owners = sources.filter { $0.contains("\"http\"") && $0.contains("\"https\"") }.count
        XCTAssertEqual(owners, 1, "Editor and rendered preview must share the web-scheme allowlist")
    }

    private func readSources(_ paths: [String]) throws -> [String] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Pensieve")
        let files = FileService()
        return try paths.compactMap { path in
            let absolute = root.appendingPathComponent(path).path
            return files.fileExists(at: absolute) ? try files.readFile(at: absolute) : nil
        }
    }
}
