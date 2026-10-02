import ServiceManagement
import XCTest
@testable import Pensieve

@MainActor
final class LoginItemModelTests: XCTestCase {
    private final class StubService: LoginItemServiceProtocol {
        var status: SMAppService.Status
        private(set) var registerCount = 0
        private(set) var unregisterCount = 0

        init(status: SMAppService.Status) {
            self.status = status
        }

        func register() throws {
            registerCount += 1
            status = .enabled
        }

        func unregister() throws {
            unregisterCount += 1
            status = .notRegistered
        }
    }

    func testEnableRegisters() {
        let service = StubService(status: .notRegistered)
        let model = LoginItemModel(service: service)

        model.setEnabled(true)

        XCTAssertEqual(service.registerCount, 1)
        XCTAssertEqual(service.unregisterCount, 0)
        XCTAssertTrue(model.isEnabled)
    }

    func testDisableUnregisters() {
        let service = StubService(status: .enabled)
        let model = LoginItemModel(service: service)

        model.setEnabled(false)

        XCTAssertEqual(service.registerCount, 0)
        XCTAssertEqual(service.unregisterCount, 1)
        XCTAssertFalse(model.isEnabled)
    }

    func testRequiresApprovalSurfaced() {
        let service = StubService(status: .requiresApproval)
        let model = LoginItemModel(service: service)

        XCTAssertTrue(model.requiresApproval)
        XCTAssertFalse(model.isEnabled)
    }
}
