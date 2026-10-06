import SwiftData
import SwiftUI

/// Remove first prepares a read-only confirmation. Cancel drops only this pending UI state.
@Observable
@MainActor
final class ProjectRemovalModel {
    private(set) var project: Project?
    private var plan: ProjectRemovalPlan?
    var preview: ProjectRemovalPreview? { plan?.preview }
    var error: String?

    func request(_ project: Project, platformVM: PlatformViewModel, context: ModelContext) {
        cancel()
        error = nil
        do {
            plan = try ProjectRemovalPlan.prepare(project: project, platformVM: platformVM, context: context)
            self.project = project
        } catch {
            self.error = "Couldn't prepare removal of “\(project.name)”: \(error.localizedDescription). "
                + "It stays registered so you can retry."
        }
    }

    func cancel() {
        project = nil
        plan = nil
    }

    @discardableResult
    func confirm(perform: (Project, ProjectRemovalPlan) -> BatchResult) -> BatchResult {
        guard let project, let plan else { return BatchResult() }
        let name = project.name
        let result = perform(project, plan)
        if result.hasFailures { error = ProjectListView.removalFailureMessage(projectName: name, result: result) }
        cancel()
        return result
    }
}
