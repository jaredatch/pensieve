import Foundation
import Observation

@MainActor
@Observable
final class CommandLineSettingsModel {
    private(set) var status: CommandLinkStatus = .absent
    private(set) var isWorking = false
    var error: String?
    private let installer: CommandLinkInstalling
    private var didRepairAtLaunch = false

    init(installer: CommandLinkInstalling) { self.installer = installer }

    func refresh() {
        do { status = try installer.status() } catch { self.error = error.localizedDescription }
    }

    func perform(_ action: CommandLinkAction) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false; refresh() }
        do {
            let installer = installer
            try await BlockingWork.run { try installer.perform(action) }
            error = nil
        } catch is AdminCommandLinkAuthorization.Cancelled {
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func repairAtLaunch() async {
        guard !didRepairAtLaunch else { return }
        didRepairAtLaunch = true
        let installer = installer
        // A failed unprivileged repair is reported by the broken status, with Repair offered.
        _ = try? await BlockingWork.run { try installer.repairAtLaunch() }
        refresh()
    }
}
