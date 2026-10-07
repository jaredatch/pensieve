import Foundation
import SwiftData

/// Reconciles category-managed deployments to the declared category rules. PLAN-06 / 06.2.
protocol CategoryReconcilerProtocol {
    @discardableResult
    func reconcile(context: ModelContext) -> BatchResult
    func reconcileRemovingProject(_ projectID: UUID, preservingProjects: Set<UUID>, context: ModelContext) -> BatchResult
}

/// The heart of categories: diff the desired (skill, project, agent) triples declared by the
/// rules against the realized ledger, and drive the resilient batch engine to close the gap.
/// Ledger only successful deploys; drop ledger rows only for successful unlinks. It passes
/// Skill/Project objects to PlatformViewModel, which owns the routed deploy.
struct CategoryReconciler: CategoryReconcilerProtocol {
    let platformVM: PlatformViewModel
    private let stateFetcher: ReconcilerStateFetching

    private struct Triple: ProjectReconcileTriple {
        let skillID: UUID
        let projectID: UUID
        let platform: PlatformTarget
        var platformTarget: PlatformTarget? { platform }
    }

    private struct Pair: Hashable {
        let skillID: UUID
        let projectID: UUID
    }

    private struct State {
        let categories: [Category]
        let skillBySlug: [String: Skill]
        let skillByID: [UUID: Skill]
        let projectsByKey: [String: [Project]]
        let projectByID: [UUID: Project]
        let ledger: [SkillProjectAssignment]
        let intentTriples: Set<Triple>
    }

    init(
        platformVM: PlatformViewModel,
        stateFetcher: ReconcilerStateFetching = ReconcilerStateFetcher()
    ) {
        self.platformVM = platformVM
        self.stateFetcher = stateFetcher
    }

    @discardableResult
    func reconcile(context: ModelContext) -> BatchResult {
        var result = reconcile(context: context, excludingProjectIDs: [])
        result.append(platformVM.reconcileWaitingRemovals(context: context))
        return result
    }

    func reconcileRemovingProject(_ projectID: UUID, preservingProjects: Set<UUID>, context: ModelContext) -> BatchResult {
        reconcile(context: context, excludingProjectIDs: preservingProjects.union([projectID]))
    }

    private func reconcile(context: ModelContext, excludingProjectIDs: Set<UUID>) -> BatchResult {
        var aggregate = BatchResult()
        let intentLedger: [IntentAssignment]
        do {
            intentLedger = try stateFetcher.intentAssignments(context: context)
        } catch {
            return BatchResult.readFailure("deploy intent ownership", error: error)
        }
        let state = fetchState(context: context, intentLedger: intentLedger)
        let platforms = platformVM.deployablePlatforms(forProject: true)
        let desired = desiredTriples(from: state, platforms: platforms, excludingProjectIDs: excludingProjectIDs)
        let current = Set(state.ledger.filter { !excludingProjectIDs.contains($0.projectID) }.map {
            Triple(skillID: $0.skillID, projectID: $0.projectID, platform: $0.platform)
        })

        let work = platformVM.projectReconcilePolicy.pending(
            desired: desired, current: current, ownedByOtherReconciler: state.intentTriples,
            skills: state.skillByID, projects: state.projectByID, platformVM: platformVM
        )
        aggregate.append(work.result)
        deploy(work.deploy, ledgerTriples: current, state: state, context: context, aggregate: &aggregate)
        remove(work.remove, state: state, context: context, aggregate: &aggregate)
        try? context.save()
        return aggregate
    }

