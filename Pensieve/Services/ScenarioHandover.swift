import Foundation
import SwiftData

protocol ScenarioHandingOver {
    /// Called only under the launch ingest lock, before any deploy convergence.
    func handOver(context: ModelContext) throws
}

/// Transfers legacy ownership without touching agent folders. Each durable intent precedes its
/// saved realization ledger; retiring the scenario row is a second save. A fresh context isolates
/// rollback from the caller's unrelated edits. Remaining scenario rows protect interrupted pairs.
struct ScenarioHandover: ScenarioHandingOver {
    static let doneKey = "didHandOverScenarios"
    static let activeKey = "activeScenarioID"

    struct InvalidMachineIdentity: LocalizedError {
        var errorDescription: String? { "Scenario handover requires a canonical machine identity." }
    }

    private let machineIdentity: MachineIdentityProviding
    private let manifest: ManifestReadWriting
    private let root: String
    private let defaults: UserDefaults
    private let fetcher: ReconcilerStateFetching
    private let save: (ModelContext) throws -> Void
    private let log: (String) -> Void

    init(machineIdentity: MachineIdentityProviding, manifest: ManifestReadWriting,
         root: String, defaults: UserDefaults,
         fetcher: ReconcilerStateFetching = ReconcilerStateFetcher(),
         save: @escaping (ModelContext) throws -> Void = { try $0.save() },
         log: @escaping (String) -> Void = { NSLog("Pensieve scenario handover: \($0)") }) {
        self.machineIdentity = machineIdentity
        self.manifest = manifest
        self.root = root
        self.defaults = defaults
        self.fetcher = fetcher
        self.save = save
        self.log = log
    }

    func handOver(context caller: ModelContext) throws {
        guard !defaults.bool(forKey: Self.doneKey) else { return }
        let context = ModelContext(caller.container)
        context.autosaveEnabled = false
        let machineID = try machineIdentity.identifier()
        guard ManifestService.isCanonicalMachineID(machineID) else { throw InvalidMachineIdentity() }
        let rows = try fetcher.scenarioAssignments(context: context)
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let skills = try fetcher.skills(context: context)
        let skillByID = Dictionary(skills.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var intentKeys = Set(try fetcher.deployIntents(context: context).map(\.key))
        var assignmentKeys = Set(try fetcher.intentAssignments(context: context).map(\.key))
        var snapshot = try manifest.read(fromRoot: root)
        var unmanagedCount = 0

        do {
            for row in rows {
                guard let skill = skillByID[row.skillID] else {
                    context.delete(row)
                    try save(context)
                    continue
                }
                let platform = row.platform.rawValue
                guard ManifestService.isAdmittedIntentComponent(skill.directoryName),
                      SkillStore.isPathSafeSlug(skill.directoryName),
                      ManifestService.isAdmittedIntentComponent(platform) else {
                    try manifest.write(snapshot, toRoot: root)
                    context.delete(row)
                    try save(context)
                    unmanagedCount += 1
                    log("Left unmanaged: skill '\(skill.directoryName)', agent '\(platform)'.")
                    continue
                }
                let record = DeployIntentRecord(machineID: machineID, skillSlug: skill.directoryName,
                                                platformRaw: platform, projectKey: nil)
                if !snapshot.deployIntents.contains(record) { snapshot.deployIntents.append(record) }
                // Disk is authoritative: never save ownership that a subsequent rebuild can retract.
                try manifest.write(snapshot, toRoot: root)
                let intent = MachineDeployIntent(machineID: machineID, skillSlug: skill.directoryName, platformRaw: platform)
                if intentKeys.insert(intent.key).inserted { context.insert(intent) }
                let assignment = IntentAssignment(skillID: skill.id, platformRaw: platform)
                if assignmentKeys.insert(assignment.key).inserted { context.insert(assignment) }
                try save(context)

                context.delete(row)
                try save(context)
            }
        } catch {
            context.rollback()
            throw error
        }
        defaults.removeObject(forKey: Self.activeKey)
        defaults.set(true, forKey: Self.doneKey)
        log("Completed for \(machineID): \(rows.count) legacy rows retired; \(unmanagedCount) left unmanaged in this run.")
    }
}
