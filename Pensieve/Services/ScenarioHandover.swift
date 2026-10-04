import Foundation
import SwiftData

protocol ScenarioHandingOver {
    /// Called under the launch ingest lock, after any rebuild has saved, before deploy convergence.
    func handOver(context: ModelContext, readiness: ScenarioHandoverReadiness) throws
}

struct ScenarioHandoverReadiness {
    let manifestWritten: Bool
    let rebuildSaveFailed: Bool
    let ingestionNeedsRetry: Bool
}

enum ScenarioHandoverDeployState {
    case realized, absent, unmanaged
}

/// Transfers legacy ownership without touching agent folders. Batched durable intents precede the
/// saved realization ledger; retiring the scenario rows is a second save. A fresh context isolates
/// rollback from the caller's unrelated edits. Remaining scenario rows protect interrupted pairs.
struct ScenarioHandover: ScenarioHandingOver {
    static let doneKey = "didHandOverScenarios"
    static let activeKey = "activeScenarioID"

    struct InvalidMachineIdentity: LocalizedError {
        var errorDescription: String? { "Scenario handover requires a canonical machine identity." }
    }

    private let machineIdentity: MachineIdentityProviding
    private let manifest: ManifestSnapshotting
    private let root: String
    private let defaults: UserDefaults
    private let fetcher: ReconcilerStateFetching
    private let save: (ModelContext) throws -> Void
    private let log: (String) -> Void
    private let deployState: (Skill, PlatformTarget) throws -> ScenarioHandoverDeployState
    private let notifier: SyncStateNotifying
    private let fileService: FileServiceProtocol

    init(machineIdentity: MachineIdentityProviding, manifest: ManifestSnapshotting,
         root: String, defaults: UserDefaults,
         deployState: @escaping (Skill, PlatformTarget) throws -> ScenarioHandoverDeployState,
         notifier: @escaping SyncStateNotifying = SyncStateNotifier.suppressed,
         fileService: FileServiceProtocol = FileService(),
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
        self.deployState = deployState
        self.notifier = notifier
        self.fileService = fileService
    }

    private struct TransferPair {
        let skill: Skill
        let state: ScenarioHandoverDeployState
        let record: DeployIntentRecord
    }

    private struct TransferBatch {
        let pairs: [TransferPair]
        let unmanagedCount: Int
        let removedIntent: Bool
    }

    func handOver(context caller: ModelContext, readiness: ScenarioHandoverReadiness) throws {
        guard !defaults.bool(forKey: Self.doneKey) else { return }
        guard readiness.manifestWritten, !readiness.rebuildSaveFailed, !readiness.ingestionNeedsRetry else {
            log("Deferred until next launch ingest: manifest written=\(readiness.manifestWritten), "
                + "rebuild save failed=\(readiness.rebuildSaveFailed), ingest retry=\(readiness.ingestionNeedsRetry).")
            return
        }
        let context = ModelContext(caller.container)
        context.autosaveEnabled = false
        let machineID = try machineIdentity.identifier()
        guard ManifestService.isCanonicalMachineID(machineID) else { throw InvalidMachineIdentity() }
        let rows = try fetcher.scenarioAssignments(context: context).sorted { $0.id.uuidString < $1.id.uuidString }
        let skills = try fetcher.skills(context: context)
        let intents = try fetcher.deployIntents(context: context)
        let assignments = try fetcher.intentAssignments(context: context)
        let durable = try manifest.read(fromRoot: root)
        var snapshot = try preservedSnapshot(context: context, disk: durable)
        let transfer = try preparePairs(rows: rows, skills: skills, machineID: machineID, snapshot: &snapshot)
        do {
            // Disk is authoritative: never save ownership that a subsequent rebuild can retract.
            if transfer.removedIntent
                || transfer.pairs.contains(where: { $0.state != .unmanaged && !durable.deployIntents.contains($0.record) }) {
                try manifest.write(snapshot, toRoot: root)
                notifier()
            }
            recordOwnership(transfer.pairs, intents: intents, assignments: assignments, context: context)
            try save(context)
            for row in rows { context.delete(row) }
            try save(context)
        } catch {
            context.rollback()
            throw error
        }
        defaults.removeObject(forKey: Self.activeKey)
        defaults.set(true, forKey: Self.doneKey)
        log("Completed for \(machineID): \(rows.count) legacy rows retired; "
            + "\(transfer.unmanagedCount) left unmanaged in this run.")
    }

