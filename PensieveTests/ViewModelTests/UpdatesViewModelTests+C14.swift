import XCTest
@testable import Pensieve

extension UpdatesViewModelTests {
    func testCancelledReloadKeepsRowsLoadedAndAcceptsHandoff() async throws {
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
            if calls.values.count == 2 { started.signal(); try release.wait() }
            return rows
        }, applyOperation: { _, _, _, _, _, _ in throw SkillUpdateFlowError.repositoryChanged },
        recheckOperation: { _, _ in throw SkillUpdateFlowError.skillNotFound })
        sheet.present(selecting: first.id, library: fixture.library)
        await sheet.loadAndReport(context: fixture.context)
        sheet.load(context: fixture.context)
        let didStart = await TestWait.forSemaphore(started)
        XCTAssertTrue(didStart)
        XCTAssertTrue(sheet.isLoading)
        sheet.cancel() // Cancel only the reload; apply cancellation is outside this stage.
        XCTAssertEqual(sheet.rows, rows, "Cancelling reload must keep the rows already on screen")
        XCTAssertFalse(sheet.isLoading)
        XCTAssertNil(sheet.loadError)
        sheet.present(selecting: second.id, library: fixture.library)
        XCTAssertEqual(sheet.selectedSkillIDs, [first.id, second.id],
                       "After cancelling reload, a hand-off must select its shown row immediately")
        release.open()
    }
}
