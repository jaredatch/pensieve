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
    case realized, absent, unmanaged, orphan, deferred
    var requiresIntent: Bool { self == .realized || self == .absent }
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

    private struct PairKey: Hashable {
        let skillID: UUID
        let platform: PlatformTarget
    }

    private struct TransferPair {
        let skill: Skill
        let state: ScenarioHandoverDeployState
        let record: DeployIntentRecord
    }

    private struct TransferBatch {
        var pairs: [TransferPair] = []
        var retiredRows: [ScenarioAssignment] = []
        var unmanagedRecords: [DeployIntentRecord] = []
        var removedIntent = false
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
        let transfer = try preparePairs(rows: rows, skills: skills, machineID: machineID,
                                        snapshot: &snapshot)
        do {
            // Disk is authoritative: never save ownership that a subsequent rebuild can retract.
            if transfer.removedIntent
                || transfer.pairs.contains(where: { $0.state.requiresIntent && !durable.deployIntents.contains($0.record) }) {
                try manifest.write(snapshot, toRoot: root)
                notifier()
            }
            recordOwnership(transfer.pairs, intents: intents, assignments: assignments, context: context)
            try save(context)
            for row in transfer.retiredRows { context.delete(row) }
            try save(context)
        } catch {
            context.rollback()
            throw error
        }
        let remaining = try context.fetchCount(FetchDescriptor<ScenarioAssignment>())
        if remaining == 0 {
            defaults.removeObject(forKey: Self.activeKey)
            defaults.set(true, forKey: Self.doneKey)
        }
        log("\(remaining == 0 ? "Completed" : "Deferred") for \(machineID): "
            + "\(transfer.retiredRows.count) legacy rows retired; \(remaining) remain; "
            + "\(transfer.unmanagedRecords.count) left unmanaged in this run.")
    }

    private func preparePairs(rows: [ScenarioAssignment], skills: [Skill], machineID: String,
                              snapshot: inout ManifestSnapshot) throws -> TransferBatch {
        let skillByID = Dictionary(skills.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if rows.contains(where: { row in
            guard let skill = skillByID[row.skillID] else { return false }
            return canRepresent(skill: skill, platform: row.platform.rawValue)
        }) {
            try fileService.checkDirectoryReadable(at: root + "/skills")
        }
        var batch = TransferBatch()
        var states: [PairKey: ScenarioHandoverDeployState] = [:]
        var folders: [UUID: StoreFolderState] = [:]
        for row in rows {
            guard let skill = skillByID[row.skillID] else { batch.retiredRows.append(row); continue }
            let key = PairKey(skillID: row.skillID, platform: row.platform)
            let record = DeployIntentRecord(machineID: machineID, skillSlug: skill.directoryName,
                                            platformRaw: row.platform.rawValue, projectKey: nil)
            let state: ScenarioHandoverDeployState
            if let cached = states[key] { state = cached } else {
                state = classify(skill: skill, platform: row.platform, folders: &folders)
                states[key] = state
                if state != .deferred {
                    batch.pairs.append(TransferPair(skill: skill, state: state, record: record))
                    batch.removedIntent = updateIntent(record, state: state, snapshot: &snapshot) || batch.removedIntent
                }
                if state == .unmanaged, !batch.unmanagedRecords.contains(record) { batch.unmanagedRecords.append(record) }
            }
            if state != .deferred { batch.retiredRows.append(row) }
        }
        return batch
    }

    private func classify(skill: Skill, platform: PlatformTarget,
                          folders: inout [UUID: StoreFolderState]) -> ScenarioHandoverDeployState {
        guard canRepresent(skill: skill, platform: platform.rawValue) else {
            log("Left unmanaged: skill '\(skill.directoryName)', agent '\(platform.rawValue)'.")
            return .unmanaged
        }
        let folder = folders[skill.id] ?? storeFolderState(skill)
        folders[skill.id] = folder
        let state: ScenarioHandoverDeployState
        switch folder {
        case .absent: state = .orphan
        case .unmanaged: state = .unmanaged
        case .deferred: state = .deferred
        case .safe: state = probeDeployState(skill: skill, platform: platform)
        }
        switch state {
        case .unmanaged: log("Left unmanaged: skill '\(skill.directoryName)', agent '\(platform.rawValue)'.")
        case .deferred: log("Deferred: skill '\(skill.directoryName)', agent '\(platform.rawValue)'.")
        case .orphan:
            log("Dropped orphan: skill '\(skill.directoryName)' store folder is missing, agent '\(platform.rawValue)'.")
        case .realized, .absent: break
        }
        return state
    }

    private func probeDeployState(skill: Skill, platform: PlatformTarget) -> ScenarioHandoverDeployState {
        do {
            return try deployState(skill, platform)
        } catch {
            log("Deploy probe failed for '\(skill.directoryName)', agent '\(platform.rawValue)': "
                + error.localizedDescription)
            return .deferred
        }
    }

    private func updateIntent(_ record: DeployIntentRecord, state: ScenarioHandoverDeployState,
                              snapshot: inout ManifestSnapshot) -> Bool {
        if !state.requiresIntent {
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

    private enum StoreFolderState { case safe, absent, unmanaged, deferred }

    private func storeFolderState(_ skill: Skill) -> StoreFolderState {
        let path = root + "/skills/" + skill.directoryName
        do {
            guard let type = try fileService.entryTypeWithoutFollowingLinks(at: path) else { return .absent }
            guard type == .directory else { return .unmanaged }
            try fileService.checkDirectoryReadable(at: path)
            let realFolder = try fileService.resolveRealPath(at: path)
            let realBase = try fileService.resolveRealPath(at: root + "/skills")
            guard realFolder == realBase + "/" + skill.directoryName else { return .unmanaged }
            guard SkillStore.safeSkillFile(slug: skill.directoryName, base: root + "/skills",
                                          fileService: fileService) != nil else { return .unmanaged }
        } catch {
            log("Store entry probe failed for '\(skill.directoryName)': \(error.localizedDescription)")
            return .deferred
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
            if !pair.state.requiresIntent {
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
