import Foundation
import XCTest
@testable import Pensieve

final class ScenarioRemovalTests: XCTestCase {
    func testRetiredFeatureHasNoAppSourceOrNavigationEntry() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let sourceRoot = root.appendingPathComponent("Pensieve")
        let files = try XCTUnwrap(FileManager.default.enumerator(
            at: sourceRoot, includingPropertiesForKeys: nil
        ))
        let retired = try NSRegularExpression(
            pattern: #"\b(?:ScenarioStore(?:Protocol)?|ScenarioReconciler(?:Protocol)?|"#
                + #"ScenarioDetailView|ScenarioDetailModel|ScenarioListView|ScenarioRecord)\b"#
        )
        var scanned = 0
        for case let path as URL in files where path.pathExtension == "swift" {
            let source = try String(contentsOf: path, encoding: .utf8)
            XCTAssertNil(retired.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)), path.path)
            scanned += 1
        }
        XCTAssertGreaterThan(scanned, 100)
        XCTAssertEqual(SidebarSection.allCases, [.skills, .projects, .categories, .tags, .machines])
        XCTAssertNil(SidebarSection(rawValue: "scenarios"))
        XCTAssertNil(AddSheet(rawValue: "scenario"))
        XCTAssertNotNil(AddSheet(rawValue: "project"))
        XCTAssertNotNil(AddSheet(rawValue: "category"))
        let content = try String(contentsOf: sourceRoot.appendingPathComponent("Views/MainWindow/ContentView.swift"))
        XCTAssertTrue(content.contains("@State private var section: SidebarSection = .skills"))
    }
}
