import XCTest
@testable import Pensieve

extension UpdatesViewModelTests {
    func testCancelledFirstLoadDropsLateRowsAndNextPresentationUsesItsSelection() async throws {
        let fixture = try UpdateReviewFixture()
        defer { try? fixture.cleanup() }
        let first = try fixture.skill("cancel-reload-first")
        let second = try fixture.skill("cancel-reload-second")
        let rows = try [first, second].map { try UpdatesViewModel.makeRow(skill: $0, driftedLocally: false) }
        let calls = UpdateReviewRecorder<Bool>()
        let started = DispatchSemaphore(value: 0)
        let release = TestWait.Gate(owner: self)
        let sheet = UpdatesViewModel(rowLoader: { _ in
            calls.append(true)
            if calls.values.count == 1 {
                started.signal()
                try release.wait()
                return Array(rows.reversed())
            }
            return rows
        }, applyOperation: { _, _, _, _, _, _ in throw SkillUpdateFlowError.repositoryChanged },
        recheckOperation: { _, _ in throw SkillUpdateFlowError.skillNotFound })
        sheet.present(selecting: first.id, library: fixture.library)
        sheet.load(context: fixture.context)
        let load = try XCTUnwrap(sheet.operationTask)
        let didStart = await TestWait.forSemaphore(started)
        XCTAssertTrue(didStart)
        XCTAssertTrue(sheet.isLoading)
        sheet.cancel() // Cancel a first load, never an apply.
        XCTAssertTrue(sheet.rows.isEmpty, "A cancelled first load cannot expose rows")
        XCTAssertFalse(sheet.isLoading)
        XCTAssertEqual(sheet.loadPhase, .idle)
        release.open()
        await TestWait.forTask(load, failureMessage: "Cancelled first loader must finish before the test returns")
        XCTAssertTrue(sheet.rows.isEmpty, "The cancelled loader's rows must not land")
        XCTAssertTrue(sheet.selectedSkillIDs.isEmpty)
        sheet.reset()
        sheet.present(selecting: second.id, library: fixture.library)
        await sheet.loadAndReport(context: fixture.context)
        XCTAssertEqual(sheet.rows, rows)
        XCTAssertEqual(sheet.selectedSkillIDs, [second.id])
        XCTAssertEqual(calls.values.count, 2)
    }
}
