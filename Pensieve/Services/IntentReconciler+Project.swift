import Foundation
import SwiftData

extension IntentReconciler {
    func reconcileProjects(
        machineID: String,
        state: State,
        installed: Set<PlatformTarget>,
        context: ModelContext,
        aggregate: inout BatchResult
    ) {
        let desired = desiredProjectTriples(machineID: machineID, state: state, installed: installed)
        let current = Set(state.ledger.compactMap { row -> ProjectTriple? in
            guard let projectID = row.projectID else { return nil }
            return ProjectTriple(skillID: row.skillID, projectID: projectID, platformRaw: row.platformRaw)
        })
        let work = platformVM.projectReconcilePolicy.pending(
            desired: desired, current: current, ownedByOtherReconciler: state.categoryTriples,
            skills: state.skillByID, projects: state.projectByID, platformVM: platformVM
        )
        aggregate.append(work.result)
        deployProjects(work.deploy, ledgerTriples: current, state: state, context: context, aggregate: &aggregate)
        removeProjects(work.remove, state: state, context: context, aggregate: &aggregate)
    }

    private func desiredProjectTriples(
        machineID: String,
        state: State,
        installed: Set<PlatformTarget>
    ) -> Set<ProjectTriple> {
        var desired: Set<ProjectTriple> = []
        for intent in state.intents where intent.machineID == machineID {
            guard let projectKey = intent.projectKey,
                  let skill = state.skillBySlug[intent.skillSlug],
                  let platform = PlatformTarget(rawValue: intent.platformRaw),
                  installed.contains(platform), platform.supportsProjectScope,
                  let projects = state.projectsByKey[projectKey] else { continue }
            for project in projects {
                desired.insert(ProjectTriple(
                    skillID: skill.id, projectID: project.id, platformRaw: platform.rawValue
                ))
            }
        }
        return desired
    }

    private func deployProjects(
        _ triples: Set<ProjectTriple>,
        ledgerTriples: Set<ProjectTriple>,
        state: State,
        context: ModelContext,
        aggregate: inout BatchResult
    ) {
        var recorded = ledgerTriples
        for (pair, group) in groupedProjectTriples(triples) {
            guard let skill = state.skillByID[pair.skillID],
                  let project = state.projectByID[pair.projectID] else { continue }
            let platforms = group.compactMap { PlatformTarget(rawValue: $0.platformRaw) }
                .sorted { $0.rawValue < $1.rawValue }
            guard !platforms.isEmpty else { continue }
            let result = platformVM.deployBatch(
                skills: [skill], platforms: platforms, target: .project(project), context: context
            ).skippingMissingProjects()
            aggregate.append(result)
            for outcome in result.successes {
                guard recorded.insert(ProjectTriple(skillID: skill.id, projectID: project.id,
                                                    platformRaw: outcome.platform.rawValue)).inserted else { continue }
                context.insert(IntentAssignment(
                    skillID: outcome.skillID,
                    platformRaw: outcome.platform.rawValue,
                    projectID: project.id
                ))
            }
        }
    }

    private func removeProjects(
        _ triples: Set<ProjectTriple>,
        state: State,
        context: ModelContext,
        aggregate: inout BatchResult
    ) {
        var removals: [UUID: [DeployRemovalPair]] = [:]
        for (pair, group) in groupedProjectTriples(triples) {
            guard let skill = state.skillByID[pair.skillID],
                  let project = state.projectByID[pair.projectID] else {
                for triple in group { deleteProjectRows(matching: triple, state: state, context: context) }
                continue
            }
            for triple in group.sorted(by: { $0.platformRaw < $1.platformRaw }) {
                guard let platform = PlatformTarget(rawValue: triple.platformRaw) else {
                    deleteProjectRows(matching: triple, state: state, context: context)
                    continue
                }
                if state.categoryTriples.contains(triple) {
                    deleteProjectRows(matching: triple, state: state, context: context)
                } else {
                    removals[project.id, default: []].append(DeployRemovalPair(skill: skill, platform: platform))
                }
            }
        }
        for projectID in removals.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let project = state.projectByID[projectID], let pairs = removals[projectID] else { continue }
            let result = platformVM.removeOwnedBatch(pairs: pairs, target: .project(project))
            aggregate.append(result)
            for key in result.completedPairs {
                deleteProjectRows(matching: ProjectTriple(skillID: key.skillID, projectID: projectID,
                    platformRaw: key.platform.rawValue), state: state, context: context)
            }
        }
    }

    private func deleteProjectRows(
        matching triple: ProjectTriple,
        state: State,
        context: ModelContext
    ) {
        for row in state.ledger where row.projectID == triple.projectID
            && row.skillID == triple.skillID && row.platformRaw == triple.platformRaw {
            context.delete(row)
        }
    }

    private func groupedProjectTriples(
        _ triples: Set<ProjectTriple>
    ) -> [(pair: ProjectPair, triples: [ProjectTriple])] {
        var groups: [ProjectPair: [ProjectTriple]] = [:]
        for triple in triples {
            groups[ProjectPair(skillID: triple.skillID, projectID: triple.projectID), default: []].append(triple)
        }
        return groups.map { (pair: $0.key, triples: $0.value) }
            .sorted {
                let left = $0.pair.skillID.uuidString + $0.pair.projectID.uuidString
                let right = $1.pair.skillID.uuidString + $1.pair.projectID.uuidString
                return left < right
            }
    }

    private struct ProjectPair: Hashable {
        let skillID: UUID
        let projectID: UUID
    }
}
