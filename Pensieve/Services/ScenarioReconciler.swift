import Foundation
import SwiftData

protocol ScenarioReconcilerProtocol {
    @discardableResult
    func reconcile(context: ModelContext) -> BatchResult
}

/// Reconciles the one active scenario's declared user-wide set against the scenario ledger.
struct ScenarioReconciler: ScenarioReconcilerProtocol {
    let platformVM: PlatformViewModel
    private let scenarioStore: ScenarioStoreProtocol
    private let stateFetcher: ReconcilerStateFetching

    private struct Pair: Hashable {
        let skillID: UUID
        let platform: PlatformTarget
    }

    private struct State {
        let scenarios: [Scenario]
        let skillBySlug: [String: Skill]
        let skillByID: [UUID: Skill]
        let ledger: [ScenarioAssignment]
        let intentPairs: Set<Pair>
    }

    init(
        platformVM: PlatformViewModel,
        scenarioStore: ScenarioStoreProtocol = ScenarioStore(),
        stateFetcher: ReconcilerStateFetching = ReconcilerStateFetcher()
    ) {
        self.platformVM = platformVM
        self.scenarioStore = scenarioStore
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
        let active = activeScenario(from: state)
        let installed = Set(platformVM.installedPlatforms())
        let desired = desiredPairs(active: active, state: state, installed: installed)
        let current = Set(state.ledger.map { Pair(skillID: $0.skillID, platform: $0.platform) })

        deploy(desired.subtracting(current), state: state, context: context, aggregate: &aggregate)
        remove(current.subtracting(desired), state: state, context: context, aggregate: &aggregate)
        try? context.save()
        return aggregate
    }

    private func fetchState(context: ModelContext, intentLedger: [IntentAssignment]) -> State {
        let scenarios = (try? context.fetch(FetchDescriptor<Scenario>())) ?? []
        let skills = (try? context.fetch(FetchDescriptor<Skill>())) ?? []
        let ledger = (try? context.fetch(FetchDescriptor<ScenarioAssignment>())) ?? []
        return State(
            scenarios: scenarios,
            skillBySlug: Dictionary(skills.map { ($0.directoryName, $0) }, uniquingKeysWith: { first, _ in first }),
            skillByID: Dictionary(skills.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            ledger: ledger,
            intentPairs: Set(intentLedger.compactMap { row in
                guard row.projectID == nil,
                      let platform = PlatformTarget(rawValue: row.platformRaw) else { return nil }
                return Pair(skillID: row.skillID, platform: platform)
            })
        )
    }

    private func activeScenario(from state: State) -> Scenario? {
        guard let activeID = scenarioStore.activeScenarioID() else { return nil }
        return state.scenarios.first { $0.id == activeID }
    }

    private func desiredPairs(active: Scenario?, state: State, installed: Set<PlatformTarget>) -> Set<Pair> {
        guard let active else { return [] }
        var desired: Set<Pair> = []
        for slug in active.skillSlugs {
            guard let skill = state.skillBySlug[slug] else { continue }
            for rawValue in active.agentRawValues {
                guard let platform = PlatformTarget(rawValue: rawValue), installed.contains(platform) else { continue }
                desired.insert(Pair(skillID: skill.id, platform: platform))
            }
        }
        return desired
    }

    private func deploy(
        _ pairsToDeploy: Set<Pair>,
        state: State,
        context: ModelContext,
        aggregate: inout BatchResult
    ) {
        for (skillID, pairs) in groupedBySkill(pairsToDeploy) {
            guard let skill = state.skillByID[skillID] else { continue }
            let platforms = pairs.map(\.platform).sorted { $0.rawValue < $1.rawValue }
            let result = platformVM.deployBatch(
                skills: [skill],
                platforms: platforms,
                target: .userWide,
                context: context
            )
            aggregate.outcomes.append(contentsOf: result.outcomes)
            for outcome in result.outcomes where outcome.error == nil {
                context.insert(ScenarioAssignment(skillID: outcome.skillID, platform: outcome.platform))
            }
        }
    }

    private func remove(
        _ pairsToRemove: Set<Pair>,
        state: State,
        context: ModelContext,
        aggregate: inout BatchResult
    ) {
        for (skillID, pairs) in groupedBySkill(pairsToRemove) {
            if let skill = state.skillByID[skillID] {
                var platformsToRemove: Set<PlatformTarget> = []
                for pair in pairs {
                    if state.intentPairs.contains(pair) {
                        deleteLedgerRows(matching: pair, state: state, context: context)
                        continue
                    }
                    if platformVM.artifactExists(skill: skill, platform: pair.platform, target: .userWide) {
                        platformsToRemove.insert(pair.platform)
                    } else {
                        deleteLedgerRows(matching: pair, state: state, context: context)
                    }
                }
                let sortedPlatforms = platformsToRemove.sorted { $0.rawValue < $1.rawValue }
                guard !sortedPlatforms.isEmpty else { continue }
                let result = platformVM.removeBatch(skills: [skill], platforms: sortedPlatforms, target: .userWide)
                aggregate.outcomes.append(contentsOf: result.outcomes)
                for outcome in result.outcomes where outcome.error == nil {
                    deleteLedgerRows(
                        matching: Pair(skillID: outcome.skillID, platform: outcome.platform),
                        state: state,
                        context: context
                    )
                }
            } else {
                for pair in pairs {
                    deleteLedgerRows(matching: pair, state: state, context: context)
                }
            }
        }
    }

    private func deleteLedgerRows(matching pair: Pair, state: State, context: ModelContext) {
        for row in state.ledger where row.skillID == pair.skillID && row.platform == pair.platform {
            context.delete(row)
        }
    }

    private func groupedBySkill(_ pairs: Set<Pair>) -> [(skillID: UUID, pairs: [Pair])] {
        var groups: [UUID: [Pair]] = [:]
        for pair in pairs {
            groups[pair.skillID, default: []].append(pair)
        }
        return groups
            .map { (skillID: $0.key, pairs: $0.value) }
            .sorted { $0.skillID.uuidString < $1.skillID.uuidString }
    }
}
