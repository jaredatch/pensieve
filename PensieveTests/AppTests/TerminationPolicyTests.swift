import AppKit
import XCTest
@testable import Pensieve

@MainActor
final class TerminationPolicyTests: XCTestCase {
    func testACleanLibraryQuitsAtOnce() {
        var confirmCalls = 0
        var replies: [Bool] = []

        let reply = PensieveAppDelegate.terminationReply(
            hasUnsavedChanges: false, questionOpen: false,
            confirm: { _ in confirmCalls += 1 },
            reply: { replies.append($0) }
        )

        XCTAssertEqual(reply, .terminateNow)
        XCTAssertEqual(confirmCalls, 0)
        XCTAssertTrue(replies.isEmpty)
    }

    /// The question is raised only after the delegate has returned `.terminateLater`: AppKit's contract is that
    /// the reply follows that return, and a presenter that answers at once (the default one, a refused second
    /// question) would otherwise reply from inside the delegate.
    func testUnsavedChangesHoldTheQuitAndAskAfterReturning() {
        var continuation: ((Bool) -> Void)?
        var replies: [Bool] = []
        let asked = expectation(description: "asked")

        let reply = PensieveAppDelegate.terminationReply(
            hasUnsavedChanges: true, questionOpen: false,
            confirm: { continuation = $0; asked.fulfill() },
            reply: { replies.append($0) }
        )

        XCTAssertEqual(reply, .terminateLater)
        XCTAssertNil(continuation)                        // not yet: the delegate has to return first
        wait(for: [asked], timeout: 2)
        XCTAssertTrue(replies.isEmpty)
        continuation?(true)
        XCTAssertEqual(replies, [true])

        var second: ((Bool) -> Void)?
        let askedAgain = expectation(description: "asked again")
        _ = PensieveAppDelegate.terminationReply(
            hasUnsavedChanges: true, questionOpen: false,
            confirm: { second = $0; askedAgain.fulfill() },
            reply: { replies.append($0) }
        )
        wait(for: [askedAgain], timeout: 2)
        second?(false)
        XCTAssertEqual(replies, [true, false])
    }

    /// The question's draft can read clean by the time the quit arrives (its file caught up while the sheet
    /// was up); the open question still refuses the quit — a policy that checked cleanliness first let it
    /// through (round 6).
    func testAnOpenQuestionOverACleanDraftStillRefusesTheQuit() {
        var confirmCalls = 0
        var replies: [Bool] = []

        let reply = PensieveAppDelegate.terminationReply(
            hasUnsavedChanges: false, questionOpen: true,
            confirm: { _ in confirmCalls += 1 },
            reply: { replies.append($0) }
        )

        XCTAssertEqual(reply, .terminateCancel)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(confirmCalls, 0)
        XCTAssertTrue(replies.isEmpty)
    }

    func testAQuestionAlreadyOpenRefusesTheQuitAtOnce() {
        var confirmCalls = 0
        var replies: [Bool] = []

        let reply = PensieveAppDelegate.terminationReply(
            hasUnsavedChanges: true, questionOpen: true,
            confirm: { _ in confirmCalls += 1 },
            reply: { replies.append($0) }
        )

        XCTAssertEqual(reply, .terminateCancel)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(confirmCalls, 0)
        XCTAssertTrue(replies.isEmpty)
    }
}
