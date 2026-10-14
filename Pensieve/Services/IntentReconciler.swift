import Foundation
import SwiftData

protocol IntentReconcilerProtocol: DeploymentLedgerReconciling {
    func reconcileWaitingRemovals(context: ModelContext) -> BatchResult
}

/// Reconciles this machine's user-wide and project-scoped intent against its private realization ledger.
struct IntentReconciler: IntentReconcilerProtocol {
    let platformVM: PlatformViewModel
    let stateFetcher: ReconcilerStateFetching
    private let machineIdentity: MachineIdentityProviding

    struct UserPair: Hashable {
        let skillID: UUID
        let platformRaw: String
    }

    struct ProjectTriple: ProjectReconcileTriple {
        let skillID: UUID
        let projectID: UUID
        let platformRaw: String
        var platformTarget: PlatformTarget? { PlatformTarget(rawValue: platformRaw) }
    }

    struct State {
        let intents: [MachineDeployIntent]
        let skillBySlug: [String: Skill]
        let skillByID: [UUID: Skill]
        let projectsByKey: [String: [Project]]
        let projectByID: [UUID: Project]
        let ledger: [IntentAssignment]
        let categoryTriples: Set<ProjectTriple>
    }

    init(
        platformVM: PlatformViewModel,
        machineIdentity: MachineIdentityProviding,
        stateFetcher: ReconcilerStateFetching = ReconcilerStateFetcher()
    ) {
        self.platformVM = platformVM
        self.machineIdentity = machineIdentity
        self.stateFetcher = stateFetcher
    }

    @discardableResult
    func reconcile(context: ModelContext) -> BatchResult {
        var result = reconcileDeployments(context: context)
        result.append(reconcileWaitingRemovals(context: context))
        return result
    }

    func reconcileWaitingRemovals(context: ModelContext) -> BatchResult {
        platformVM.reconcileWaitingRemovals(context: context, identity: machineIdentity)
    }

    func reconcileSelection(_ pairs: [DeployMutationPair], context: ModelContext) -> BatchResult {
        reconcileDeployments(context: context, selection: pairs)
    }

    func reconcileDeployments(context: ModelContext) -> BatchResult {
        reconcileDeployments(context: context, selection: nil)
    }

    private func reconcileDeployments(context: ModelContext, selection: [DeployMutationPair]?) -> BatchResult {
        guard let machineID = try? machineIdentity.identifier() else { return BatchResult() }
        let state: State
        do {
            state = try fetchState(context: context, selection: selection)
        } catch {
            return BatchResult.readFailure("deployment state", error: error)
        }
        let installed = Set(platformVM.installedPlatforms())
        var aggregate = BatchResult()
        reconcileUserWide(
            machineID: machineID, state: state, installed: installed,
            context: context, aggregate: &aggregate
        )
        reconcileProjects(
            machineID: machineID, state: state, installed: installed,
            context: context, aggregate: &aggregate
        )
        try? context.save()
        return aggregate
    }

