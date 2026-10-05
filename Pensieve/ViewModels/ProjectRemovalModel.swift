import SwiftData
import SwiftUI

/// Remove first prepares a read-only confirmation. Cancel drops only this pending UI state.
@Observable
@MainActor
final class ProjectRemovalModel {
    private(set) var project: Project?
    private(set) var preview: ProjectRemovalPreview?
    var error: String?

    func request(_ project: Project, platformVM: PlatformViewModel, context: ModelContext) {
        cancel()
        error = nil
        do {
            preview = try ProjectRemovalPlan.prepare(project: project, platformVM: platformVM, context: context).preview
            self.project = project
        } catch {
            self.error = "Couldn't prepare removal of “\(project.name)”: \(error.localizedDescription). "
                + "It stays registered so you can retry."
        }
    }

    func cancel() {
        project = nil
        preview = nil
    }

    func confirm(perform: (Project) -> BatchResult) {
        guard let project else { return }
        let name = project.name
        let result = perform(project)
        if result.hasFailures { error = ProjectListView.removalFailureMessage(projectName: name, result: result) }
        cancel()
    }
}
