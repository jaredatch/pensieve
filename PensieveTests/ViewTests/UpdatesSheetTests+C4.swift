import Foundation
import XCTest
@testable import Pensieve

extension UpdatesSheetTests {
    /// The Planner forbids native-view hooks here; this guards that framework boundary, not private logic.
    func testSheetUsesNativeControlsOneSwiftUIMeasurementAndNoDeadModelAPI() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().path
        let files = FileService()
        let directory = root + "/Pensieve/Views/InstallViews"
        let paths = try files.listDirectory(at: directory).filter { $0.hasPrefix("Updates") && $0.hasSuffix(".swift") }
        let sources = try paths.map { try files.readFile(at: directory + "/" + $0) }.joined(separator: "\n")
        XCTAssertFalse(sources.contains("NSViewRepresentable"), "The sheet must use native SwiftUI controls and geometry")
        XCTAssertFalse(sources.contains("ViewThatFits"), "Build and measure one row stack")
        XCTAssertFalse(sources.contains("updatesChromeHeight"), "No token sum sizes the scrolling region")
        XCTAssertTrue(sources.contains("sources: shown.selectionSources"), "Select-all uses the model's collection bindings")
        let row = try files.readFile(at: directory + "/UpdatesRowView.swift")
        let checkbox = row.components(separatedBy: "Toggle(")[1]
            .components(separatedBy: ".accessibilityIdentifier")[0]
        XCTAssertFalse(checkbox.contains("frame(width:"), "The native row checkbox keeps its intrinsic width")
        let model = try files.readFile(at: root + "/Pensieve/ViewModels/UpdatesViewModel.swift")
        XCTAssertFalse(model.contains("func toggleSelection("), "No test-only selection adapter")
        XCTAssertFalse(model.contains("var loadError:"), "Tests and production share loadPhase")
    }

    func testPresentationCostGrowsLinearlyWithSelectableRows() throws {
        let fixture = try UpdateReviewFixture()
        defer { try? fixture.cleanup() }
        let base = try UpdatesViewModel.makeRow(skill: fixture.skill("linear"), driftedLocally: false)
        let small = medianPresentationTime(base: base, count: 1_000)
        let large = medianPresentationTime(base: base, count: 8_000)
        XCTAssertLessThan(large, small * 24, "8× rows: small=\(small)s large=\(large)s; per-row scans grow quadratically")
    }

    private func medianPresentationTime(base: UpdatesRow, count: Int) -> TimeInterval {
        let rows = (0..<count).map { _ in
            UpdatesRow(id: UUID(), skillName: base.skillName, slug: base.slug, installedCommitDate: nil,
                       installedCommit: base.installedCommit, updateDate: base.updateDate,
                       upstreamCommit: base.upstreamCommit, upstreamTree: base.upstreamTree,
                       repositoryDisplay: base.repositoryDisplay, repositoryPath: base.repositoryPath,
                       driftedLocally: false, compareURL: nil)
        }
        let model = UpdatesViewModel(rowLoader: { _ in rows }, applyOperation: { _, _, _, _, _, _ in
            throw SkillUpdateFlowError.skillNotFound
        }, recheckOperation: { _, _ in throw SkillUpdateFlowError.skillNotFound })
        model.rows = rows
        model.loadPhase = .loaded
        model.selectAll()
        return (0..<5).map { _ in
            let start = ProcessInfo.processInfo.systemUptime
            let shown = UpdatesSheetPresentation(model)
            XCTAssertEqual(shown.selectionLabel, "\(count) of \(count) selected")
            return ProcessInfo.processInfo.systemUptime - start
        }.sorted()[2]
    }
}
