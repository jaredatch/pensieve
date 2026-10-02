import SwiftUI

/// File › Check All Skills for Updates as a `View`, so its enabled state observes the runtime.
struct CheckAllSkillUpdatesCommand: View {
    let runtime: AppRuntime

    var body: some View {
        Button("Check All Skills for Updates") {
            runtime.checkForSkillUpdatesNow()
        }
        .disabled(runtime.updateCheckInFlight)
    }
}
