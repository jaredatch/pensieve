import XCTest
@testable import Pensieve

final class AppSignalTests: XCTestCase {
    func testSignalLaunchEmitsLaunchedSignal() {
        var receivedSignals: [String] = []
        let signaler = LaunchSignaler { signal in
            receivedSignals.append(signal)
        }

        signaler.signalLaunch()

        XCTAssertEqual(receivedSignals, [AppSignal.launched])
    }
}
