import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Pensieve

extension ViewChangesSceneTests {
    func testRenderedSidebarSurvivesCloseRecheckAndSwitchToFewerFiles() async throws {
        let fixture = try UpdateReviewFixture()
        defer { try? fixture.cleanup() }
        let large = try fixture.skill("large-preview")
        let small = try fixture.skill("small-preview")
        let empty = try fixture.skill("empty-preview")
        let smallID = small.id
        let emptyID = empty.id
        let rows = try [large, small, empty].map { try UpdatesViewModel.makeRow(skill: $0, driftedLocally: false) }
        let previews = try [8, 2, 0].map { try sidebarPreview(fileCount: $0) }
        let model = ViewChangesViewModel(library: fixture.library, operations: fixture.operations(rows: rows, diff: { row, _ in
            if row.id == emptyID { return previews[2] }
            return row.id == smallID || row.upstreamTree == "smaller-tree" ? previews[1] : previews[0]
        }, recheck: { id, _ in
            SkillUpdateRecheckCompletion(row: nil, skillID: id, updateAvailable: true,
                lastCheckedAt: Date(), lastCheckedHead: nil, upstreamTree: "smaller-tree",
                upstreamCommit: String(repeating: "3", count: 40),
                upstreamCommitDate: Date(timeIntervalSince1970: 4 * 86_400), checkError: nil)
        }))
        let window = makeWindow(id: "sidebar-reload")
        let host = NSHostingView(rootView: ViewChangesView(model: model, library: fixture.library, onUpdate: {})
            .modelContainer(fixture.container))
        window.contentView = host
        window.orderFront(nil)
        defer { model.close(); window.contentView = nil; window.toolbar = nil; window.close() }

        for _ in 0..<6 {
            for transition in 0..<4 {
                large.updateAvailable = true
                large.upstreamTree = "new-tree"
                model.open(skillID: large.id, context: fixture.context)
                await assertSidebarRows(model, host: host, count: 8)
                model.selectFile(id: 7)
                await displaySidebar(host)
                XCTAssertEqual(model.selectedFile?.path, "file-7.txt")
                switch transition {
                case 0: model.close()
                case 1:
                    large.updateAvailable = false
                    model.validate(skills: [large], folderRevisions: [:], context: fixture.context)
                    await assertSidebarRows(model, host: host, count: 0, expectLoaded: false)
                    large.updateAvailable = true
                    model.recheck(context: fixture.context)
                default: model.open(skillID: transition == 2 ? small.id : empty.id, context: fixture.context)
                }
                XCTAssertTrue(model.files.isEmpty, "Retiring a preview clears the sidebar before the next result")
                await displaySidebar(host)
                await assertSidebarRows(model, host: host, count: transition == 1 || transition == 2 ? 2 : 0,
                                        expectLoaded: transition != 0)
            }
        }
    }

    private func sidebarPreview(fileCount: Int) throws -> PinnedSkillDiff {
        try PinnedSkillDiff.build(comparison: FileTreeComparison(changes: (0..<fileCount).map {
            FileTreeChange(path: "file-\($0).txt", kind: .modified, content: .text(old: "old\n", new: "new\n"))
        }, unreadFileCount: 0, bytesRead: fileCount * 8))
    }

    private func assertSidebarRows(_ model: ViewChangesViewModel, host: NSView, count: Int,
                                   expectLoaded: Bool = true) async {
        await TestWait.until(failureMessage: "The sidebar preview did not finish loading") { model.state != .loading }
        await displaySidebar(host)
        if expectLoaded {
            switch model.state {
            case .loaded: break
            default: XCTFail("The next sidebar preview must be loaded; state: \(model.state)")
            }
        }
        XCTAssertEqual(model.files.map(\.path), (0..<count).map { "file-\($0).txt" },
                       "After display the sidebar must present exactly the new preview's rows; state: \(model.state)")
        XCTAssertEqual(model.selectedFile?.path, count == 0 ? nil : "file-0.txt")
        XCTAssertEqual(model.selectedFileID, count == 0 ? nil : 0)
    }

    private func displaySidebar(_ host: NSView) async {
        for _ in 0..<3 {
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            host.display()
            await Task.yield()
        }
    }
}
