import Foundation
@testable import Pensieve

/// Compatibility projections let baseline assertions inspect the same facts after the stores
/// move into the per-skill value. They own no state and are absent from the app target.
@MainActor
extension UpstreamHistoryViewModel {
    func hold(_ result: HeldResult, for key: ReadKey) {
        var flow = flows[key.request.skillID] ?? SkillFlow()
        hold(result, for: key, flow: &flow)
        flows[key.request.skillID] = flow
    }

    var held: [ReadKey: HeldResult] {
        get { flows.values.reduce(into: [:]) { $0.merge($1.held) { _, newer in newer } } }
        set {
            for id in flows.keys { flows[id]?.held = [:] }
            for (key, value) in newValue { flows[key.request.skillID, default: SkillFlow()].held[key] = value }
        }
    }

    var failures: [ReadKey: HeldFailure] {
        flows.values.reduce(into: [:]) { $0.merge($1.failures) { _, newer in newer } }
    }

    var reads: [UUID: Job] {
        flows.values.flatMap { $0.jobs.values }.reduce(into: [:]) {
            if case .read = $1.purpose { $0[$1.id] = $1 }
        }
    }

    var probedSkillIDs: Set<UUID> {
        get { Set(flows.filter { $0.value.probeSpent }.keys) }
        set {
            for id in Set(flows.keys).union(newValue) {
                flows[id, default: SkillFlow()].probeSpent = newValue.contains(id)
            }
        }
    }
}
