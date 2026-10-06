import AppKit
import XCTest
@testable import Pensieve

extension UpdatesSheetTests {
    func testSheetHostCleanupDismissesBindingAndClosesOnceBeforeFixtureCleanup() async throws {
        let fixture = try UpdateReviewFixture()
        defer { try? fixture.cleanup() }
        let skill = try fixture.skill("cleanup")
        let row = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: false)
        let model = fixture.sheet(rows: [row])
        model.present(library: fixture.library)
        await model.loadAndReport(context: fixture.context)
        let main = try await hostSheet(model, fixture: fixture)
        _ = try await attachedSheet(to: main, model: model)
        let closes = UpdateReviewRecorder<Bool>()
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                              object: main, queue: .main) { _ in closes.append(true) }
        defer { NotificationCenter.default.removeObserver(observer) }
        await Self.closeSheetHost(main, model: model)
        await Self.closeSheetHost(main, model: model)
        XCTAssertFalse(model.isPresented, "Cleanup must dismiss through the model's sheet binding")
        XCTAssertNil(main.attachedSheet, "The sheet must detach before its views and fixture are cleared")
        XCTAssertNil(main.contentView)
        XCTAssertEqual(closes.values.count, 1, "Repeated teardown must close the host exactly once")
    }
}
