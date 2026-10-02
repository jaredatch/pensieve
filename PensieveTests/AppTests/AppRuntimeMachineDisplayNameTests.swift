import Foundation
import XCTest
@testable import Pensieve

@MainActor
final class AppRuntimeMachineDisplayNameTests: XCTestCase {
    func testAbsentNameIsSeededFromHost() throws {
        let defaults = try isolatedDefaults()

        _ = try makeRuntime(defaults: defaults, hostName: "Studio Mac")

        XCTAssertEqual(defaults.string(forKey: MachineDisplayName.defaultsKey), "Studio Mac")
        XCTAssertEqual(MachineDisplayName.publishedFallback(hostName: "Studio Mac"), "Studio Mac")
    }

    func testTypedNameIsNotOverwritten() throws {
        let defaults = try isolatedDefaults()
        defaults.set("Writing Mac", forKey: MachineDisplayName.defaultsKey)

        _ = try makeRuntime(defaults: defaults, hostName: "Studio Mac")

        XCTAssertEqual(defaults.string(forKey: MachineDisplayName.defaultsKey), "Writing Mac")
    }

    func testClearedNameIsNotOverwritten() throws {
        let defaults = try isolatedDefaults()
        defaults.set("", forKey: MachineDisplayName.defaultsKey)

        _ = try makeRuntime(defaults: defaults, hostName: "Studio Mac")

        XCTAssertEqual(defaults.object(forKey: MachineDisplayName.defaultsKey) as? String, "")
    }

    func testUnavailableOrBlankHostNameStoresNothing() throws {
        for hostName: String? in [nil, "", " \t\n"] {
            let defaults = try isolatedDefaults()
            _ = try makeRuntime(defaults: defaults, hostName: hostName)
            XCTAssertNil(defaults.object(forKey: MachineDisplayName.defaultsKey))
            XCTAssertEqual(MachineDisplayName.publishedFallback(hostName: hostName), "Mac")
        }
    }

    func testSeedTrimsHostName() throws {
        let defaults = try isolatedDefaults()
        _ = try makeRuntime(defaults: defaults, hostName: " \tStudio\n ")
        XCTAssertEqual(defaults.string(forKey: MachineDisplayName.defaultsKey), "Studio")
    }

    func testStoredNameDoesNotAskForHostName() throws {
        let defaults = try isolatedDefaults()
        defaults.set("Writing Mac", forKey: MachineDisplayName.defaultsKey)
        var hostNameCalls = 0

        _ = try AppRuntime(
            defaults: defaults,
            hostName: {
                hostNameCalls += 1
                return "Studio Mac"
            },
            paths: AppRuntimePaths.temporary(named: "AppRuntimeMachineDisplayNameTests"),
            gitUsabilityProbe: { .usable }
        )

        XCTAssertEqual(hostNameCalls, 0)
    }

    private func makeRuntime(defaults: UserDefaults, hostName: String?) throws -> AppRuntime {
        try AppRuntime(
            defaults: defaults,
            hostName: { hostName },
            paths: AppRuntimePaths.temporary(named: "AppRuntimeMachineDisplayNameTests"),
            gitUsabilityProbe: { .usable }
        )
    }
}
