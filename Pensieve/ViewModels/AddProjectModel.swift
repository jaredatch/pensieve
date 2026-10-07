import Foundation
import Observation

/// Sheet-local validation and identity preview. Path changes probe off the render path.
@Observable
final class AddProjectModel {
    var name = "" {
        didSet { if name != oldValue { queuedSubmission = nil } }
    }
    var path = "" {
        didSet { if path != oldValue { refreshIdentityStatus() } }
    }
    private(set) var identityMessage: String?
    private(set) var hasIdentityError = false
    private(set) var hasProjectDirectory = false
    private(set) var hasExistingIdentity = false
    private(set) var isCheckingIdentity = false
    private var previewGeneration = 0
    private var didSubmit = false
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var queuedSubmission: (@MainActor (Project) -> Void)?

    private let previewDelay: () async throws -> Void
    private let fileService: FileServiceProtocol
    private let identityService: ProjectIdentityServiceProtocol

    init(fileService: FileServiceProtocol = FileService(), identityService: ProjectIdentityServiceProtocol? = nil,
         previewDelay: @escaping () async throws -> Void = { try await Task.sleep(for: .milliseconds(150)) }) {
        self.previewDelay = previewDelay
        self.fileService = fileService
        self.identityService = identityService ?? ProjectIdentityService(fileService: fileService)
    }

    private var submissionPath: String {
        (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
    }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && hasProjectDirectory
    }

    /// Add waits for the current path's probe. Return queues one submission until admission;
    /// editing either field cancels it. Submission revalidates the directory, including after a failed Add.
    var canSubmit: Bool {
        !didSubmit && !isCheckingIdentity && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && submissionPath.hasPrefix("/")
    }

    func refreshIdentityStatus() {
        previewTask?.cancel()
        queuedSubmission = nil
        hasProjectDirectory = false
        previewGeneration += 1
        let expanded = submissionPath
        isCheckingIdentity = !expanded.isEmpty
        hasIdentityError = false
        hasExistingIdentity = false
        guard !expanded.isEmpty else {
            identityMessage = nil
            return
        }
        guard expanded.hasPrefix("/") else {
            isCheckingIdentity = false
            hasIdentityError = true
            identityMessage = "Enter a full path, starting with / or ~/"
            return
        }
        identityMessage = "Checking project folder…"
        previewTask = previewIdentity(at: expanded, generation: previewGeneration)
    }

    private func previewIdentity(at path: String, generation: Int) -> Task<Void, Never> {
        let files = fileService
        let identities = identityService
        let delay = previewDelay
        return Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            do { try await delay() } catch { return }
            guard !Task.isCancelled else { return }
            let probe = BlockingWork.task {
                do {
                    try Task.checkCancellation()
                    try files.requireProjectDirectory(at: path)
                    try Task.checkCancellation()
                    return (identities.peekIdentity(forProjectAt: path), Optional<String>.none)
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

    @MainActor
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
        let queued = queuedSubmission
        queuedSubmission = nil
        if error == nil, let queued { submit(onCreated: queued) }
    }

    @MainActor
    func submit(onCreated: @escaping @MainActor (Project) -> Void) {
        guard !didSubmit, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if isCheckingIdentity {
            if queuedSubmission == nil { queuedSubmission = onCreated }
            return
        }
        guard let project = makeProject() else { return }
        didSubmit = true
        onCreated(project)
    }

    func cancelSubmission() { queuedSubmission = nil }

    func makeProject() -> Project? {
        guard canSubmit else { return nil }
        previewTask?.cancel()
        previewGeneration += 1
        queuedSubmission = nil
        isCheckingIdentity = false
        do {
            let expanded = submissionPath
            return try ProjectRegistration.makeProject(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines), path: expanded, using: identityService
            )
        } catch {
            hasProjectDirectory = false
            hasIdentityError = true
            identityMessage = error.localizedDescription
            return nil
        }
    }
}
