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
            let description = skill.skillDescription.isEmpty ? skill.name : skill.skillDescription
            let result = try SkillDocumentEditing.rewrite(draft: document, original: original,
                name: skill.name, description: description, slug: skill.directoryName)
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

    func updateBody(_ skill: Skill, body: String) -> BodyUpdateOutcome {
        guard !isWriteFenced(skill) else {
            error = "This skill's files are unavailable; delete it from the list, or restore the file and relaunch Pensieve."
            return .failed
        }
        do {
            // Keep the model's description non-empty without rewriting identity in the existing file.
            // A body save preserves that file's frontmatter verbatim; migration remains responsible for
            // normalizing legacy identity when it can do so without discarding source bytes.
            let resolvedDescription = skill.skillDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? skill.name
                : skill.skillDescription
            let parsed = SkillParser.parse(try skillStore.readBody(directoryName: skill.directoryName))
            let result = try skillStore.rewriteSkill(
                directoryName: skill.directoryName,
                body: body,
                preserving: parsed,
                fallbackName: skill.name,
                fallbackDescription: resolvedDescription
            )
            if skill.skillDescription != resolvedDescription {
                skill.skillDescription = resolvedDescription
            }
            let savedBody = result.content
            StoreRebuildService.refreshIdentity(of: skill, document: result.content)
            if result.didChange {
                noteAppAuthoredBody(skill, body: savedBody)
                skill.updatedAt = Date()
            } else {
                setLastWrittenBody(savedBody, directoryName: skill.directoryName)
            }
            error = nil
            return result.didChange ? .written : .unchanged
        } catch {
            self.error = "Failed to save: \(error.localizedDescription)"
            return .failed
        }
    }
}
