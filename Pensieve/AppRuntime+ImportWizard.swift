import Foundation

extension AppRuntime {
    /// The first-launch wizard opens only over an empty library the app can trust: not quarantined (a
    /// half-cloned store, PLAN-24) and not unreadable (a newer or corrupt manifest).
    static func shouldAutoShowImportWizard(skillCount: Int, storeQuarantined: Bool, storeUnreadable: Bool) -> Bool {
        skillCount == 0 && !storeQuarantined && !storeUnreadable
    }

    /// The pure rule over this runtime's own state; `ContentView.onAppear` reads this form.
    func shouldAutoShowImportWizard(skillCount: Int) -> Bool {
        Self.shouldAutoShowImportWizard(
            skillCount: skillCount, storeQuarantined: storeQuarantined, storeUnreadable: library.storeUnreadable
        )
    }
}
