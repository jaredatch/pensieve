import Foundation
import os
import SwiftData

// MARK: - Protocol

/// Pure CRUD over synced `Scenario` definitions. Scenario deployment fan-out lands in Stage 17.3.
protocol ScenarioStoreProtocol {
    var notifier: SyncStateNotifying { get }
    func create(name: String, context: ModelContext, notifier: SyncStateNotifying) -> Scenario?
    func rename(_ scenario: Scenario, to name: String, context: ModelContext, notifier: SyncStateNotifying)
    func delete(_ scenario: Scenario, context: ModelContext, notifier: SyncStateNotifying)
    @discardableResult
    func delete(_ scenario: Scenario, reconciler: ScenarioReconcilerProtocol, context: ModelContext,
                notifier: SyncStateNotifying) -> BatchResult
    func setSkill(_ skill: Skill, inScenario scenario: Scenario, assigned: Bool, context: ModelContext,
                  notifier: SyncStateNotifying)
    @discardableResult
    func setSkill(_ skill: Skill, inScenario scenario: Scenario, assigned: Bool,
                  reconciler: ScenarioReconcilerProtocol, context: ModelContext,
                  notifier: SyncStateNotifying) -> BatchResult
    func setAgent(_ platform: PlatformTarget, inScenario scenario: Scenario, enabled: Bool, context: ModelContext,
                  notifier: SyncStateNotifying)
    @discardableResult
    func setAgent(_ platform: PlatformTarget, inScenario scenario: Scenario, enabled: Bool,
                  reconciler: ScenarioReconcilerProtocol, context: ModelContext,
                  notifier: SyncStateNotifying) -> BatchResult
    func scenarios(containingSkillSlug slug: String, context: ModelContext) -> [Scenario]
    @discardableResult
    func activate(_ scenario: Scenario, reconciler: ScenarioReconcilerProtocol, context: ModelContext) -> BatchResult
    @discardableResult
    func deactivate(reconciler: ScenarioReconcilerProtocol, context: ModelContext) -> BatchResult
    @discardableResult
    func reconcileAfterRemovingSkill(_ skill: Skill,
                                     reconciler: ScenarioReconcilerProtocol, context: ModelContext,
                                     notifier: SyncStateNotifying) -> BatchResult
    func activeScenarioID() -> UUID?
    func setActiveScenarioID(_ id: UUID?)
}

extension ScenarioStoreProtocol {
    var notifier: SyncStateNotifying { SyncStateNotifier.suppressed }
    func create(name: String, context: ModelContext) -> Scenario? {
        create(name: name, context: context, notifier: notifier)
    }
    func rename(_ scenario: Scenario, to name: String, context: ModelContext) {
        rename(scenario, to: name, context: context, notifier: notifier)
    }
    func delete(_ scenario: Scenario, context: ModelContext) {
        delete(scenario, context: context, notifier: notifier)
    }
    func delete(_ scenario: Scenario, reconciler: ScenarioReconcilerProtocol,
                context: ModelContext) -> BatchResult {
        delete(scenario, reconciler: reconciler, context: context, notifier: notifier)
    }
    func setSkill(_ skill: Skill, inScenario scenario: Scenario, assigned: Bool, context: ModelContext) {
        setSkill(skill, inScenario: scenario, assigned: assigned, context: context, notifier: notifier)
    }
    func setSkill(_ skill: Skill, inScenario scenario: Scenario, assigned: Bool,
                  reconciler: ScenarioReconcilerProtocol, context: ModelContext) -> BatchResult {
        setSkill(skill, inScenario: scenario, assigned: assigned, reconciler: reconciler,
                 context: context, notifier: notifier)
    }
    func setAgent(_ platform: PlatformTarget, inScenario scenario: Scenario, enabled: Bool,
                  context: ModelContext) {
        setAgent(platform, inScenario: scenario, enabled: enabled, context: context, notifier: notifier)
    }
    func setAgent(_ platform: PlatformTarget, inScenario scenario: Scenario, enabled: Bool,
                  reconciler: ScenarioReconcilerProtocol, context: ModelContext) -> BatchResult {
        setAgent(platform, inScenario: scenario, enabled: enabled, reconciler: reconciler,
                 context: context, notifier: notifier)
    }
    func reconcileAfterRemovingSkill(_ skill: Skill, reconciler: ScenarioReconcilerProtocol,
                                     context: ModelContext) -> BatchResult {
        reconcileAfterRemovingSkill(skill, reconciler: reconciler, context: context, notifier: notifier)
    }
}

// MARK: - Implementation

struct ScenarioStore: ScenarioStoreProtocol {
    private static let activeScenarioKey = "activeScenarioID"

    private let manifestService: ManifestSnapshotting?
    private let manifestRoot: String
    private let defaults: UserDefaults
    let notifier: SyncStateNotifying

    init(manifestService: ManifestSnapshotting? = nil,
         manifestRoot: String = Constants.pensieveBaseDir,
         defaults: UserDefaults = .standard,
         notifier: @escaping SyncStateNotifying = SyncStateNotifier.suppressed) {
        self.manifestService = manifestService
        self.manifestRoot = manifestRoot
        self.defaults = defaults
        self.notifier = notifier
    }