    private func fetchState(context: ModelContext, selection: [DeployMutationPair]?) throws -> State {
        let selectedKeys = selection.map { pairs in Set(pairs.filter(\.isLocal).map {
            MachineDeployIntent.makeKey(machineID: $0.machineID, skillSlug: $0.skill.directoryName,
                platformRaw: $0.platform.rawValue, projectKey: $0.target.project?.identityKey)
        }) }
        let selectedPairs = selection.map { pairs in Set(pairs.filter(\.isLocal).map {
            BatchPairKey(skillID: $0.skill.id, platform: $0.platform, target: BatchPairTarget($0.target))
        }) }
        let intents = try stateFetcher.deployIntents(context: context).filter { selectedKeys?.contains($0.key) ?? true }
        let skills = try stateFetcher.skills(context: context)
        let ledger = try stateFetcher.intentAssignments(context: context).filter { row in
            guard let selectedPairs else { return true }
            guard let platform = PlatformTarget(rawValue: row.platformRaw) else { return false }
            return selectedPairs.contains(BatchPairKey(skillID: row.skillID, platform: platform,
                target: row.projectID.map(BatchPairTarget.project) ?? .userWide))
        }
        let categoryLedger = try stateFetcher.categoryAssignments(context: context)
        let projectIDs = selection.map { Set($0.compactMap { $0.target.project?.id }) }
        let projects = try stateFetcher.projects(context: context).filter { projectIDs?.contains($0.id) ?? true }
        var projectsByKey: [String: [Project]] = [:]
        for project in projects {
            guard let key = project.identityKey else { continue }
            projectsByKey[key, default: []].append(project)
        }
        return State(
            intents: intents,
            skillBySlug: Dictionary(skills.map { ($0.directoryName, $0) }, uniquingKeysWith: { first, _ in first }),
            skillByID: Dictionary(skills.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            projectsByKey: projectsByKey,
            projectByID: Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            ledger: ledger,
            categoryTriples: Set(categoryLedger.map {
                ProjectTriple(
                    skillID: $0.skillID, projectID: $0.projectID, platformRaw: $0.platform.rawValue
                )
            })
        )
    }

    private func reconcileUserWide(
        machineID: String,
        state: State,
        installed: Set<PlatformTarget>,
        context: ModelContext,
        aggregate: inout BatchResult
    ) {
        let desired = desiredUserPairs(machineID: machineID, state: state, installed: installed)
        let current = Set(state.ledger.compactMap { row -> UserPair? in
            guard row.projectID == nil else { return nil }
            return UserPair(skillID: row.skillID, platformRaw: row.platformRaw)
        })
        let realized = current.intersection(desired).filter { pair in
            guard let skill = state.skillByID[pair.skillID],
                  let platform = PlatformTarget(rawValue: pair.platformRaw) else { return true }
            return platformVM.isRealized(skill: skill, platform: platform)
        }
        deployUserWide(desired.subtracting(realized), state: state, context: context, aggregate: &aggregate)
        removeUserWide(current.subtracting(desired), state: state, context: context, aggregate: &aggregate)
    }

    private func desiredUserPairs(
        machineID: String,
        state: State,
        installed: Set<PlatformTarget>
    ) -> Set<UserPair> {
        var desired: Set<UserPair> = []
        for intent in state.intents where intent.machineID == machineID && intent.projectKey == nil {
            guard let skill = state.skillBySlug[intent.skillSlug],
                  let platform = PlatformTarget(rawValue: intent.platformRaw),
                  installed.contains(platform) else { continue }
            desired.insert(UserPair(skillID: skill.id, platformRaw: platform.rawValue))
        }
        return desired
    }

    private func deployUserWide(
        _ pairs: Set<UserPair>, state: State, context: ModelContext, aggregate: inout BatchResult
    ) {
        for (skillID, group) in groupedUserPairs(pairs) {
            guard let skill = state.skillByID[skillID] else { continue }
            let platforms = group.compactMap { PlatformTarget(rawValue: $0.platformRaw) }
                .sorted { $0.rawValue < $1.rawValue }
            guard !platforms.isEmpty else { continue }
            let result = platformVM.deployBatch(
                skills: [skill], platforms: platforms, target: .userWide, context: context
            )
            aggregate.outcomes.append(contentsOf: result.outcomes)
            for outcome in result.outcomes where outcome.error == nil {
                guard !state.ledger.contains(where: {
                    $0.projectID == nil && $0.skillID == outcome.skillID && $0.platformRaw == outcome.platform.rawValue
                }) else { continue }
                context.insert(IntentAssignment(
                    skillID: outcome.skillID, platformRaw: outcome.platform.rawValue
                ))
            }
        }
    }

    private func removeUserWide(
        _ pairs: Set<UserPair>, state: State, context: ModelContext, aggregate: inout BatchResult
    ) {
        var removals: [DeployRemovalPair] = []
        for (skillID, group) in groupedUserPairs(pairs) {
            guard let skill = state.skillByID[skillID] else {
                for pair in group { deleteUserRows(matching: pair, state: state, context: context) }
                continue
            }
            for pair in group.sorted(by: { $0.platformRaw < $1.platformRaw }) {
                guard let platform = PlatformTarget(rawValue: pair.platformRaw) else {
                    deleteUserRows(matching: pair, state: state, context: context)
                    continue
                }
                removals.append(DeployRemovalPair(skill: skill, platform: platform))
            }
        }
        guard !removals.isEmpty else { return }
        let result = platformVM.removeOwnedBatch(pairs: removals, target: .userWide)
        aggregate.append(result)
        for key in result.completedPairs {
            deleteUserRows(matching: UserPair(skillID: key.skillID, platformRaw: key.platform.rawValue),
                           state: state, context: context)
        }
    }

    private func deleteUserRows(matching pair: UserPair, state: State, context: ModelContext) {
        for row in state.ledger where row.projectID == nil
            && row.skillID == pair.skillID && row.platformRaw == pair.platformRaw {
            context.delete(row)
        }
    }

    private func groupedUserPairs(_ pairs: Set<UserPair>) -> [(skillID: UUID, pairs: [UserPair])] {
        var groups: [UUID: [UserPair]] = [:]
        for pair in pairs { groups[pair.skillID, default: []].append(pair) }
        return groups.map { (skillID: $0.key, pairs: $0.value) }
            .sorted { $0.skillID.uuidString < $1.skillID.uuidString }
    }
}
