import Foundation
import SwiftData

struct SkillUpdatePlan {
    let slug: String
    let origin: InstalledOrigin
    let drifted: Bool
    let update: PinnedSkillUpdate?
}

extension UpdateCheckService {
    /// Check the same remote heads and trees as Check Now without persisting check flags or cursors.
    func planUpdates(slugs: Set<String>, context: ModelContext,
                     verify: ([SkillUpdatePlan], [UUID: String]) throws -> Void) throws -> [SkillUpdatePlan] {
        var checkouts: [UUID: String] = [:]
        defer {
            for checkout in Set(checkouts.values) {
                try? fileService.deleteDirectory(at: (checkout as NSString).deletingLastPathComponent)
            }
        }
        let skills = try context.fetch(FetchDescriptor<Skill>()).filter { slugs.contains($0.directoryName) }
        var batches: [BatchKey: [Snapshot]] = [:]
        for skill in skills {
            guard let origin = skill.installedOrigin, skill.hasLinkedOrigin else {
                throw SkillUpdateFlowError.missingPinnedUpdate
            }
            guard let remote = validateRemote(origin.repo) else { throw UpdateCheckError.unsupportedRepositoryRemote }
            batches[BatchKey(repo: remote.repo, cloneRemote: remote.cloneRemote, ref: origin.ref), default: []]
                .append(makeSnapshot(skill: skill, origin: origin))
        }
        var plans: [SkillUpdatePlan] = []
        for key in batches.keys.sorted(by: batchOrder) {
            let snapshots = batches[key] ?? []
            let credential = credentialStore.credential(forHost: CredentialHost.githubInstall)
            guard let head = try gitService.remoteHead(remote: key.cloneRemote, ref: key.ref, credential: credential) else {
                throw UpdateCheckError.trackedRefNotFound(key.ref)
            }
            let diagnostics = UpdateBatchDiagnostics(probe: { try gitService.probeUsability() })
            let (date, trees) = try readMovedHead(key: key, head: head, snapshots: snapshots,
                credential: credential, diagnostics: diagnostics, retainingCheckout: { checkout in
                    for snapshot in snapshots { checkouts[snapshot.id] = checkout }
                })
            for (snapshot, treeResult) in trees {
                let tree = try treeResult.get()
                guard let skill = skills.first(where: { $0.id == snapshot.id }) else {
                    throw SkillUpdateFlowError.skillNotFound
                }
                let drifted = try driftedLocally(skill: skill)
                // Detached metadata supplies the existing pinned-update constructor without changing the library.
                let proposed = Skill(name: skill.name, skillDescription: skill.skillDescription,
                    directoryName: skill.directoryName)
                proposed.id = skill.id
                proposed.installedOrigin = snapshot.origin
                proposed.upstreamCommit = head
                proposed.upstreamTree = tree
                proposed.upstreamCommitDate = date
                plans.append(SkillUpdatePlan(slug: skill.directoryName, origin: snapshot.origin, drifted: drifted,
                    update: tree == snapshot.origin.installedTree ? nil : try PinnedSkillUpdate(skill: proposed)))
            }
        }
        let sorted = plans.sorted { $0.slug < $1.slug }
        try verify(sorted, checkouts)
        return sorted
    }
}

extension SkillInstallService {
    func applyAndReport(_ update: PinnedSkillUpdate, expectedOrigin: InstalledOrigin,
                        allowLocalOverwrite: Bool, registration: SyncBodyWriteRegistration,
                        context: ModelContext) throws -> SkillUpdateCompletion {
        guard let skill = try context.fetch(FetchDescriptor<Skill>()).first(where: { $0.id == update.skillID }) else {
            throw SkillUpdateFlowError.skillNotFound
        }
        guard skill.installedOrigin == expectedOrigin else { throw SkillUpdateFlowError.repositoryChanged }
        try applyUpdate(update, allowLocalOverwrite: allowLocalOverwrite,
            bodyWriteRegistration: registration, context: context)
        guard let data = skill.installedOriginData else {
            throw SyncedStateMutationError(underlyingError: SkillUpdateFlowError.skillNotFound)
        }
        return SkillUpdateCompletion(skillID: skill.id, name: skill.name, skillDescription: skill.skillDescription,
            installedOriginData: data, updatedAt: skill.updatedAt)
    }
}
