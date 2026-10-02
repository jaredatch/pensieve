import Foundation
import XCTest

extension XCTestCase {
    /// The suite name for a `UserDefaults` private to this test: the test's own name plus an optional
    /// label, never a UUID. macOS keeps an empty plist in the real `~/Library/Preferences` for every suite
    /// ever created, even after `removePersistentDomain`; UUID names had left 13,344 of them by 2026-09-10.
    /// Two suites live in one test only when their labels differ.
    func isolatedDefaultsSuite(_ label: String = "") -> String {
        let testName = name.filter { $0.isLetter || $0.isNumber || $0 == "_" }
        return "PensieveTests." + testName + (label.isEmpty ? "" : "." + label)
    }

    /// A `UserDefaults` suite private to this test, emptied now and again at teardown.
    func isolatedDefaults(_ label: String = "") throws -> UserDefaults {
        let suite = isolatedDefaultsSuite(label)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
}
