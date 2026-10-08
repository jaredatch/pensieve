import Foundation
import XCTest
@testable import Pensieve

/// XCTest runs cases serially within a host; parallel workers have separate registries.
/// Only folder-timeout tests use the app's budget, with teardown restoring the host budget
/// even after a failure. Raw probes, their priority and existing flights are unchanged.
enum ProjectDirectoryProbeDeadline {
    private static let installation: Void = {
        ProjectDirectoryProbes.shared.deadlineSeconds = 30
    }()

    static func install() {
        _ = installation
    }

    static func useAppDeadline(in test: XCTestCase) {
        let previous = ProjectDirectoryProbes.shared.deadlineSeconds
        ProjectDirectoryProbes.shared.deadlineSeconds = 2
        test.addTeardownBlock {
            ProjectDirectoryProbes.shared.deadlineSeconds = previous
        }
    }
}
