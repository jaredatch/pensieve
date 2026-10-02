import Foundation
@testable import Pensieve

/// Retains one runtime across configuration changes. Its orchestration paths are temporary.
/// The inert probe and the supplied model's git double both use the production refresh path.
@MainActor
final class RuntimeConfigurationFixture {
    private let fixture: GitFailureFixture
    let defaults: UserDefaults
    let runtime: AppRuntime
    let probe = RuleProbe()

    init(_ model: SyncModel, defaults: UserDefaults) throws {
        fixture = try GitFailureFixture()
        self.defaults = defaults
        runtime = try AppRuntime(
            syncModel: model,
            scheduler: SyncScheduler(startAutomatically: false, backgroundSyncEnabled: { false }),
            defaults: defaults, paths: fixture.paths, gitUsabilityProbe: probe.run
        )
    }

    func refresh() async {
        await runtime.bootstrapTask.value
        await runtime.refreshGitConfiguration(probingGit: false)
    }

    func remove() throws { try fixture.remove() }
}
