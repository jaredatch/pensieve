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
    private(set) var hasExistingIdentity = false
    private var previewGeneration = 0

    private let fileService: FileServiceProtocol
    private let identityService: ProjectIdentityServiceProtocol

    init(fileService: FileServiceProtocol = FileService(), identityService: ProjectIdentityServiceProtocol? = nil) {
        self.fileService = fileService
        self.identityService = identityService ?? ProjectIdentityService(fileService: fileService)
    }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && hasProjectDirectory
    }

    /// Submission always validates the directory again, including after a failed Add.
    var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func refreshIdentityStatus() {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        hasProjectDirectory = false
        hasIdentityError = false
        hasExistingIdentity = false
        previewGeneration += 1
        let generation = previewGeneration
        guard !trimmed.isEmpty else {
            identityMessage = nil
            return
        }
        identityMessage = nil
        let files = fileService
        let identities = identityService
        Task { @MainActor [weak self] in
            let preview = await Task.detached {
                do {
                    try files.requireProjectDirectory(at: trimmed)
                    return (identities.peekIdentity(forProjectAt: trimmed), Optional<String>.none)
                } catch {
                    return (Optional<ProjectIdentity>.none, Optional(error.localizedDescription))
                }
            }.value
            guard let self, self.previewGeneration == generation else { return }
            self.hasProjectDirectory = preview.1 == nil
            self.hasIdentityError = preview.1 != nil
            self.hasExistingIdentity = preview.0 != nil
            if let error = preview.1 {
                self.identityMessage = error
            } else {
                switch preview.0?.kind {
                case .remote: self.identityMessage = "Git remote: \(preview.0?.key ?? "")"
                case .marker: self.identityMessage = "Marker found"
                case nil: self.identityMessage = "Marker will be created on Add"
                }
            }
        }
    }

    func makeProject() -> Project? {
        guard canSubmit else { return nil }
        previewGeneration += 1
        do {
            return try ProjectRegistration.makeProject(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                path: path.trimmingCharacters(in: .whitespacesAndNewlines),
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
