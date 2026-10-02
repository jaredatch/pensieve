import Sparkle
import XCTest
@testable import Pensieve

final class UpdateChannelPolicyTests: XCTestCase {
    func testDefaultExcludesBetaChannel() {
        XCTAssertTrue(UpdateChannelPolicy.allowedChannels(betaOptIn: false).isEmpty)
    }

    func testOptInIncludesExactlyBetaChannel() {
        XCTAssertEqual(UpdateChannelPolicy.allowedChannels(betaOptIn: true), ["beta"])
    }

    // Exercises the REAL Sparkle callback (allowedChannels(for:)), not a
    // convenience wrapper — a delegate whose Sparkle entry point drifted from
    // the policy must fail here. The SPUUpdater is never started, so no
    // network/appcast activity occurs.
    func testUpdaterDelegateSparkleCallbackConsultsPolicy() throws {
        let defaults = try isolatedDefaults()

        let delegate = UpdaterDelegate(defaults: defaults)
        let driver = SPUStandardUserDriver(hostBundle: .main, delegate: nil)
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: delegate)

        XCTAssertEqual(delegate.allowedChannels(for: updater), [])

        defaults.set(true, forKey: UpdateChannelPolicy.betaUpdatesEnabledKey)
        XCTAssertEqual(delegate.allowedChannels(for: updater), ["beta"])
    }
}
