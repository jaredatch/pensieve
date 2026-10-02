import Foundation

extension SkillInstallViewModel {
    func abandonOperation() {
        let abandonedOperationID = operationID
        operationID = nil
        operationTask?.cancel()
        backgroundCancel?()
        operationTask = nil
        backgroundCancel = nil
        if let abandonedOperationID {
            emitPendingMutationIfNeeded(operationID: abandonedOperationID)
        }
    }

    func finishBackgroundOperation(id: UUID, keepingOperationID: Bool = false) {
        guard operationID == id else { return }
        operationTask = nil
        backgroundCancel = nil
        if !keepingOperationID { operationID = nil }
    }

    func clearInstallState(keepingOperation: Bool = false) {
        installQueue = []
        installIndex = 0
        installContainer = nil
        pendingCollision = nil
        collisionActionInFlight = false
        collisionRenameSlug = ""
        if let operationID {
            emitPendingMutationIfNeeded(operationID: operationID)
        }
        if !keepingOperation { operationID = nil }
    }

    func recordCanonicalWrite(operationID: UUID, slug: String? = nil) {
        if let slug { echoRegistrar([slug]) }
        mutatedOperationIDs.insert(operationID)
    }

    func emitPendingMutationIfNeeded(operationID: UUID) {
        guard mutatedOperationIDs.remove(operationID) != nil else { return }
        notifier()
    }

    var isTargetedConfirmation: Bool {
        (adoptTarget != nil || parsedURL?.form != .repo) && candidates.count == 1
    }

    var isAdoptMode: Bool { adoptTarget != nil }

    /// The picker's confirm button: "Install 1 Skill", "Install 3 Skills", or "Connect Skill" when adopting.
    var confirmButtonTitle: String {
        if isAdoptMode { return "Connect Skill" }
        return selectedCount == 1 ? "Install 1 Skill" : "Install \(selectedCount) Skills"
    }

    var repositoryIdentity: String? {
        Self.repositoryIdentity(from: source?.repo ?? parsedURL?.repo)
    }

    var repositoryDisplayName: String? {
        repositoryIdentity ?? source?.repo ?? parsedURL?.repo
    }

    var renameValidationReason: String? {
        guard pendingCollision != nil else { return nil }
        if collisionRenameSlug.isEmpty { return "Enter a new skill name." }
        guard SkillStore.isCanonicalSlug(collisionRenameSlug) else {
            return "Use lowercase letters, numbers, and hyphens."
        }
        return nil
    }

    static func repositoryIdentity(from repository: String?) -> String? {
        guard let repository,
              let components = URLComponents(string: repository),
              components.scheme == "https",
              components.host?.lowercased() == "github.com" else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return nil }
        let repo = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
        guard !parts[0].isEmpty, !repo.isEmpty else { return nil }
        return parts[0] + "/" + repo
    }

    /// Refuses to enter a service call once its task is canceled, so Cancel/Esc is never followed
    /// by a fresh fetch/install/adopt/rename starting in the background. The residual window
    /// (cancel landing after this check) is the plan's tolerated quit-mid-install shape: the
    /// engine call itself is atomic.
    nonisolated static func performUnlessCancelled<T>(_ body: () throws -> T) throws -> T {
        try Task.checkCancellation()
        return try body()
    }

    func readableFetchError(_ error: Error, form: SkillInstallURL.Form) -> String {
        var message = readable(error)
        if form != .repo {
            message += "\n\nBranch names containing '/' aren't supported in this URL form — "
                + "if the skill exists on the default branch, paste the repository URL instead "
                + "and pick it from the list."
        }
        return message
    }

    func readable(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let message = localized.errorDescription {
            return message
        }
        return error.localizedDescription
    }
}
