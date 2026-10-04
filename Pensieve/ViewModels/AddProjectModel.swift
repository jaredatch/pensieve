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
    private(set) var isCheckingIdentity = false
    private var previewGeneration = 0
    @ObservationIgnored private var previewTask: Task<Void, Never>?

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
        !isCheckingIdentity && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func refreshIdentityStatus() {
        previewTask?.cancel()
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        hasProjectDirectory = false
        previewGeneration += 1
        let generation = previewGeneration
        isCheckingIdentity = !trimmed.isEmpty
        guard !trimmed.isEmpty else {
            identityMessage = nil
            hasIdentityError = false
            hasExistingIdentity = false
            return
        }
        identityMessage = "Checking project folder…"
        hasIdentityError = false
        hasExistingIdentity = false
        let files = fileService
        let identities = identityService
        previewTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let probe = Task.detached {
                do {
                    try Task.checkCancellation()
                    try files.requireProjectDirectory(at: trimmed)
                    try Task.checkCancellation()
                    return (identities.peekIdentity(forProjectAt: trimmed), Optional<String>.none)
                } catch {
                    return (Optional<ProjectIdentity>.none, Optional(error.localizedDescription))
                }
            }
            let preview = await withTaskCancellationHandler {
                await probe.value
            } onCancel: {
                probe.cancel()
            }
            guard !Task.isCancelled, let self, self.previewGeneration == generation else { return }
            self.applyPreview(preview.0, error: preview.1)
        }
    }

    private func applyPreview(_ identity: ProjectIdentity?, error: String?) {
        isCheckingIdentity = false
        hasProjectDirectory = error == nil
        hasIdentityError = error != nil
        hasExistingIdentity = identity != nil
        if let error {
            identityMessage = error
        } else {
            switch identity?.kind {
            case .remote: identityMessage = "Git remote: \(identity?.key ?? "")"
            case .marker: identityMessage = "Marker found"
            case nil: identityMessage = "Marker will be created on Add"
            }
        }
    }

    func makeProject() -> Project? {
        guard canSubmit else { return nil }
        previewTask?.cancel()
        previewGeneration += 1
        isCheckingIdentity = false
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
