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
            desired: desired, current: current, skills: state.skillByID, projects: state.projectByID, platformVM: platformVM
        )
        aggregate.append(work.result)
        deployProjects(work.deploy, state: state, context: context, aggregate: &aggregate)
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
        state: State,
        context: ModelContext,
        aggregate: inout BatchResult
    ) {
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
                guard !state.ledger.contains(where: {
                    $0.skillID == skill.id && $0.projectID == project.id && $0.platformRaw == outcome.platform.rawValue
                }) else { continue }
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
        for (pair, group) in groupedProjectTriples(triples) {
            guard let skill = state.skillByID[pair.skillID],
                  let project = state.projectByID[pair.projectID] else {
                for triple in group { deleteProjectRows(matching: triple, state: state, context: context) }
                continue
            }
            var platforms: [PlatformTarget] = []
            for triple in group {
                if state.categoryTriples.contains(triple) {
                    deleteProjectRows(matching: triple, state: state, context: context)
                } else if let platform = PlatformTarget(rawValue: triple.platformRaw),
                          platformVM.artifactExists(
                            skill: skill, platform: platform, target: .project(project)
                          ) {
                    platforms.append(platform)
                } else {
                    deleteProjectRows(matching: triple, state: state, context: context)
                }
            }
            let sorted = Set(platforms).sorted { $0.rawValue < $1.rawValue }
            guard !sorted.isEmpty else { continue }
            let result = platformVM.removeBatch(
                skills: [skill], platforms: sorted, target: .project(project)
            )
            aggregate.outcomes.append(contentsOf: result.outcomes)
            for outcome in result.outcomes where outcome.error == nil {
                deleteProjectRows(
                    matching: ProjectTriple(
                        skillID: outcome.skillID,
                        projectID: project.id,
                        platformRaw: outcome.platform.rawValue
                    ),
                    state: state,
                    context: context
                )
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
