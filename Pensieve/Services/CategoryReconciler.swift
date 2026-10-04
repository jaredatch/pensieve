import Foundation
import SwiftData

/// Reconciles category-managed deployments to the declared category rules. PLAN-06 / 06.2.
protocol CategoryReconcilerProtocol {
    @discardableResult
    func reconcile(context: ModelContext) -> BatchResult
}

/// The heart of categories: diff the desired (skill, project, agent) triples declared by the
/// rules against the realized ledger, and drive the resilient batch engine to close the gap.
/// Ledger only successful deploys; drop ledger rows only for successful unlinks. It passes
/// Skill/Project objects to PlatformViewModel, which owns the routed deploy.
struct CategoryReconciler: CategoryReconcilerProtocol {
    let platformVM: PlatformViewModel
    private let stateFetcher: ReconcilerStateFetching

    private struct Triple: Hashable {
        let skillID: UUID
        let projectID: UUID
        let platform: PlatformTarget
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
        var aggregate = BatchResult()
        let intentLedger: [IntentAssignment]
        do {
            intentLedger = try stateFetcher.intentAssignments(context: context)
        } catch {
            return BatchResult.readFailure("deploy intent ownership", error: error)
        }
        let state = fetchState(context: context, intentLedger: intentLedger)
        let platforms = platformVM.deployablePlatforms(forProject: true)
        let desired = desiredTriples(from: state, platforms: platforms)
        let current = Set(state.ledger.map {
            Triple(skillID: $0.skillID, projectID: $0.projectID, platform: $0.platform)
        })

        let unavailable = unavailableTriples(desired.union(current), state: state, context: context, aggregate: &aggregate)
        deploy(desired.subtracting(current).subtracting(unavailable), state: state, context: context, aggregate: &aggregate)
        remove(current.subtracting(desired).subtracting(unavailable), state: state, context: context, aggregate: &aggregate)
        try? context.save()
        return aggregate
    }

    private func unavailableTriples(
        _ triples: Set<Triple>, state: State, context: ModelContext, aggregate: inout BatchResult
    ) -> Set<Triple> {
        var unavailable: Set<Triple> = []
        for (pair, group) in grouped(triples) {
            guard let project = state.projectByID[pair.projectID],
                  let problem = platformVM.projectFolderProblem(for: project) else { continue }
            for triple in group {
                unavailable.insert(triple)
                if case .missing = problem { deleteLedgerRow(matching: triple, state: state, context: context) }
                guard let skill = state.skillByID[triple.skillID] else { continue }
                let result = BatchResult(outcomes: [BatchPairOutcome(
                    skillID: skill.id, skillName: skill.name, platform: triple.platform,
                    target: .project(project.id),
                    error: BatchPairOutcome.failureMessage(problem, target: .project(project)),
                    projectFolderError: problem
                )]).skippingMissingProjects()
                aggregate.append(result)
            }
        }
        return unavailable
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

    private func desiredTriples(from state: State, platforms: [PlatformTarget]) -> Set<Triple> {
        var desired: Set<Triple> = []
        for category in state.categories {
            for slug in category.skillSlugs {
                guard let skill = state.skillBySlug[slug] else { continue }
                for key in category.projectKeys {
                    guard let members = state.projectsByKey[key] else { continue }
                    for project in members {
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
        state: State,
        context: ModelContext,
        aggregate: inout BatchResult
    ) {
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
        for (pair, triples) in grouped(triplesToRemove) {
            var groupPlatforms: Set<PlatformTarget> = []
            for triple in triples {
                if state.intentTriples.contains(triple) {
                    deleteLedgerRow(matching: triple, state: state, context: context)
                } else {
                    groupPlatforms.insert(triple.platform)
                }
            }
            guard !groupPlatforms.isEmpty else { continue }
            if let skill = state.skillByID[pair.skillID], let project = state.projectByID[pair.projectID] {
                let sortedPlatforms = groupPlatforms.sorted { $0.rawValue < $1.rawValue }
                let result = platformVM.removeBatch(skills: [skill], platforms: sortedPlatforms, target: .project(project))
                aggregate.outcomes.append(contentsOf: result.outcomes)
                let succeeded = Set(result.outcomes.filter { $0.error == nil }.map(\.platform))
                for row in state.ledger
                    where row.skillID == pair.skillID
                        && row.projectID == pair.projectID
                        && succeeded.contains(row.platform) {
                    context.delete(row)
                }
            } else {
                for row in state.ledger
                    where row.skillID == pair.skillID
                        && row.projectID == pair.projectID
                        && groupPlatforms.contains(row.platform) {
                    context.delete(row)
                }
            }
        }
    }

    private func deleteLedgerRow(matching triple: Triple, state: State, context: ModelContext) {
        for row in state.ledger where row.skillID == triple.skillID
            && row.projectID == triple.projectID && row.platform == triple.platform {
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
