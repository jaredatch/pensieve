import XCTest
@testable import Pensieve

extension UpdatesViewModelTests {
    func testRetryAndCancelledLoadingNeverExposeThePreviousLoadError() async throws {
        let fixture = try UpdateReviewFixture()
        defer { try? fixture.cleanup() }
        let skill = try fixture.skill("coherent-load")
        let row = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: false)
        let calls = UpdateReviewRecorder<Bool>()
        let started = DispatchSemaphore(value: 0)
        let release = TestWait.Gate(owner: self)
        let sheet = UpdatesViewModel(rowLoader: { _ in
            calls.append(true)
            if calls.values.count == 1 { throw SkillUpdateFlowError.repositoryChanged }
            if calls.values.count == 2 { started.signal(); try release.wait() }
            return [row]
        }, applyOperation: { _, _, _, _, _, _ in throw SkillUpdateFlowError.repositoryChanged },
        recheckOperation: { _, _ in throw SkillUpdateFlowError.skillNotFound })
        await sheet.loadAndReport(context: fixture.context)
        XCTAssertNotNil(sheet.loadError)
        sheet.load(context: fixture.context)
        let retry = try XCTUnwrap(sheet.operationTask)
        let didStart = await TestWait.forSemaphore(started)
        XCTAssertTrue(didStart)
        XCTAssertTrue(sheet.isLoading)
        XCTAssertNil(sheet.loadError, "Retry must expose loading alone, not the previous failed phase")
        sheet.cancel() // Cancel a load, not an apply.
        XCTAssertFalse(sheet.isLoading)
        XCTAssertNil(sheet.loadError, "Cancelling loading must return to idle, not revive the old error")
        release.open()
        await TestWait.forTask(retry, failureMessage: "Cancelled Retry must finish before a new load")
        await sheet.loadAndReport(context: fixture.context)
        XCTAssertFalse(sheet.isLoading)
        XCTAssertNil(sheet.loadError)
        XCTAssertEqual(sheet.rows.map(\.id), [skill.id])
        XCTAssertEqual(sheet.selectedSkillIDs, [skill.id])
    }
}
