import Foundation
import ServiceManagement

protocol LoginItemServiceProtocol {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemServiceProtocol {}

@MainActor
@Observable
final class LoginItemModel {
    private let service: LoginItemServiceProtocol
    private(set) var status: SMAppService.Status
    var errorMessage: String?

    var isEnabled: Bool { status == .enabled }
    var requiresApproval: Bool { status == .requiresApproval }

    init(service: LoginItemServiceProtocol = SMAppService.mainApp) {
        self.service = service
        self.status = service.status
    }

    func refresh() {
        status = service.status
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
        refresh()
    }
}
