import Foundation
import Observation

@MainActor
@Observable
final class InstalledSkillHistorySession {
    var showAllReadRows = false
    var requestedWindow = 1
    private(set) var mountedSkillID: UUID?

    func prepare(for skillID: UUID) -> Int {
        if mountedSkillID != skillID { reset(for: skillID) }
        return requestedWindow
    }

    func reset(for skillID: UUID) {
        mountedSkillID = skillID
        showAllReadRows = false
        requestedWindow = 1
    }

    func showOlder(
        _ action: InstalledSkillHistoryPresentation.OlderAction,
        currentWindow: Int
    ) {
        switch action {
        case .revealReadRows:
            showAllReadRows = true
        case .readNextWindow:
            let (next, overflow) = currentWindow.addingReportingOverflow(1)
            if !overflow { requestedWindow = next }
        }
    }
}
