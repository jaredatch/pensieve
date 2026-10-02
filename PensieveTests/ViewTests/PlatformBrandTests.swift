import AppKit
import XCTest
@testable import Pensieve

/// The brand tiles (PLAN-34 / 34.1): every platform has one, and every vendored mark is in the app bundle.
final class PlatformBrandTests: XCTestCase {
    private var bundle: Bundle { Bundle(for: PlatformViewModel.self) }

    func testEveryPlatformHasATile() {
        for platform in PlatformTarget.allCases {
            _ = PlatformBrand.tile(for: platform)
        }
        XCTAssertEqual(PlatformBrand.tile(for: .claudeCode).mark, .asset("brand-claudecode"))
        XCTAssertEqual(PlatformBrand.tile(for: .hermes).mark, .symbol("scroll"))
    }

    func testEveryVendoredMarkIsInTheBundle() {
        for platform in PlatformTarget.allCases {
            guard case let .asset(name) = PlatformBrand.tile(for: platform).mark else { continue }
            XCTAssertNotNil(bundle.image(forResource: name), "\(name) is not in the asset catalog")
        }
    }

    func testTheGitBranchIconIsInTheBundle() {
        XCTAssertNotNil(bundle.image(forResource: "git-branch"))
    }
}
