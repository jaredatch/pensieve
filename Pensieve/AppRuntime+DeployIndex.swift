import Foundation

extension AppRuntime {
    /// Wraps the injected launch backfill so every backfill site — launch, the deferred run after the
    /// first synced cycle, and conflict resolution — refreshes the deploy index once the ledger has been
    /// rewritten (PLAN-29). The backfill rewrites only the ledger, never an artifact, so the detail's
    /// refresh counter stays put; a convergence pass, which can prune links and recompile Cursor rules,
    /// announces itself through `PlatformViewModel.noteDeployStateChanged()` instead. Lives in its own
    /// file because `AppRuntime.init` sits at SwiftLint's 50-line `function_body_length` limit.
    static func backfillRefreshingIndex(_ backfill: @escaping LaunchBackfill,
                                        platformVM: PlatformViewModel) -> LaunchBackfill {
        { context in
            backfill(context)
            platformVM.refreshDeployIndex()
        }
    }
}
