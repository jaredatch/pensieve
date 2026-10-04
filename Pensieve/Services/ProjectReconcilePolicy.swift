import Foundation

protocol ProjectReconcileTriple: Hashable {
    var skillID: UUID { get }
    var projectID: UUID { get }
    var platformTarget: PlatformTarget? { get }
}

/// A reconcile admits each project once. Unavailable projects retain their owner rows;
/// only work still pending gets an outcome. Present projects also check their artifacts.
struct ProjectReconcilePolicy {
    private let fileService: FileServiceProtocol

    init(fileService: FileServiceProtocol) { self.fileService = fileService }

    struct Work<Triple: ProjectReconcileTriple> {
        let deploy: Set<Triple>
        let remove: Set<Triple>
        let result: BatchResult
    }

    func pending<Triple: ProjectReconcileTriple>(
        desired: Set<Triple>, current: Set<Triple>, ownedByOtherReconciler: Set<Triple>,
        skills: [UUID: Skill], projects: [UUID: Project],
        platformVM: PlatformViewModel
    ) -> Work<Triple> {
        let remove = current.subtracting(desired)
        let unlink = remove.subtracting(ownedByOtherReconciler)
        var problems: [UUID: ProjectFolderError] = [:]
        for id in Set(desired.union(unlink).map(\.projectID)) {
            guard let project = projects[id] else { continue }
            do {
                try fileService.requireProjectDirectory(at: project.path)
            } catch let error as ProjectFolderError {
                problems[id] = error
            } catch {
                problems[id] = .couldNotCheck(path: project.path, reason: error.localizedDescription)
            }
        }
        let realized = current.intersection(desired).filter { triple in
            guard problems[triple.projectID] == nil,
                  let project = projects[triple.projectID], let skill = skills[triple.skillID],
                  let platform = triple.platformTarget else { return true }
            return platformVM.artifactExists(skill: skill, platform: platform, target: .project(project))
        }
        let deploy = desired.subtracting(realized)
        var unavailable: Set<Triple> = []
        var result = BatchResult()
        for triple in deploy.union(unlink) {
            guard let problem = problems[triple.projectID] else { continue }
            unavailable.insert(triple)
            guard let project = projects[triple.projectID], let skill = skills[triple.skillID],
                  let platform = triple.platformTarget else { continue }
            result.outcomes.append(BatchPairOutcome(
                skillID: skill.id, skillName: skill.name, platform: platform, target: .project(project.id),
                error: BatchPairOutcome.failureMessage(problem, target: .project(project)), projectFolderError: problem
            ))
        }
        return Work(deploy: deploy.subtracting(unavailable), remove: remove.subtracting(unavailable),
                    result: result.skippingMissingProjects())
    }
}
