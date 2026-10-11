import AppKit
import XCTest
@testable import Pensieve

/// Checks windows created during a case after its body and cleanup blocks release their owners.
/// Release hosted windows in the body or a teardown block; this check runs before tearDown().
/// A retained shell passes only when hidden, transitions-off and contentless. Closed windows
/// keeping content or default transitions still fail. Pre-existing and private-framework helper
/// windows are excluded; the observer never closes windows or changes their animation policy.
/// Cases are serial within one host; parallel XCTest workers have separate inventories.
final class TestWindowLifetime: NSObject, XCTestObservation {
    private static let shared = TestWindowLifetime()
    private(set) static var registrationCount = 0
    private var casesFinished = 0
    private var completedClasses = Set<String>()

    static func install() {
        guard registrationCount == 0 else { return }
        registrationCount += 1
        XCTestObservationCenter.shared.addTestObserver(shared)
    }

    func testCaseWillStart(_ testCase: XCTestCase) {
        let baseline = onMain { MainActor.assumeIsolated { WindowInventory() } }
        // Registered before the body, so the case's own teardown blocks run first (LIFO).
        // XCTest cannot record an issue from testCaseDidFinish: its run has already stopped.
        testCase.addTeardownBlock { @MainActor in
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while baseline.remaining().isEmpty == false && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            for window in baseline.remaining() {
                testCase.record(XCTIssue(type: .assertionFailure, compactDescription:
                    "\(testCase.name) left a test window alive: title=\(window.title), " +
                    "class=\(type(of: window)), visible=\(window.isVisible), " +
                    "animation=\(window.animationBehavior.rawValue), frame=\(window.frame), " +
                    "content=\(String(describing: window.contentView)), " +
                    "bundle=\(Bundle(for: type(of: window)).bundlePath); release hosted windows in the test body " +
                    "or a teardown block, not tearDown()."))
            }
        }
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        casesFinished += 1
        completedClasses.insert(String(describing: type(of: testCase)))
    }

    /// Opt-in end-of-host evidence for a full-suite run. Sampling never records an XCTest issue
    /// after the run stopped; the caller checks the saved reports, including successful sampling.
    func testBundleDidFinish(_ testBundle: Bundle) {
        guard casesFinished > 0,
              let directory = ProcessInfo.processInfo.environment["PENSIEVE_TEST_WINDOW_SAMPLE_DIR"] else { return }
        let sample = TestThreadSample.capture()
        do {
            let files = FileService()
            try files.createDirectory(at: directory)
            let classes = completedClasses.sorted().joined(separator: ",")
            try files.writeFile(at: directory + "/\(ProcessInfo.processInfo.processIdentifier).txt",
                content: "completed cases=\(casesFinished)\nclasses=\(classes)\n" + sample)
        } catch {
            TestTimeoutDiagnostics.writeToStandardError("Window lifetime sample could not be saved: \(error)")
        }
    }

    @MainActor
    private final class WindowInventory {
        private let baseline = NSHashTable<NSWindow>.weakObjects()

        init() { NSApp.windows.forEach(baseline.add) }

        func remaining() -> [NSWindow] {
            NSApp.windows.filter {
                !baseline.contains($0) && !Self.isPrivateFrameworkWindow($0)
                    && ($0.isVisible || $0.animationBehavior != .none || $0.contentView != nil)
            }
        }

        private static func isPrivateFrameworkWindow(_ window: NSWindow) -> Bool {
            // Private macOS frameworks create and retain hidden text-field helpers: TUINSWindow
            // (TextInputUIMacHelper) and SPRoundedWindow (SafariPlatformSupport) were observed.
            // A test cannot host a class defined there. Public AppKit/SwiftUI, app and test
            // classes still count, including closed windows retaining content or transitions.
            Bundle(for: type(of: window)).bundlePath.hasPrefix("/System/Library/PrivateFrameworks/")
        }
    }

    private func onMain<T>(_ body: () -> T) -> T {
        if Thread.isMainThread { body() } else { DispatchQueue.main.sync(execute: body) }
    }
}