    private func fetchState(context: ModelContext, intentLedger: [IntentAssignment]) -> State {
        let categories = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        let skills = (try? context.fetch(FetchDescriptor<Skill>())) ?? []
        let projects = (try? context.fetch(FetchDescriptor<Project>())) ?? []
        let ledger = (try? context.fetch(FetchDescriptor<SkillProjectAssignment>())) ?? []
        let skillBySlug = Dictionary(skills.map { ($0.directoryName, $0) }, uniquingKeysWith: { first, _ in first })
        let skillByID = Dictionary(skills.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let projectByID = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var projectsByKey: [String: [Project]] = [:]
        for project in projects {
            guard let key = project.identityKey else { continue }
            projectsByKey[key, default: []].append(project)
        }
        return State(
            categories: categories,
            skillBySlug: skillBySlug,
            skillByID: skillByID,
            projectsByKey: projectsByKey,
            projectByID: projectByID,
            ledger: ledger,
            intentTriples: Set(intentLedger.compactMap { row in
                guard let projectID = row.projectID,
                      let platform = PlatformTarget(rawValue: row.platformRaw) else { return nil }
                return Triple(skillID: row.skillID, projectID: projectID, platform: platform)
            })
        )
    }

    private func desiredTriples(from state: State, platforms: [PlatformTarget], excludingProjectIDs: Set<UUID>) -> Set<Triple> {
        var desired: Set<Triple> = []
        for category in state.categories {
            for slug in category.skillSlugs {
                guard let skill = state.skillBySlug[slug] else { continue }
                for key in category.projectKeys {
                    guard let members = state.projectsByKey[key] else { continue }
                    for project in members where !excludingProjectIDs.contains(project.id) {
                        for platform in platforms {
                            desired.insert(Triple(skillID: skill.id, projectID: project.id, platform: platform))
                        }
                    }
                }
            }
        }
        return desired
    }

    private func deploy(
        _ triplesToDeploy: Set<Triple>,
        ledgerTriples: Set<Triple>,
        state: State,
        context: ModelContext,
        aggregate: inout BatchResult
    ) {
        var recorded = ledgerTriples
        for (pair, triples) in grouped(triplesToDeploy) {
            guard let skill = state.skillByID[pair.skillID],
                  let project = state.projectByID[pair.projectID] else { continue }
            let groupPlatforms = triples.map(\.platform).sorted { $0.rawValue < $1.rawValue }
            let result = platformVM.deployBatch(
                skills: [skill],
                platforms: groupPlatforms,
                target: .project(project),
                context: context
            ).skippingMissingProjects()
            aggregate.append(result)
            for outcome in result.successes {
                guard recorded.insert(Triple(skillID: skill.id, projectID: project.id,
                                             platform: outcome.platform)).inserted else { continue }
                context.insert(SkillProjectAssignment(
                    skillID: skill.id,
                    projectID: project.id,
                    platform: outcome.platform
                ))
            }
        }
    }

    private func remove(
        _ triplesToRemove: Set<Triple>,
        state: State,
        context: ModelContext,
        aggregate: inout BatchResult
    ) {
        var removals: [UUID: (project: Project, pairs: [DeployRemovalPair])] = [:]
        var retired: Set<Triple> = []
        for (pair, triples) in grouped(triplesToRemove) {
            for triple in triples.sorted(by: { $0.platform.rawValue < $1.platform.rawValue }) {
                if state.intentTriples.contains(triple) {
                    retired.insert(triple)
                } else if let skill = state.skillByID[pair.skillID], let project = state.projectByID[pair.projectID] {
                    removals[project.id, default: (project, [])].pairs.append(
                        DeployRemovalPair(skill: skill, platform: triple.platform))
                } else {
                    retired.insert(triple)
                }
            }
        }
        deleteLedgerRows(matching: retired, state: state, context: context)
        for group in removals.values.sorted(by: { $0.project.id.uuidString < $1.project.id.uuidString }) {
            let result = platformVM.removeOwnedBatch(pairs: group.pairs, target: .project(group.project))
            aggregate.append(result)
            let completed = Set(result.completedPairs.map {
                Triple(skillID: $0.skillID, projectID: group.project.id, platform: $0.platform)
            })
            deleteLedgerRows(matching: completed, state: state, context: context)
        }
    }

    private func deleteLedgerRows(matching triples: Set<Triple>, state: State, context: ModelContext) {
        guard !triples.isEmpty else { return }
        for row in state.ledger where triples.contains(Triple(
            skillID: row.skillID, projectID: row.projectID, platform: row.platform)) {
            context.delete(row)
        }
    }

    private func grouped(_ triples: Set<Triple>) -> [(pair: Pair, triples: [Triple])] {
        var groups: [Pair: [Triple]] = [:]
        for triple in triples {
            groups[Pair(skillID: triple.skillID, projectID: triple.projectID), default: []].append(triple)
        }
        return groups
            .map { (pair: $0.key, triples: $0.value) }
            .sorted { lhs, rhs in
                if lhs.pair.skillID.uuidString != rhs.pair.skillID.uuidString {
                    return lhs.pair.skillID.uuidString < rhs.pair.skillID.uuidString
                }
                return lhs.pair.projectID.uuidString < rhs.pair.projectID.uuidString
            }
    }
}
