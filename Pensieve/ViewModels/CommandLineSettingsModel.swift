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
    private var generation = 0
    private var locationError = false

    init(installer: CommandLinkInstalling) { self.installer = installer }

    func refresh() async {
        guard !isWorking else { return }
        generation += 1
        let ticket = generation
        let installer = installer
        do {
            let result = try await BlockingWork.run { () -> (CommandLinkStatus, Bool) in
                let status = try installer.status()
                do {
                    try installer.checkAppLocation()
                    return (status, false)
                } catch CommandLinkLocationError.temporaryLocation { return (status, true) }
            }
            guard ticket == generation else { return }
            if locationError ? !result.1 : status != result.0 { error = nil; locationError = false }
            status = result.0
        } catch {
            guard ticket == generation else { return }
            if !locationError { self.error = error.localizedDescription }
        }
    }

    func perform(_ action: CommandLinkAction) async {
        guard !isWorking else { return }
        generation += 1
        isWorking = true
        error = nil
        locationError = false
        defer { isWorking = false }
        let installer = installer
        do {
            try await BlockingWork.run { try installer.perform(action) }
        } catch is AdminCommandLinkAuthorization.Cancelled {
            // Cancellation leaves the current status.
        } catch { setError(error) }
        do { status = try await BlockingWork.run { try installer.status() } } catch { if self.error == nil { setError(error) } }
    }

    func repairAtLaunch() async {
        guard !didRepairAtLaunch, !isWorking else { return }
        didRepairAtLaunch = true
        isWorking = true
        defer { isWorking = false }
        generation += 1
        let ticket = generation
        let installer = installer
        do { try await BlockingWork.run { try installer.repairAtLaunch() } } catch CommandLinkLocationError.temporaryLocation {
            guard ticket == generation else { return }
            setError(CommandLinkLocationError.temporaryLocation)
        } catch { /* A failed unprivileged repair is reported by broken status. */ }
        guard ticket == generation else { return }
        do { status = try await BlockingWork.run { try installer.status() } } catch { if self.error == nil { setError(error) } }
    }

    private func setError(_ error: Error) {
        self.error = error.localizedDescription
        locationError = error is CommandLinkLocationError
    }
}