    func create(name: String, context: ModelContext, notifier: SyncStateNotifying) -> Scenario? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let scenario = Scenario(name: trimmed)
        context.insert(scenario)
        try? context.save()
        regenerateManifest(context: context)
        notifier()
        return scenario
    }

    func rename(_ scenario: Scenario, to name: String, context: ModelContext, notifier: SyncStateNotifying) {
        scenario.name = name
        try? context.save()
        regenerateManifest(context: context)
        notifier()
    }

    func delete(_ scenario: Scenario, context: ModelContext, notifier: SyncStateNotifying) {
        if activeScenarioID() == scenario.id {
            setActiveScenarioID(nil)
        }
        context.delete(scenario)
        try? context.save()
        regenerateManifest(context: context)
        notifier()
    }

    @discardableResult
    func delete(_ scenario: Scenario, reconciler: ScenarioReconcilerProtocol, context: ModelContext,
                notifier: SyncStateNotifying) -> BatchResult {
        delete(scenario, context: context, notifier: SyncStateNotifier.suppressed)
        let result = reconciler.reconcile(context: context)
        notifier()
        return result
    }

    func setSkill(_ skill: Skill, inScenario scenario: Scenario, assigned: Bool, context: ModelContext,
                  notifier: SyncStateNotifying) {
        let slug = skill.directoryName

        if assigned {
            if !scenario.skillSlugs.contains(slug) {
                scenario.skillSlugs.append(slug)
            }
        } else {
            scenario.skillSlugs.removeAll { $0 == slug }
        }
        try? context.save()
        regenerateManifest(context: context)
        notifier()
    }

    @discardableResult
    func setSkill(_ skill: Skill, inScenario scenario: Scenario, assigned: Bool,
                  reconciler: ScenarioReconcilerProtocol, context: ModelContext,
                  notifier: SyncStateNotifying) -> BatchResult {
        setSkill(skill, inScenario: scenario, assigned: assigned, context: context,
                 notifier: SyncStateNotifier.suppressed)
        let result = reconciler.reconcile(context: context)
        notifier()
        return result
    }

    func setAgent(_ platform: PlatformTarget, inScenario scenario: Scenario, enabled: Bool, context: ModelContext,
                  notifier: SyncStateNotifying) {
        var values = Set(scenario.agentRawValues)
        if enabled {
            values.insert(platform.rawValue)
        } else {
            values.remove(platform.rawValue)
        }
        let known = PlatformTarget.allCases.map(\.rawValue).filter { values.contains($0) }
        let unknown = values.subtracting(PlatformTarget.allCases.map(\.rawValue)).sorted()
        scenario.agentRawValues = known + unknown
        try? context.save()
        regenerateManifest(context: context)
        notifier()
    }

    @discardableResult
    func setAgent(_ platform: PlatformTarget, inScenario scenario: Scenario, enabled: Bool,
                  reconciler: ScenarioReconcilerProtocol, context: ModelContext,
                  notifier: SyncStateNotifying) -> BatchResult {
        setAgent(platform, inScenario: scenario, enabled: enabled, context: context,
                 notifier: SyncStateNotifier.suppressed)
        let result = reconciler.reconcile(context: context)
        notifier()
        return result
    }

    func scenarios(containingSkillSlug slug: String, context: ModelContext) -> [Scenario] {
        let scenarios = (try? context.fetch(FetchDescriptor<Scenario>())) ?? []
        return scenarios.filter { $0.skillSlugs.contains(slug) }
    }

    @discardableResult
    func activate(_ scenario: Scenario, reconciler: ScenarioReconcilerProtocol, context: ModelContext) -> BatchResult {
        setActiveScenarioID(scenario.id)
        return reconciler.reconcile(context: context)
    }

    @discardableResult
    func deactivate(reconciler: ScenarioReconcilerProtocol, context: ModelContext) -> BatchResult {
        setActiveScenarioID(nil)
        return reconciler.reconcile(context: context)
    }

    @discardableResult
    func reconcileAfterRemovingSkill(_ skill: Skill,
                                     reconciler: ScenarioReconcilerProtocol, context: ModelContext,
                                     notifier: SyncStateNotifying) -> BatchResult {
        for scenario in scenarios(containingSkillSlug: skill.directoryName, context: context) {
            setSkill(skill, inScenario: scenario, assigned: false, context: context,
                     notifier: SyncStateNotifier.suppressed)
        }
        let result = reconciler.reconcile(context: context)
        notifier()
        return result
    }

    func activeScenarioID() -> UUID? {
        guard let raw = defaults.string(forKey: Self.activeScenarioKey),
              !raw.isEmpty else { return nil }
        return UUID(uuidString: raw)
    }

    func setActiveScenarioID(_ id: UUID?) {
        if let id {
            defaults.set(id.uuidString, forKey: Self.activeScenarioKey)
        } else {
            defaults.removeObject(forKey: Self.activeScenarioKey)
        }
    }

    /// Best-effort manifest regeneration after a scenario mutation. No-op without a wired service
    /// (tests). A failure is logged (this struct has no error channel) — never a silent `try?`.
    private func regenerateManifest(context: ModelContext) {
        guard let manifestService else { return }
        do {
            try manifestService.write(manifestService.snapshot(from: context), toRoot: manifestRoot)
        } catch {
            Logger(subsystem: "com.jaredatch.pensieve", category: "manifest")
                .warning(
                    "Scenario mutation saved, but manifest regeneration failed: \(error.localizedDescription, privacy: .public)"
                )
        }
    }
}
