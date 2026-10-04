import Foundation

extension PlatformViewModel {
    func projectFolderProblem(for project: Project) -> ProjectFolderError? {
        do {
            try fileService.requireProjectDirectory(at: project.path)
            return nil
        } catch let error as ProjectFolderError {
            return error
        } catch {
            return .couldNotCheck(path: project.path, reason: error.localizedDescription)
        }
    }
}
