import Foundation
import SwiftData

protocol IntentReconcilerProtocol {
    @discardableResult
    func reconcile(context: ModelContext) -> BatchResult
}

/// Reconciles this machine's user-wide and project-scoped intent against its private realization ledger.
struct IntentReconciler: IntentReconcilerProtocol {
    let platformVM: PlatformViewModel
    let stateFetcher: ReconcilerStateFetching
    private let machineIdentity: MachineIdentityProviding
    private let handoverIsComplete: () -> Bool

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
        let scenarioPairs: Set<UserPair>
        let categoryTriples: Set<ProjectTriple>
    }

    init(
        platformVM: PlatformViewModel,
        machineIdentity: MachineIdentityProviding = MachineIdentity(),
        stateFetcher: ReconcilerStateFetching = ReconcilerStateFetcher(),
        handoverIsComplete: @escaping () -> Bool
    ) {
        self.platformVM = platformVM
        self.machineIdentity = machineIdentity
        self.stateFetcher = stateFetcher
        self.handoverIsComplete = handoverIsComplete
    }

    @discardableResult
    func reconcile(context: ModelContext) -> BatchResult {
        guard let machineID = try? machineIdentity.identifier() else { return BatchResult() }
        let state: State
        do {
            state = try fetchState(context: context)
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

    private func fetchState(context: ModelContext) throws -> State {
        let intents = try stateFetcher.deployIntents(context: context)
        let skills = try stateFetcher.skills(context: context)
        let ledger = try stateFetcher.intentAssignments(context: context)
        let scenarioLedger = handoverIsComplete() ? [] : try stateFetcher.scenarioAssignments(context: context)
        let categoryLedger = try stateFetcher.categoryAssignments(context: context)
        let projects = try stateFetcher.projects(context: context)
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
            scenarioPairs: Set(scenarioLedger.map {
                UserPair(skillID: $0.skillID, platformRaw: $0.platform.rawValue)
            }),
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
            return platform.usesSymlinks
                ? platformVM.isDeployed(skill: skill, platform: platform)
                : platformVM.artifactExists(skill: skill, platform: platform)
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
        for (skillID, group) in groupedUserPairs(pairs) {
            guard let skill = state.skillByID[skillID] else {
                for pair in group { deleteUserRows(matching: pair, state: state, context: context) }
                continue
            }
            var platforms: [PlatformTarget] = []
            for pair in group {
                if state.scenarioPairs.contains(pair) {
                    deleteUserRows(matching: pair, state: state, context: context)
                } else if let platform = PlatformTarget(rawValue: pair.platformRaw) {
                    do {
                        if try platformVM.artifactIsOwned(skill: skill, platform: platform) {
                            platforms.append(platform)
                        } else {
                            deleteUserRows(matching: pair, state: state, context: context)
                        }
                    } catch {
                        aggregate.outcomes.append(BatchPairOutcome(
                            skillID: skill.id, skillName: skill.name, platform: platform, target: .userWide,
                            error: error.localizedDescription
                        ))
                    }
                } else {
                    deleteUserRows(matching: pair, state: state, context: context)
                }
            }
            let sorted = Set(platforms).sorted { $0.rawValue < $1.rawValue }
            guard !sorted.isEmpty else { continue }
            let result = platformVM.removeBatch(skills: [skill], platforms: sorted, target: .userWide)
            aggregate.outcomes.append(contentsOf: result.outcomes)
            for outcome in result.outcomes where outcome.error == nil {
                deleteUserRows(
                    matching: UserPair(skillID: outcome.skillID, platformRaw: outcome.platform.rawValue),
                    state: state, context: context
                )
            }
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
