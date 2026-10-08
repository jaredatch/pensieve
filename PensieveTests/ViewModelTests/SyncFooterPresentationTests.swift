import XCTest
@testable import Pensieve

@MainActor
final class SyncFooterPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testUnconfiguredHasNoPresentation() {
        XCTAssertNil(make(.unconfigured))
    }

    func testSyncingShowsDisabledSpinnerLine() throws {
        let line = try XCTUnwrap(make(.syncing))

        XCTAssertTrue(line.showsSpinner)
        XCTAssertEqual(line.label, "Syncing…")
        XCTAssertEqual(line.action, .none)
    }

    func testIdleAtRestOffersSyncWithoutEmphasis() throws {
        let line = try XCTUnwrap(make(.idle))

        XCTAssertEqual(line.symbol, "arrow.triangle.2.circlepath")
        XCTAssertEqual(line.label, "Sync now")
        XCTAssertFalse(line.emphasized)
        XCTAssertEqual(line.action, .sync)
    }

    func testIdleHoveringIsEmphasized() throws {
        XCTAssertTrue(try XCTUnwrap(make(.idle, hovering: true)).emphasized)
    }

    func testSyncedAtRestShowsCompactTime() throws {
        let line = try XCTUnwrap(make(.synced(at: now.addingTimeInterval(-12 * 60))))

        XCTAssertEqual(line.symbol, "checkmark.circle")
        XCTAssertEqual(line.label, "12m ago")
        XCTAssertFalse(line.emphasized)
        XCTAssertEqual(line.action, .sync)
    }

    func testSyncedHoveringOffersEmphasizedSync() throws {
        let line = try XCTUnwrap(make(.synced(at: now.addingTimeInterval(-12 * 60)), hovering: true))

        XCTAssertEqual(line.symbol, "arrow.triangle.2.circlepath")
        XCTAssertEqual(line.label, "Sync now")
        XCTAssertTrue(line.emphasized)
    }

    func testErrorAtRestShowsFailureAndHelp() throws {
        let line = try XCTUnwrap(make(.error("boom")))

        XCTAssertEqual(line.symbol, "exclamationmark.triangle")
        XCTAssertEqual(line.label, "Sync failed")
        XCTAssertTrue(line.emphasized)
        XCTAssertEqual(line.help, "boom")
    }

    func testErrorHoveringOffersSyncAndKeepsHelp() throws {
        let line = try XCTUnwrap(make(.error("boom"), hovering: true))

        XCTAssertEqual(line.label, "Sync now")
        XCTAssertEqual(line.help, "boom")
    }

    func testSingleConflictAtRestOffersResolve() throws {
        let line = try XCTUnwrap(make(.conflicted(["a"])))

        XCTAssertEqual(line.label, "1 conflict")
        XCTAssertEqual(line.action, .resolve)
    }

    func testMultipleConflictsHoveringShowsResolveAction() throws {
        let line = try XCTUnwrap(make(.conflicted(["a", "b"]), hovering: true))

        XCTAssertEqual(line.label, "Resolve…")
        XCTAssertEqual(line.action, .resolve)
    }

    private func make(
        _ state: SyncModel.SyncState,
        hovering: Bool = false
    ) -> SyncFooterPresentation? {
        SyncFooterPresentation.make(state: state, canResolve: SyncModel(git: TestPaths.git, root: TestPaths.storeRoot,
            initialState: state).canResolve,
                                    hovering: hovering, now: now)
    }
}
