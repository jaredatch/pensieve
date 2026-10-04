import Foundation

extension SkillLibraryViewModel {
    @discardableResult
    func updateBody(_ skill: Skill, body: String, onWrite: SyncStateNotifying? = nil) -> Bool {
        guard !isWriteFenced(skill) else {
            error = "This skill's files are unavailable; delete it from the list, or restore the file and relaunch Pensieve."
            return false
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
            let savedBody = SkillParser.stripFrontmatter(result.content)
            if result.didWrite {
                skill.skillDescription = resolvedDescription
                noteAppAuthoredBody(skill, body: savedBody)
                skill.updatedAt = Date()
                onWrite?()
            } else {
                setLastWrittenBody(savedBody, directoryName: skill.directoryName)
            }
            error = nil
            return true
        } catch {
            self.error = "Failed to save: \(error.localizedDescription)"
            return false
        }
    }
}
