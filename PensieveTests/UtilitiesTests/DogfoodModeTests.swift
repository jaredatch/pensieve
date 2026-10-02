import XCTest
@testable import Pensieve

final class DogfoodModeTests: XCTestCase {
    func testInactiveWhenVariableAbsent() {
        XCTAssertFalse(DogfoodMode.isActive(in: [:]))
    }

    func testActiveWhenVariableIsOne() {
        XCTAssertTrue(DogfoodMode.isActive(in: [DogfoodMode.environmentKey: "1"]))
    }

    func testInactiveForOtherValues() {
        XCTAssertFalse(DogfoodMode.isActive(in: [DogfoodMode.environmentKey: "0"]))
        XCTAssertFalse(DogfoodMode.isActive(in: [DogfoodMode.environmentKey: "true"]))
        XCTAssertFalse(DogfoodMode.isActive(in: [DogfoodMode.environmentKey: ""]))
    }
}
