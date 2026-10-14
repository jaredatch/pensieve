import Foundation

extension SkillLibraryViewModel {
    enum BodyUpdateOutcome {
        case failed, unchanged, written

        var succeeded: Bool { self != .failed }
    }

    func updateDocument(_ skill: Skill, document: String, original: String) -> BodyUpdateOutcome {
        guard !isWriteFenced(skill) else {
            error = "This skill's files are unavailable; restore the file and try again."
            return .failed
        }
        do {
            let description = skill.skillDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? skill.name : skill.skillDescription
            let result = try SkillDocumentEditing.rewrite(draft: document, original: original,
                name: skill.name, description: description)
            if result.didChange {
                try skillStore.writeBody(directoryName: skill.directoryName, body: result.content)
            }
            StoreRebuildService.refreshIdentity(of: skill, document: result.content, retainingBOM: true)
            if result.didChange {
                skill.updatedAt = Date()
                noteAppAuthoredBody(skill, body: result.content)
                if !Self.bodiesMatch(document, result.content) { noteEditorBodyInvalidated() }
            } else { setLastWrittenBody(result.content, directoryName: skill.directoryName) }
            error = nil
            return result.didChange ? .written : .unchanged
        } catch {
            self.error = error.localizedDescription
            return .failed
        }
    }

}

extension SkillLibraryViewModel {
    /// Filled when the synchronous deletion flow settles, before queued save callbacks can run.
    final class DeletionPresentation {
        var notice: DeletionNotice?
        let presentsInWindow: Bool
        init(presentsInWindow: Bool = true) { self.presentsInWindow = presentsInWindow }
    }
    func reportDeletionError(_ message: String?, to presentation: DeletionPresentation) {
        if presentation.presentsInWindow { error = message }
    }
}