    private func preparePairs(rows: [ScenarioAssignment], skills: [Skill], machineID: String,
                              snapshot: inout ManifestSnapshot) throws -> TransferBatch {
        let skillByID = Dictionary(skills.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var pairs: [TransferPair] = []
        var unmanagedCount = 0
        var removedIntent = false
        var checkedSkills = false
        for row in rows {
            guard let skill = skillByID[row.skillID] else { continue }
            let platform = row.platform.rawValue
            let record = DeployIntentRecord(machineID: machineID, skillSlug: skill.directoryName,
                                            platformRaw: platform, projectKey: nil)
            var state = ScenarioHandoverDeployState.unmanaged
            if canRepresent(skill: skill, platform: platform) {
                if !checkedSkills {
                    try fileService.checkDirectoryReadable(at: root + "/skills")
                    checkedSkills = true
                }
                switch storeFolderState(skill) {
                case .absent:
                    log("Dropped orphan: skill '\(skill.directoryName)' has no safe store folder, agent '\(platform)'.")
                    continue
                case .safe:
                    do { state = try deployState(skill, row.platform) } catch {
                        log("Deploy probe failed for '\(skill.directoryName)', agent '\(platform)': "
                            + error.localizedDescription)
                    }
                case .unmanaged: break
                }
            }
            if state == .unmanaged {
                unmanagedCount += 1
                log("Left unmanaged: skill '\(skill.directoryName)', agent '\(platform)'.")
            }
            pairs.append(TransferPair(skill: skill, state: state, record: record))
            removedIntent = updateIntent(record, state: state, snapshot: &snapshot) || removedIntent
        }
        return TransferBatch(pairs: pairs, unmanagedCount: unmanagedCount, removedIntent: removedIntent)
    }

    private func updateIntent(_ record: DeployIntentRecord, state: ScenarioHandoverDeployState,
                              snapshot: inout ManifestSnapshot) -> Bool {
        if state == .unmanaged {
            let count = snapshot.deployIntents.count
            snapshot.deployIntents.removeAll { $0 == record }
            return count != snapshot.deployIntents.count
        }
        if !snapshot.deployIntents.contains(record) { snapshot.deployIntents.append(record) }
        return false
    }

    private func canRepresent(skill: Skill, platform: String) -> Bool {
        ManifestService.isAdmittedIntentComponent(skill.directoryName)
            && SkillStore.isPathSafeSlug(skill.directoryName) && ManifestService.isAdmittedIntentComponent(platform)
    }

    private enum StoreFolderState { case safe, absent, unmanaged }

    private func storeFolderState(_ skill: Skill) -> StoreFolderState {
        let path = root + "/skills/" + skill.directoryName
        do {
            guard try fileService.entryExistsWithoutFollowingLinks(at: path) else { return .absent }
            guard let directory = SkillStore.safeSkillDirectory(slug: skill.directoryName, base: root + "/skills",
                                                               fileService: fileService) else { return .unmanaged }
            try fileService.checkDirectoryReadable(at: directory)
        } catch {
            log("Store entry probe failed for '\(skill.directoryName)': \(error.localizedDescription)")
            return .unmanaged
        }
        return .safe
    }

    private func recordOwnership(_ pairs: [TransferPair], intents: [MachineDeployIntent],
                                 assignments: [IntentAssignment], context: ModelContext) {
        var intentKeys = Set(intents.map(\.key))
        var assignmentKeys = Set(assignments.map(\.key))
        for pair in pairs {
            let record = pair.record
            let intent = MachineDeployIntent(machineID: record.machineID, skillSlug: record.skillSlug,
                                              platformRaw: record.platformRaw)
            if pair.state == .unmanaged {
                for existing in intents where existing.key == intent.key { context.delete(existing) }
                intentKeys.remove(intent.key)
            } else if intentKeys.insert(intent.key).inserted {
                context.insert(intent)
            }
            let assignment = IntentAssignment(skillID: pair.skill.id, platformRaw: record.platformRaw)
            if pair.state == .realized {
                if assignmentKeys.insert(assignment.key).inserted { context.insert(assignment) }
            } else {
                for existing in assignments where existing.key == assignment.key { context.delete(existing) }
                assignmentKeys.remove(assignment.key)
            }
        }
    }

    /// An absent/partial tree is silent about cached metadata, and disk-only facts can outlive
    /// their local cache. Preserve both sets; local overlay fields win when both name one skill.
    private func preservedSnapshot(context: ModelContext, disk: ManifestSnapshot) throws -> ManifestSnapshot {
        var snapshot = disk
        snapshot.projects = []
        let cached = try manifest.snapshot(from: context)
        for category in cached.categories {
            if let index = snapshot.categories.firstIndex(where: { $0.name == category.name }) {
                snapshot.categories[index].projectKeys = Array(Set(
                    snapshot.categories[index].projectKeys + category.projectKeys)).sorted()
                snapshot.categories[index].skillSlugs = Array(Set(
                    snapshot.categories[index].skillSlugs + category.skillSlugs)).sorted()
            } else {
                snapshot.categories.append(category)
            }
        }
        for overlay in cached.skills {
            if let index = snapshot.skills.firstIndex(where: { $0.slug == overlay.slug }) {
                snapshot.skills[index] = overlay
            } else {
                snapshot.skills.append(overlay)
            }
        }
        for intent in cached.deployIntents where !snapshot.deployIntents.contains(intent) {
            snapshot.deployIntents.append(intent)
        }
        return snapshot
    }
}
