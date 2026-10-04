import Foundation
import Observation

/// Sheet-local validation and identity preview. Path changes probe off the render path.
@Observable
final class AddProjectModel {
    var name = ""
    var path = "" {
        didSet { refreshIdentityStatus() }
    }
    private(set) var identityMessage: String?
    private(set) var hasIdentityError = false
    private(set) var hasProjectDirectory = false

    private let fileService: FileServiceProtocol
    private let identityService: ProjectIdentityServiceProtocol

    init(fileService: FileServiceProtocol = FileService(), identityService: ProjectIdentityServiceProtocol? = nil) {
        self.fileService = fileService
        self.identityService = identityService ?? ProjectIdentityService(fileService: fileService)
    }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && hasProjectDirectory
    }

    func refreshIdentityStatus() {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        hasProjectDirectory = false
        hasIdentityError = false
        guard !trimmed.isEmpty else {
            identityMessage = nil
            return
        }
        do {
            try fileService.requireProjectDirectory(at: trimmed)
            hasProjectDirectory = true
            let identity = identityService.peekIdentity(forProjectAt: trimmed)
            switch identity?.kind {
            case .remote: identityMessage = "Git remote: \(identity?.key ?? "")"
            case .marker: identityMessage = "Marker found"
            case nil: identityMessage = "Marker will be created on Add"
            }
        } catch {
            hasIdentityError = true
            identityMessage = error.localizedDescription
        }
    }

    func makeProject() -> Project? {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        do {
            return try ProjectRegistration.makeProject(
                name: name.trimmingCharacters(in: .whitespaces),
                path: path.trimmingCharacters(in: .whitespaces),
                using: identityService
            )
        } catch {
            hasProjectDirectory = false
            hasIdentityError = true
            identityMessage = error.localizedDescription
            return nil
        }
    }
}
