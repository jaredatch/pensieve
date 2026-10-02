import Foundation
import XCTest

extension TestWait {
    enum GateFailure: Error { case timedOut, abandoned }

    /// A synchronous stub gate with counted releases and sticky failure evidence. Creation
    /// requires its owning test and registers an automatic teardown check. Each `open` grants
    /// one wait, even if consumed after cleanup. Cleanup abandons only uncovered waits, which
    /// throw instead of returning a canned result. Timeouts also throw and stay recorded even
    /// if production swallows the error. Recorded failures never revoke granted permits.
    /// Workers never report XCTest issues. Teardown asserts a release was granted and no
    /// failure was recorded. This gate does not join operations or undo permitted work.
    /// `abandon` can count only workers already inside `wait`. A worker arriving afterwards
    /// can be abandoned after the teardown check without reporting it. The owning test's
    /// own operation counts must catch a lost release in that case.
    final class Gate {
        private let condition = NSCondition()
        private var permits = 0
        private var openings = 0
        private var waiting = 0
        private var abandoned = false
        private var recordedFailure: GateFailure?

        init(owner: XCTestCase, file: StaticString = #filePath, line: UInt = #line) {
            owner.addTeardownBlock { await self.finish(file: file, line: line) }
        }

        var failure: GateFailure? {
            condition.lock()
            defer { condition.unlock() }
            return recordedFailure
        }

        var waiterCount: Int {
            condition.lock()
            defer { condition.unlock() }
            return waiting
        }

        func open() {
            condition.lock()
            defer { condition.unlock() }
            permits += 1
            condition.signal()
        }

        func wait(timeout: Duration = .seconds(TestWait.timeoutSeconds)) throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            condition.lock()
            waiting += 1
            defer { waiting -= 1; condition.unlock() }
            while permits == 0 && !abandoned {
                let remaining = clock.now.duration(to: deadline)
                if remaining <= .zero {
                    recordedFailure = recordedFailure ?? .timedOut
                    TestTimeoutDiagnostics.note(
                        "TestWait.Gate: waiting=\(waiting); permits=\(permits); " +
                            "openings=\(openings); abandoned=\(abandoned)"
                    )
                    throw GateFailure.timedOut
                }
                let parts = remaining.components
                let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
                _ = condition.wait(until: Date().addingTimeInterval(seconds))
            }
            guard permits > 0 else {
                recordedFailure = recordedFailure ?? .abandoned
                throw GateFailure.abandoned
            }
            permits -= 1
            openings += 1
        }

        func abandon() {
            condition.lock()
            defer { condition.unlock() }
            abandoned = true
            if waiting > permits || openings + permits == 0 {
                recordedFailure = recordedFailure ?? .abandoned
            }
            condition.broadcast()
        }

        @MainActor
        func finish(file: StaticString = #filePath, line: UInt = #line) {
            abandon()
            condition.lock()
            let succeeded = openings + permits > 0 && recordedFailure == nil
            let detail = recordedFailure.map { String(describing: $0) } ?? "not opened"
            condition.unlock()
            XCTAssertTrue(succeeded, "Gate did not open normally: \(detail)", file: file, line: line)
        }
    }
}
