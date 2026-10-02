import Foundation

/// A saved SKILL.md export. The library's store owns source resolution; no text decoding alters its bytes.
struct SkillExportModel {
    let suggestedFileName: String
    let message: String
    private let directoryName: String
    private let skillStore: SkillStoreProtocol
    private let fileService: FileServiceProtocol

    init(skill: Skill, library: SkillLibraryViewModel) {
        directoryName = skill.directoryName
        skillStore = library.skillStore
        fileService = library.fileService
        suggestedFileName = skill.directoryName + ".md"
        message = library.hasUnsavedChanges(for: skill)
            ? "Save a copy of the stored SKILL.md. Unsaved changes aren't included."
            : "Save a copy of the stored SKILL.md."
    }

    func export(to destination: String) throws {
        let data = try skillStore.readData(directoryName: directoryName)
        try fileService.writeData(at: destination, data: data)
    }
}
