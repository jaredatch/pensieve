import Foundation

extension SkillLibraryViewModel {
    /// The skill's directory inventory, read off the render path (a snapshot loader's call, never `body`).
    func bundleInventory(_ skill: Skill) -> SkillBundleInventory {
        Self.bundleInventory(slug: skill.directoryName, base: skillsDirectory, fileService: fileService)
    }

    /// One bundle file's text for the Content tab, or nil.
    func bundleFileText(_ skill: Skill, relativePath: String) -> String? {
        Self.bundleFileText(slug: skill.directoryName, relativePath: relativePath,
                            base: skillsDirectory, fileService: fileService)
    }

    /// An unsafe or missing directory reads as empty (C7: `SkillStore.safeSkillDirectory`, which does not
    /// check that the directory exists).
    static func bundleInventory(slug: String, base: String, fileService: FileServiceProtocol) -> SkillBundleInventory {
        guard let dir = SkillStore.safeSkillDirectory(slug: slug, base: base, fileService: fileService),
              fileService.directoryExists(at: dir) else { return .empty }
        return SkillBundleInventory.scan(root: dir, fileService: fileService)
    }

    /// `relativePath` is one the inventory produced and is re-validated here: every component passes
    /// `SkillStore.isPathSafeSlug` (the walk's predicate — no separator, dot name, leading dot, backslash, or
    /// control character), no component reached through a symlink; only a regular UTF-8 file reads, anything
    /// else is nil.
    static func bundleFileText(slug: String, relativePath: String, base: String,
                               fileService: FileServiceProtocol) -> String? {
        guard let dir = SkillStore.safeSkillDirectory(slug: slug, base: base, fileService: fileService) else { return nil }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty, components.allSatisfy(SkillStore.isPathSafeSlug) else { return nil }
        var path = dir
        for component in components {
            path += "/" + component
            if fileService.isSymlink(at: path) { return nil }
        }
        guard fileService.isRegularFile(at: path) else { return nil }
        return try? fileService.readFile(at: path)
    }
}
