import Foundation
import Observation
import SwiftData

/// Remove first prepares a read-only confirmation. Cancel drops only this pending UI state.
@Observable
@MainActor
final class ProjectRemovalModel {
    private(set) var project: Project?
    private(set) var preview: ProjectRemovalPreview?
    var error: String?

    nonisolated static func removalFailureMessage(projectName: String, result: BatchResult) -> String {
        let details = (result.failures.compactMap(\.error) + result.readFailures.map(\.message)
                       + result.operationFailures).joined(separator: " ")
        if !result.readFailures.isEmpty && !result.didWithdrawProjectRequests
            && !result.didRemoveArtifacts && result.successes.isEmpty {
            return "Removal stopped because Pensieve couldn't read its deploy records. "
                + "“\(projectName)” stays registered so you can retry. " + details
        }
        let progress: String
        if result.didRemoveArtifacts || !result.successes.isEmpty {
            progress = "Removal of “\(projectName)” stopped partway. "
        } else if result.didWithdrawProjectRequests {
            progress = "Couldn't remove “\(projectName)”. Pensieve withdrew this Mac's direct deploy requests for this project. "
        } else {
            progress = "Couldn't remove “\(projectName)”. Nothing was changed. "
        }
        let reason = details.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return progress + reason + ". It stays registered; retry to complete it."
    }

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

    @discardableResult
    func confirm(perform: (Project, ProjectRemovalPreview) -> BatchResult) -> BatchResult {
        guard let project, let preview else { return BatchResult() }
        let name = project.name
        let result = perform(project, preview)
        if result.hasFailures { error = Self.removalFailureMessage(projectName: name, result: result) }
        cancel()
        return result
    }
}
